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

-- Lua module searcher: returns a loader for a registered alias, otherwise nil. 
-- Kept to a single hash lookup since it runs for every otherwise-unresolved require.
search = (name) ->
    providerName = state.providers[name]
    return unless providerName
    -> require providerName

class ModuleProvider
    --- Registers a provider for an alias name. First registration wins.
    -- @param alias string the (possibly bare) module name to provide
    -- @param providerName string the namespaced module that provides it
    -- @return boolean whether the registration was applied
    @register = (alias, providerName) ->
        return false unless type(alias) == "string" and type(providerName) == "string"
        return false if state.providers[alias]
        state.providers[alias] = providerName
        return true

    --- Registers every alias declared in a record's `provides` field.
    -- @param record table a record with .moduleName and an optional .provides array
    @registerRecord = (record) ->
        return unless record.provides and record.moduleName
        for alias in *record.provides
            name = type(alias) == "table" and alias.name or alias
            @register name, record.moduleName if name

    --- Gets the provider namespace registered for an alias module name.
    -- @param alias string
    -- @return string|nil the provider namespace registered for the alias
    @getProvider = (alias) -> state.providers[alias]

    --- Installs the alias searcher. Idempotent across reloads.
    @install = ->
        return if state.installed
        loaders = package.loaders or package.searchers
        loaders[#loaders + 1] = search
        state.installed = true

return ModuleProvider
