-- Resolves provided module aliases (e.g. "json") to their provider module
-- (e.g. "l0.dkjson") through a custom package searcher.
--
-- A module declares the aliases it can satisfy via its record's `provides` field;
-- DependencyControl registers those here, and a single searcher — appended last so
-- stock searchers and any real user-supplied module always win first — lazily loads
-- the provider when an otherwise-unresolved alias is required.
--
-- State lives in a global table so registrations and the installed searcher survive
-- DependencyControl self-update reloads.
-- @class ModuleProvider

GLOBAL_KEY = "__depCtrlModuleProvider"

state = _G[GLOBAL_KEY]
unless state
    state = { providers: {}, installed: false }
    _G[GLOBAL_KEY] = state

-- Runs a freshly-loaded module's DependencyControl initializer (`__depCtrlInit`) if it has one and
-- hasn't been initialized yet, so the module exposes a proper DependencyControl record. The guard
-- avoids re-initializing modules that mutate their exported state on first init (e.g. BadMutex).
runInitializer = (ref, DependencyControl) ->
    return ref unless type(ref) == "table" and ref.__depCtrlInit
    -- Note to future self: don't change this to a class check! When DepCtrl self-updates
    -- any managed module initialized before will still use the same instance
    alreadyInitialized = type(ref.version) == "table" and ref.version.__class and
        ref.version.__class.__name == DependencyControl.__name
    ref.__depCtrlInit DependencyControl unless alreadyInitialized
    return ref

-- Resolves DependencyControl from package.loaded rather than require()ing it, because an alias can be
-- pulled in during DepCtrl's own bootstrap where a require-back would cycle, and the type check also
-- rejects the mid-bootstrap "loading" sentinel. Until the real class is loaded there's nothing to init
-- against, so the module is returned as-is.
initProvidedModule = (mod) ->
    DependencyControl = package.loaded["l0.DependencyControl"]
    return mod unless type(DependencyControl) == "table"
    runInitializer mod, DependencyControl

-- Returns a loader for a registered alias, or nil for an unregistered name.
-- Kept to a single hash lookup since it runs for every otherwise-unresolved require.
search = (name) ->
    providerName = state.providers[name]
    return unless providerName
    -> initProvidedModule require providerName

class ModuleProvider
    --- Runs a freshly-loaded module reference's DependencyControl initializer (`__depCtrlInit`), if
    -- it has one and hasn't been initialized yet, so the module exposes a proper DependencyControl
    -- record. The guard avoids re-initializing modules that mutate state on first init (e.g. BadMutex).
    -- @param ref any the loaded module reference
    -- @param DependencyControl table the DependencyControl class to hand the initializer
    -- @return any the same ref, for convenient chaining
    @runInitializer = runInitializer

    --- Registers a provider for an alias name. First registration wins.
    -- @param alias string the (possibly bare) module name to provide
    -- @param providerName string the namespaced module that provides it
    -- @return boolean whether the registration was applied
    @register = (alias, providerName) =>
        return false unless type(alias) == "string" and type(providerName) == "string"
        return false if state.providers[alias]
        state.providers[alias] = providerName
        return true

    --- Registers every alias declared in a record's `provides` field.
    -- @param record table a record with .moduleName and an optional .provides array
    @registerRecord = (record) =>
        return unless record.provides and record.moduleName
        for alias in *record.provides
            name = type(alias) == "table" and alias.name or alias
            @register name, record.moduleName if name

    --- Gets the provider namespace registered for an alias module name.
    -- @param alias string
    -- @return string|nil the provider namespace registered for the alias
    @getProvider = (alias) => state.providers[alias]

    --- Installs the alias searcher. Idempotent across reloads.
    @install = =>
        return if state.installed
        loaders = package.loaders or package.searchers
        loaders[#loaders + 1] = search
        state.installed = true

return ModuleProvider
