lfs = require "aegisub.lfs"
PreciseTimer = require "PreciseTimer.PreciseTimer"
util = require "aegisub.util"

class ConfigHandler
    @handlers = {}
    errors = {
        jsonDecode: "Failed decoding JSON (%s)."
        badKey: "Can't %s section because the key #%d (%s) leads to a %s."
        jsonRoot: "JSON root element must be an array or a hashtable, got a %s."
        noFile: "No config file defined."
    }

    new: (@file, @defaults = {}, @section = {}, noLoad) =>
        -- register all handlers for concerted writing
        if @file
            if @@handlers[@file]
                table.insert @@handlers[@file], @
            else @@handlers[@file] = {@}
            @lockFile = "#{@file}.lock"

        -- set up user configuration and make defaults accessible
        @userConfig = {}
        @config = setmetatable {}, {
            __index: (_, k) ->
                if @userConfig[k] ~= nil return @userConfig[k]
                else return @defaults[k]
            __newindex: (_, k, v) -> @userConfig[k] = v
        }
        @c = @config -- shortcut

        -- rig defaults in a way that writing to contained tables deep-copies the whole default
        -- into the user configuration and sets the requested property there
        recurse = (tbl) ->
            for k,v in pairs tbl
                continue if type(v)~="table"
                setmetatable v, {
                    __index: {__key: k, __parent: tbl}
                    __newindex: (tbl, k, v) ->
                        upKeys, parent = {}, tbl.__parent
                        -- trace back to defaults entry, pick up the keys along the path
                        while parent
                            tbl = parent
                            upKeys[#upKeys+1] = tbl.__key
                            parent = tbl.__parent

                        -- deep copy whole defaults entry (without copying attached metatables)
                        @userConfig[tbl.__key] = util.deep_copy @defaults[tbl.__key]
                        -- set specific property originally requested on copy
                        tbl = @userConfig[tbl.__key]
                        for i = #upKeys-1, 1, -1
                            tbl = tbl[upKeys[i]]
                        tbl[k] =v
                }
                recurse v

        recurse @defaults
        @load! unless noLoad

    readFile: (file = @file) =>
        mode, err = lfs.attributes @file, "mode"
        return false, err if err
        return nil unless mode or err

        handle, err = io.open @file, "r"
        unless handle
            return false, err

        data = handle\read "*a"
        success, result = pcall json.decode, data
        unless success
            return false, errors.jsonDecode\format result
        if "table" != type result
            return false, errors.jsonRoot\format type result

        handle\close!
        return result

    load: =>
        return false, errors.noFile unless @file

        config, err = @readFile!
        return config, err unless config

        for i=1, #@section
            config = config[@section[i]]
            switch type config
                when "table" continue
                when "nil"
                    config = {}
                    break
                else return false, errors.badKey\format "retrive", i, tostring(@section[i]),type config

        @userConfig[k] = v for k,v in pairs config
        return @config

    mergeSection: (config) =>
        section = config
        -- create missing parent sections
        for i=1, #@section
            childSection = section[@section[i]]
            if childSection == nil
                section[@section[i]] = {}
                childSection = section[@section[i]]
            elseif "table" != type childSection
                return false, errors.badKey\format "update", i, tostring(@section[i]),type childSection
            section = childSection
        -- merge our values into our section
        section[k] = v for k,v in pairs @userConfig
        return config

    write: (concertWrite, waitWriteTime = 500, waitLockTime) =>
        return false, errors.noFile unless @file

        -- avoid concurrent config file access
        -- TODO: better and actually safe implementation
        PreciseTimer\sleep math.random!*(waitWriteTime/2) for i=1,2
        @getLock waitLockTime

        config, err = @readFile!
        return false, err if err
        config or= {}

        -- concerted writing allows us to update a configuration file
        -- shared by multiple handlers in the lua environment
        handlers = concertWrite and @@handlers[@file] or {@}
        for handler in *handlers
            config, err = handler\mergeSection config
            return false, err unless config

        @getLock!
        handle, err = io.open(@file, "w")
        return false, err unless handle
        success, res = pcall json.encode, config
        unless success
            @releaseLock!
            return false, res
        handle\write res
        handle\flush!
        handle\close!
        @releaseLock!

    getLock: (timeout) =>
        return true if @hasLock
        locked = lfs.attributes @lockFile, "mode"
        @waitLock timeout if locked
        lfs.touch @lockFile
        @hasLock = true

    waitLock: (timeout = 5000, interval = 100) =>
        locked = lfs.attributes @lockFile, "mode"
        while locked and timeout > 0
            PreciseTimer\sleep interval
            locked = lfs.attributes @lockFile, "mode"
            timeout -= interval
        return timeout>0 and true or @releaseLock true

    releaseLock: (force) =>
        if @hasLock or force
            @hasLock = false
            return os.remove @lockFile
        return false

    -- copied from Aegisub util.moon, adjusted to skip private keys
    deepCopy: (tbl) =>
        seen = {}
        copy = (val) ->
            return val if type(val) != 'table'
            return seen[val] if seen[val]
            seen[val] = val
            {k, copy(v) for k, v in pairs val when type(k) != "string" or k\sub(1,1) != "_"}
        copy tbl

    import: (tbl = {}, keys) =>
        changesMade = false
        keys = {key, true for key in *keys} if keys

        for k,v in pairs tbl
            continue if keys and not keys[k] or @userConfig[k] == v
            -- TODO: deep-compare tables
            isTable = type(v) == "table"
            continue if isTable and type(@userConfig[k]) == "table" and #v == #@userConfig[k]
            continue if type(k) == "string" and k\sub(1,1) == "_"
            @userConfig[k] = isTable and @deepCopy(v) or v
            changesMade = true

        return changesMade