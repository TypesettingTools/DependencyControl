util = require "aegisub.util"
local ConfigHandler

class ConfigView
    msgs = {
        new: {
            failedRetrieveHive: "Failed to retrieve hive %s from ConfigHandler: %s"
        }
    }

    @get = (filePath, hivePath, defaults, logger) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        return ConfigHandler\getView filePath, hivePath, defaults, logger


    new: (configHandler, hivePath, defaults) =>
        ConfigHandler or= require "l0.DependencyControl.ConfigHandler"
        @__hivePath = "table" == type(hivePath) and hivePath or {hivePath} 
        @__configHandler = configHandler
        
        -- deprecated, provided for compatility with DepCtrl < 0.7
        @section = @__hivePath

        -- set up user configuration and make defaults accessible
        @userConfig, msg = configHandler\getHive @__hivePath
        @__configHandler.logger\assert @userConfig, msgs.new.failedRetrieveHive, hivePath, msg

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


    delete: (waitLockTime) =>
        @userConfig, msg = @__configHandler\purgeHive @
        return nil, msg unless @userConfig
        return @save waitLockTime


    import: (tbl, keys, updateOnly) =>
        tbl = tbl.userConfig if tbl.__class == @@
        changesMade = false
        keySet = {key, true for key in *keys} if keys

        for k, v in pairs tbl
            continue if keys and not keySet[k] or @userConfig[k] == v
            continue if updateOnly and @config[k] == nil

            @userConfig[k] = ConfigHandler\getSerializableCopy v
            changesMade = true

        return changesMade


    load: (waitLockTime) => @__configHandler\load @, waitLockTime


    save: (waitLockTime) => @__configHandler\save @, waitLockTime


    -- deprecated, provided for compatility with DepCtrl < 0.7
    write: (waitLockTime) => @save waitLockTime

    -- deprecated, provided for compatility with DepCtrl < 0.7
    getSectionHandler: (hivePath, defaults, noLoad) =>
        view, msg = @__configHandler\getView hivePath, defaults
        return nil, msg unless view

        view\load! unless noLoad
        return view

