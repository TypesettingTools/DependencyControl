lfs = require "lfs"
util = require "aegisub.util"
json = require "json"
PreciseTimer = require "PT.PreciseTimer"
Logger = require "l0.DependencyControl.Logger"
fileOps = require "l0.DependencyControl.FileOps"
mutex = require "BM.BadMutex"

class ConfigHandler
    @handlers = {}
    errors = {
        jsonDecode: "Failed decoding JSON (%s)."
        badKey: "Can't %s section because the key #%d (%s) leads to a %s."
        jsonRoot: "JSON root element must be an array or a hashtable, got a %s."
        noFile: "No config file defined."
        failedLockWrite: "Failed to lock config file for writing: %s"
        waitLockFailed: "Error waiting for existing lock to be released: %s"
        forceReleaseFailed: "Failed to force-release existing lock after timeout had passed (%s)"
        noLock: "#{@@__name} doesn't have a lock"
        writeFailedRead: "Failed reading config file: %s."
        lockTimeout: "Timeout reached while waiting for write lock."
    }
    traceMsgs = {
        waitingLock: "Waiting %d ms before trying to get a lock..."
        waitingLock: "Waiting for config file lock to be released (%d seconds passed)... "
        waitingLockFinished: "Lock was released after %d seconds."
        -- waitingLockTimeout: "Timeout was reached after %d seconds, force-releasing lock..."
    }

    new: (@file, @defaults = {}, @section = {}, noLoad, @logger = Logger fileBaseName: @@__name) =>
        -- register all handlers for concerted writing
        @setFile @file

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

    setFile: (file) =>
        return false unless file
        if @@handlers[file]
            table.insert @@handlers[file], @
        else @@handlers[file] = {@}
        @file = file
        return true

    unsetFile: =>
        handlers = @@handlers[@file]
        if handlers and #handlers>1
            @@handlers[@file] = [handler for handler in *handlers when handler != @]
        else @@handlers[@file] = nil
        @file = nil
        return true

    readFile: (file = @file) =>
        mode, file = fileOps.attributes file, "mode"
        if mode == nil
            return false, file
        elseif not mode
            return nil

        handle, err = io.open file, "r"
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

        sectionExists = true
        for i=1, #@section
            config = config[@section[i]]
            switch type config
                when "table" continue
                when "nil"
                    config, sectionExists = {}, false
                    break
                else return false, errors.badKey\format "retrive", i, tostring(@section[i]),type config

        @userConfig[k] = v for k,v in pairs config
        return sectionExists

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

    write: (concertWrite, waitLockTime = 5000) =>
        return false, errors.noFile unless @file

        -- get a lock to avoid concurrent config file access
        time, err = @getLock waitLockTime
        unless time
            return false, errors.failedLockWrite\format err

        -- read the config file
        config, err = @readFile!
        if err
            return false, errors.writeFailedRead\format err
        config or= {}

        -- merge in our section
        -- concerted writing allows us to update a configuration file
        -- shared by multiple handlers in the lua environment
        handlers = concertWrite and @@handlers[@file] or {@}
        for handler in *handlers
            config, err = handler\mergeSection config
            return false, err unless config

        -- write the whole config file in one go
        handle, err = io.open(@file, "w")
        unless handle
            @releaseLock!
            return false, err

        success, res = pcall json.encode, config
        unless success
            @releaseLock!
            return false, res


        handle\setvbuf "full"
        handle\write res
        handle\flush!
        handle\close!
        @releaseLock!

        return true

    getLock: (waitTimeout, checkInterval = 100) =>
        return 0 if @hasLock
        success = mutex.tryLock!
        if success
            @hasLock = true
            return 0

        timeout, timePassed = waitTimeout, 0
        while not success and timeout > 0
            PreciseTimer.sleep checkInterval
            success = mutex.tryLock!
            timeout -= checkInterval
            timePassed = waitTimeout - timeout
            @logger\trace traceMsgs.waitingLock, timePassed/1000
        if timeout > 0
            @logger\trace traceMsgs.waitingLockFinished, timePassed/1000
            @hasLock = true
            return timePassed
        else
            -- @logger\trace traceMsgs.waitingLockTimeout, waitTimeout/1000
            -- success, err = @releaseLock true
            -- unless success
                -- return false, errors.forceReleaseFailed\format err
            -- @hasLock = true
            --return waitTimeout
            return false, errors.lockTimeout

    releaseLock: (force) =>
        if @hasLock or force
            @hasLock = false
            mutex.unlock!
            return true
        return false, errors.noLock

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