Common = require "l0.DependencyControl.Common"
local ConfigHandler

-- A read/write view over a user section that holds only some of its keys, falling through per key to the
-- section default: a user-set value wins, an absent key reads the default. Needed because the top-level
-- default fallback is whole-section, so a partially-populated section (e.g. what the flat->sectioned config
-- migration leaves behind, `updates = {enabled}`) would otherwise read nil for its unset sibling keys.
-- Writes go straight to the user section, so defaults are never materialized into stored config.
mergeSection = (userSection, defaultSection) ->
    setmetatable {}, {
        __index: (_, k) -> if userSection[k] != nil then userSection[k] else defaultSection[k]
        __newindex: (_, k, v) -> userSection[k] = v
        __len: -> 0
        __ipairs: -> error "numerically indexed config hive keys are not supported"
        __pairs: ->
            merged = {}
            merged[k] = v for k, v in pairs defaultSection
            merged[k] = v for k, v in pairs userSection
            return next, merged
    }

---A view into a hive (nested path) of a ConfigHandler's JSON config file.
---Holds the proxy/defaults machinery and exposes @c / @config / @userConfig.
---Multiple views on the same file are coordinated through their shared ConfigHandler.
---@class ConfigView
class ConfigView
    msgs = {
        new: {
            failedRetrieveHive: "Failed to retrieve hive %s from ConfigHandler: %s"
        }
        isOverlappingView: {
            differentHandler: "Other view on config file '%s' does not belong to the same config handler as this view on config file '%s'."
        }
    }

    ---Returns a ConfigView for the given file and hive path, creating a handler if needed.
    ---@param filePath string|boolean Config file path, or false for an in-memory (orphan) view.
    ---@param hivePath string|string[] The hive (nested key path) this view targets.
    ---@param defaults? table Default values for the hive.
    ---@param logger? Logger
    ---@param noLoad? boolean Don't load the file immediately (default false).
    ---@param schemaOpts? { schemaId: string, migrate: fun(config: table, current?: string, target: string): boolean } Schema id/migration for the backing handler (see ConfigHandler.get); applied only when the handler is first created for this file.
    ---@return ConfigView? view
    ---@return string? err
    @get = (filePath, hivePath, defaults, logger, noLoad = false, schemaOpts) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"

        if filePath
            handler, msg = ConfigHandler\get filePath, logger, noLoad, schemaOpts
            return nil, msg unless handler
            return handler\getView hivePath, defaults
        else
            -- in-memory view with no file backing, used for virtual modules
            handler = ConfigHandler nil, logger
            return ConfigView handler, hivePath, defaults


    ---Creates a view into a hive of the given ConfigHandler.
    ---@param configHandler ConfigHandler|nil Backing handler, or nil for an in-memory (orphan) view.
    ---@param hivePath string|string[] The hive (nested key path) this view targets.
    ---@param defaults? table Default values for the hive.
    new: (configHandler, hivePath, defaults) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        @__hivePath = "table" == type(hivePath) and hivePath or {hivePath}
        @__configHandler = configHandler

        -- deprecated, provided for compatibility with DepCtrl < 0.7
        @section = @__hivePath
        -- compatibility alias exposing the config file path on the view
        @file = configHandler and configHandler.filePath

        if configHandler
            success, msg = @refresh!
            configHandler.logger\assert @userConfig, msgs.new.failedRetrieveHive, hivePath, msg
        else
            @userConfig = {}  -- orphan view: no file backing

        setDefaults @, defaults
        @config = setmetatable {}, {
            __index: (_, k) ->
                uc = @userConfig[k]
                return @defaults[k] if uc == nil
                def = @defaults[k]
                -- a partially-populated user section still resolves its unset keys from the section default
                return mergeSection uc, def if type(uc) == "table" and type(def) == "table"
                return uc
            __newindex: (_, k, v) ->
                @userConfig[k] = v
            __len: (tbl) -> return 0
            __ipairs: (tbl) -> error "numerically indexed config hive keys are not supported"
            __pairs: (tbl) ->
                merged = Common.copy @defaults
                merged[k] = v for k, v in pairs @userConfig
                return next, merged
        }
        @c = @config -- shortcut


    -- Wraps each top-level default section in a copy-on-write proxy: reads fall through to the section's
    -- defaults, and the first write into a section not yet present in the user config deep-copies that
    -- section's defaults into it before applying the write. Only the top level is wrapped -- a section
    -- already present in the user config is served per-key by mergeSection through @config. The proxy must
    -- never be iterated here: its __pairs yields the underlying default keys, so descending into it would
    -- fire the copy-on-write __newindex and materialize every default over the user's config on load.
    setDefaults = (defaults) =>
        @defaults = defaults and Common.deepCopy(defaults) or {}
        for section, contents in pairs @defaults
            continue if type(contents) != "table" or type(section) == "string" and section\match "^__"
            @defaults[section] = setmetatable {__targetMethodKey: section, __targetTable: contents}, {
                __index: contents  -- reads of unset keys fall through to the real defaults
                __len: (proxy) -> #proxy.__targetTable
                __newindex: (proxy, key, value) ->
                    -- first write into an absent section: copy its defaults into the user config, then write
                    @userConfig[proxy.__targetMethodKey] = Common.deepCopy proxy.__targetTable
                    @userConfig[proxy.__targetMethodKey][key] = value
                __pairs: (proxy) -> next, proxy.__targetTable
                __ipairs: (proxy) ->
                    i, n, orgTbl = 0, #proxy.__targetTable, proxy.__targetTable
                    ->
                        i += 1
                        return i, orgTbl[i] if i <= n
            }


    ---Removes this view's hive from the config file.
    ---@param waitLockTime? number Seconds to wait for the config lock.
    ---@return boolean? success
    ---@return string? err
    delete: (waitLockTime) =>
        @userConfig, msg = @__configHandler\purgeHive @
        return nil, msg unless @userConfig
        return @save waitLockTime


    ---Copies values from a table or ConfigView into this view's user config.
    ---@param tbl? table|ConfigView Source values.
    ---@param keys? string[] Restrict the copy to these keys.
    ---@param updateOnly? boolean Only overwrite keys already present in this view.
    ---@param skipSameLengthTables? boolean Skip array values whose length matches the existing one.
    ---@return boolean changesMade
    import: (tbl, keys, updateOnly, skipSameLengthTables) =>
        tbl = tbl.userConfig if tbl.__class == @@
        changesMade = false
        keySet = Common.makeSet keys if keys

        for k, v in pairs tbl
            continue if keys and not keySet[k] or @userConfig[k] == v
            continue if updateOnly and @config[k] == nil
            isTable = type(v) == "table"
            if isTable and skipSameLengthTables and type(@userConfig[k]) == "table" and #v == #@userConfig[k]
                continue
            continue if type(k) == "string" and k\sub(1,1) == "_"
            @userConfig[k] = ConfigHandler\getSerializableCopy v
            changesMade = true

        return changesMade


    ---Returns whether this view's hive overlaps with another view on the same handler.
    ---@param otherView ConfigView
    ---@return boolean? overlapping nil when the views belong to different handlers.
    ---@return string? err
    isOverlappingView: (otherView) =>
        if @__configHandler != otherView.__configHandler
            return nil, msgs.isOverlappingView.differentHandler\format otherView.__configHandler.filePath,
                                                                       @__configHandler.filePath

        thisViewHivePathDepth, otherViewHivePathDepth = #@__hivePath, #otherView.__hivePath

        return true if thisViewHivePathDepth == 0 or otherViewHivePathDepth == 0

        for i, key in ipairs @__hivePath
            return false if key != otherView.__hivePath[i]
            return true if i == thisViewHivePathDepth or i == otherViewHivePathDepth


    ---Reloads only this view's hive from the config file.
    ---@param waitLockTime? number Seconds to wait for the config lock.
    ---@return boolean? success
    ---@return string? err
    load: (waitLockTime) =>
        return false unless @__configHandler and @__configHandler.filePath
        @__configHandler\load @, waitLockTime


    ---Refreshes this view's userConfig from the handler's in-memory config.
    ---@return boolean? success
    ---@return string? err
    refresh: =>
        @userConfig, msg = @__configHandler\getHive @__hivePath
        return if @userConfig
            true
        else nil, msg


    ---Writes this view's hive to the config file.
    ---@param waitLockTime? number Seconds to wait for the config lock.
    ---@return boolean? success
    ---@return string? err
    save: (waitLockTime) =>
        return false unless @__configHandler and @__configHandler.filePath
        @__configHandler\save @, waitLockTime


    ---@deprecated Use `save`. Retained as an alias for callers written against DepCtrl < 0.7.
    ---@param waitLockTime? number Seconds to wait for the config lock.
    ---@return boolean? success
    ---@return string? err
    write: (waitLockTime) => @save waitLockTime

    ---Attaches this view to a different config file, without loading it (the caller loads separately).
    ---@param filePath string Full path to the config file.
    ---@return boolean? success
    ---@return string? err
    setFile: (filePath) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        logger = @__configHandler and @__configHandler.logger
        handler, msg = ConfigHandler\get filePath, logger, true  -- noLoad: caller loads separately
        return nil, msg unless handler
        @__configHandler = handler
        @file = handler.filePath
        return true

    ---Detaches this view from its config file, reverting to an in-memory (orphan) state.
    ---@return boolean success
    unsetFile: =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        @__configHandler = ConfigHandler nil, @__configHandler and @__configHandler.logger
        @file = nil
        @userConfig = {}
        return true

    ---Returns a ConfigView for a child hive of this view's config.
    ---@param hivePath string|string[] Path to the child hive, relative to this view.
    ---@param defaults? table Default values for the child view.
    ---@param noLoad? boolean Skip loading the child view (the caller loads it separately).
    ---@return ConfigView? view
    ---@return string? err
    getSectionHandler: (hivePath, defaults, noLoad) =>
        view, msg = @__configHandler\getView hivePath, defaults
        return nil, msg unless view
        view\load! unless noLoad
        return view
