util = require "aegisub.util"
local ConfigHandler

--- A view into a hive (nested path) of a ConfigHandler's JSON config file.
-- Holds the proxy/defaults machinery and exposes @c / @config / @userConfig.
-- Multiple views on the same file are coordinated through their shared ConfigHandler.
-- @class ConfigView
class ConfigView
    msgs = {
        new: {
            failedRetrieveHive: "Failed to retrieve hive %s from ConfigHandler: %s"
        }
        isOverlappingView: {
            differentHandler: "Other view on config file '%s' does not belong to the same config handler as this view on config file '%s'."
        }
    }

    --- Returns a ConfigView for the given file and hive path, creating a handler if needed.
    -- @param filePath string|boolean
    -- @param hivePath string|string[]
    -- @param[opt] defaults table
    -- @param[opt] logger Logger
    -- @param[opt=false] noLoad boolean
    -- @return ConfigView|nil
    -- @return string|nil err
    @get = (filePath, hivePath, defaults, logger, noLoad = false) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"

        if filePath
            handler, msg = ConfigHandler\get filePath, logger, noLoad
            return nil, msg unless handler
            return handler\getView hivePath, defaults
        else
            -- orphan view: in-memory only, no file backing (used for virtual modules)
            handler = ConfigHandler nil, logger
            return ConfigView handler, hivePath, defaults


    --- Creates a view into a hive of the given ConfigHandler.
    -- @param configHandler ConfigHandler|nil
    -- @param hivePath string|string[]
    -- @param[opt] defaults table
    new: (configHandler, hivePath, defaults) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        @__hivePath = "table" == type(hivePath) and hivePath or {hivePath}
        @__configHandler = configHandler

        -- deprecated, provided for compatibility with DepCtrl < 0.7
        @section = @__hivePath
        -- compat: expose file path directly on the view
        @file = configHandler and configHandler.filePath

        if configHandler
            success, msg = @refresh!
            configHandler.logger\assert @userConfig, msgs.new.failedRetrieveHive, hivePath, msg
        else
            @userConfig = {}  -- orphan view: no file backing

        setDefaults @, defaults
        @config = setmetatable {}, {
            __index: (_, k) ->
                if @userConfig[k] ~= nil
                    return @userConfig[k]
                else return @defaults[k]
            __newindex: (_, k, v) ->
                @userConfig[k] = v
            __len: (tbl) -> return 0
            __ipairs: (tbl) -> error "numerically indexed config hive keys are not supported"
            __pairs: (tbl) ->
                merged = util.copy @defaults
                merged[k] = v for k, v in pairs @userConfig
                return next, merged
        }
        @c = @config -- shortcut


    setDefaults = (defaults) =>
        @defaults = defaults and util.deep_copy(defaults) or {}
        -- rig defaults in a way that writing to contained tables deep-copies the whole default
        -- into the user configuration and sets the requested property there
        recurse = (tbl) ->
            for k,v in pairs tbl
                continue if type(v)~="table" or type(k)=="string" and k\match "^__"
                -- replace every table reference with an empty proxy table
                -- this ensures all writes to the table get intercepted
                tbl[k] = setmetatable {__key: k, __parent: tbl, __tbl: v}, {
                    -- make the original table the index of the proxy so that defaults can be read
                    __index: v
                    __len: (tbl) -> return #tbl.__tbl
                    __newindex: (tbl, k, v) ->
                        upKeys, parent = {}, tbl.__parent
                        -- trace back to defaults entry, pick up the keys along the path
                        while parent.__parent
                            tbl = parent
                            upKeys[#upKeys+1] = tbl.__key
                            parent = tbl.__parent

                        -- deep copy the whole defaults node into the user configuration
                        -- (util.deep_copy does not copy attached metatable references)
                        -- make sure we copy the actual table, not the proxy
                        @userConfig[tbl.__key] = util.deep_copy @defaults[tbl.__key].__tbl
                        -- finally perform requested write on userdata
                        tbl = @userConfig[tbl.__key]
                        for i = #upKeys-1, 1, -1
                            tbl = tbl[upKeys[i]]
                        tbl[k] = v
                    __pairs: (tbl) -> return next, tbl.__tbl
                    __ipairs: (tbl) ->
                        i, n, orgTbl = 0, #tbl.__tbl, tbl.__tbl
                        ->
                            i += 1
                            return i, orgTbl[i] if i <= n
                }
                recurse tbl[k]

        recurse @defaults


    --- Removes this view's hive from the config file.
    -- @param[opt] waitLockTime number
    -- @return boolean|nil
    -- @return string|nil err
    delete: (waitLockTime) =>
        @userConfig, msg = @__configHandler\purgeHive @
        return nil, msg unless @userConfig
        return @save waitLockTime


    --- Copies values from a table or ConfigView into this view's user config.
    -- @param[opt] tbl table|ConfigView
    -- @param[opt] keys string[]
    -- @param[opt] updateOnly boolean
    -- @param[opt] skipSameLengthTables boolean
    -- @return boolean changesMade
    import: (tbl, keys, updateOnly, skipSameLengthTables) =>
        tbl = tbl.userConfig if tbl.__class == @@
        changesMade = false
        keySet = {key, true for key in *keys} if keys

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


    --- Returns whether this view's hive overlaps with another view on the same handler.
    -- @param otherView ConfigView
    -- @return boolean|nil
    -- @return string|nil err
    isOverlappingView: (otherView) =>
        if @__configHandler != otherView.__configHandler
            return nil, msgs.isOverlappingView.differentHandler\format otherView.__configHandler.filePath,
                                                                       @__configHandler.filePath

        thisViewHivePathDepth, otherViewHivePathDepth = #@__hivePath, #otherView.__hivePath

        return true if thisViewHivePathDepth == 0 or otherViewHivePathDepth == 0

        for i, key in ipairs @__hivePath
            return false if key != otherView.__hivePath[i]
            return true if i == thisViewHivePathDepth or i == otherViewHivePathDepth


    --- Reloads only this view's hive from the config file.
    -- @param[opt] waitLockTime number
    -- @return boolean|nil
    -- @return string|nil err
    load: (waitLockTime) =>
        return false unless @__configHandler and @__configHandler.filePath
        @__configHandler\load @, waitLockTime


    --- Refreshes this view's userConfig from the handler's in-memory config.
    -- @return boolean|nil
    -- @return string|nil err
    refresh: =>
        @userConfig, msg = @__configHandler\getHive @__hivePath
        return if @userConfig
            true
        else nil, msg


    --- Writes this view's hive to the config file.
    -- @param[opt] waitLockTime number
    -- @return boolean|nil
    -- @return string|nil err
    save: (waitLockTime) =>
        return false unless @__configHandler and @__configHandler.filePath
        @__configHandler\save @, waitLockTime


    -- deprecated, provided for compatibility with DepCtrl < 0.7
    write: (waitLockTime) => @save waitLockTime

    -- deprecated, provided for compatibility with DepCtrl < 0.7
    -- Attaches this view to a different config file path.
    setFile: (filePath) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        logger = @__configHandler and @__configHandler.logger
        handler, msg = ConfigHandler\get filePath, logger, true  -- noLoad: caller loads separately
        return nil, msg unless handler
        @__configHandler = handler
        @file = handler.filePath
        return true

    -- deprecated, provided for compatibility with DepCtrl < 0.7
    -- Detaches this view from its config file (reverts to orphan/in-memory state).
    unsetFile: =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        @__configHandler = ConfigHandler nil, @__configHandler and @__configHandler.logger
        @file = nil
        @userConfig = {}
        return true

    -- deprecated, provided for compatibility with DepCtrl < 0.7
    -- Returns a new ConfigView for a child hive of this view's handler.
    getSectionHandler: (hivePath, defaults, noLoad) =>
        view, msg = @__configHandler\getView hivePath, defaults
        return nil, msg unless view
        view\load! unless noLoad
        return view
