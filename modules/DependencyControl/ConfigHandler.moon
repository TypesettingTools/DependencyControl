json = require "json"

fileOps    = require "l0.DependencyControl.FileOps"
Logger     = require "l0.DependencyControl.Logger"
Lock       = require "l0.DependencyControl.Lock"
ConfigView = require "l0.DependencyControl.ConfigView"

class ConfigHandler
    msgs = {
        get: {
            failedLoad: "Could not provide a ConfigHandler because there was an issue loading the configuration file: %s"
            failedCreate: "Failed to create ConfigHandler for file '%s: %s"
        }
        getHive: {
            unexpected: "An unexpected error occured while trying to create hive '%s' on ConfigHandler for file '%s'"
        }
        getView: {
            failedView: "Failed to get #{ConfigView.__name} '%s' on ConfigHandler for file '%s': %s"
            failedHandler: "Failed to get ConfigHandler for file '%s' while trying to acquire a view on #{ConfigView.__name}: %s"
        }
        mergeHive: {
            badKey: "Can't merge hive because the path key #%d (%s) points to a %s."
        }
        new: {
            badPath: "Couldn't validate specified config file path '%s': %s"
            failedLoad: "Failed to load config file '%s': %s"
        }
        readFile: {
            failedLock: "Failed to lock config file for reading: %s"
            fileNotFound: "Couldn't find config file '%s'."
            jsonDecodeError: "JSON parse error: %s"
            configCorrupted: [[An error occured while parsing the JSON config file.
A backup of the corrupted configuration has been written to '%s'.
Reload your automation scripts to generate a new configuration file.]]
            failedHandle: "Failed to acquire a handle for reading the config file: %s"
            badJsonRoot: "JSON root element must be an array or a hashtable, got a %s."
        }
        load: {
            noFilePath: "Can't load because no config file is set."
            noFile: "Starting with a fresh config because the config file '%s' is missing (%s)..."
        }
        save: {
            failedWhole: "Failed to save complete config to file '%s': %s"
            failedHives: "Failed to save hives %s into config file '%s': %s"
            failedMerge: "Failed to merge config hive %s into file '%s': %s"
            failedClean: "Failed to clean config hive %s in file '%s': %s"
            failedLock: "Failed to lock config file for saving: %s"
            failedRead: "Failed to read config file '%s': %s."
            noFile: "Can't save because no config file is set."
            fileCreate: "Config file '%s' doesn't exist, will write a fresh one..."
        } 
        traverseHive: {
            badKey: "Can't retrieve hive because the path key #%d (%s) points to a %s."
        }
        writeFile: {
            writing: "Writing config file '%s'..."
            failedLock: "Failed to lock config file for writing: %s"
            failedSerialize: "Failed to serialize configuration to JSON: %s"
            failedHandle: "Failed to acquire a handle for writing the config file: %s"
        }
    }


    -- make references to provided handlers weak to allow for gc
    @handlers = setmetatable {}, {__mode: 'v'}
    @logger = Logger fileBaseName: "DepCtrl.ConfigHandler", fileSubName: script_namespace

    @get = (filePath, logger = @logger) =>
        return handler for path, handler in pairs @@handlers when path == filePath

        path, msg = fileOps.validateFullPath filePath, true
        return nil, msgs.new.badPath, filePath, msg unless path
        
        success, handler = pcall ConfigHandler, path, logger
        unless success
            return nil, msgs.get.failedCreate\format filePath, handler
        
        @@handlers[path] = handler
        return handler


    @getView = (filePath, hivePath, defaults, logger) =>
        handler, msg = @get filePath, logger
        return nil, msgs.getView.failedHandler\format, handler.filePath, hivePath, msg unless handler

        return handler\getView hivePath, defaults


    new: (filePath, @logger = Logger fileBaseName: @@__name) =>
        path, msg = fileOps.validateFullPath filePath, true
        @logger\assert path, msgs.new.badPath, filePath, msg
        @filePath = path

        @lock = Lock namespace: "l0.DependencyControl.ConfigHandler", resource: @filePath, holderName: @@__name, logger: @logger
        success, msg = @load!
        @logger\assert success, msgs.new.failedLoad, filePath, msg


    readFile = (waitLockTime, useLock = true) =>
        mode, file = fileOps.attributes @filePath, "mode"
        if mode == nil
            return nil, file

        elseif not mode
            @logger\trace msgs.readFile.fileNotFound, @filePath
            return false, msgs.readFile.fileNotFound\format @filePath

        lockState, msg = @lock\lock waitLockTime
        if lockState != Lock.LockState.Held
            return nil, msgs.readFile.failedLock\format msg

        handle, msg = io.open file, "r"
        unless handle
            @lock\release! if useLock
            return nil, msgs.readFile.failedHandle

        data = handle\read "*a"
        handle\close!

        @lock\release! if useLock

        success, res = pcall json.decode, data
        unless success
            -- JSON parse error usually points to a corrupted config file
            -- Rename the broken file to allow generating a new one
            -- so the user can continue his work
            @logger\debug msgs.readFile.jsonDecodeError, res
            backup = @filePath .. ".corrupted"
            fileOps.copy @filePath, backup
            fileOps.remove @filePath, false, true
            
            @logger\warn msgs.readFile.configCorrupted, backup
            return false, msgs.readFile.configCorrupted\format backup

        if "table" != type res
            return nil, msgs.readFile.badJsonRoot\format type res

        return res


    writeFile = (config, waitLockTime, haveLock = false) =>
        success, res = pcall json.encode, ConfigHandler\getSerializableCopy config
        unless success
            return nil, msgs.writeFile.failedSerialize\format res

        unless haveLock
            lockState, msg = @lock\lock waitLockTime
            if lockState != Lock.LockState.Held
                return nil, msgs.writeFile.failedLock\format msg


        -- write the whole config file in one go
        handle, msg = io.open(@filePath, "w")
        unless handle
            @lock\release! unless haveLock
            return nil, msgs.writeFile.failedHandle\format msg

        @logger\trace msgs.writeFile.writing, @filePath
        handle\setvbuf "full", 10e6
        handle\write res
        handle\flush!
        handle\close!

        @lock\release! unless haveLock
        return true


    hasNonPrivateFields = (tbl) ->
        for k, _ in pairs tbl
            if k\sub(1, 1) == "_"
                continue 
            else return true
        
        return false


    makeHive = (path, config) ->
        return config if #path == 0
        recurse = (path, hive, depth, config) ->
            return if depth > #path 
            hive[path[depth]] = depth == #path and config or {}
            return recurse path, hive[path[depth]], depth +1 

        hive = {}
        recurse path, hive, 1
        return hive


    traverseHive = (path, config, depth = #path) ->
        for i, key in ipairs path
            break if i > depth
            switch type config
                when "nil"
                    return false
                when "table"
                    config = config[key]
                else
                    return nil, msgs.traverseHive.badKey\format i, key, type config

        return config or false


    mergeHive = (path, source, target, depth = 1) ->
        -- merging in a root hive overwrites target with source
        if #path == 0
            target[k] = nil for k, _ in pairs target
            target[k] = source[k] for k, _ in pairs source
            return true

        key = path[depth]

        if depth == #path
            target[key] = source[key]
            return true

        if target[key] != nil and "table" != type target[key]
            return nil, msgs.mergeHive.badKey\format depth, key, type target[key]

        target[key] or= {}
        return mergeHive path, source[key], target[key], depth + 1


    purgeHive = (path, config) ->
        if #path == 0
            config[k] = nil for k, _ in pairs config

        for i = #path, 1, -1
            parent, msg = traverseHive path, config, i-1
            switch parent
                when nil return nil, msg
                when false continue
    
            parent[path[i]] = nil
            break if hasNonPrivateFields parent

        return true


    cleanHive = (path, config) ->
        hive, msg = traverseHive path, config
        return hive, msg if hive == nil

        return false if hasNonPrivateFields hive
        return purgeHive path, config


    -- copied deepCopy from Aegisub util.moon, adjusted to skip private keys
    -- TODO: fail on serialization issues
    @getSerializableCopy = (val) =>
        seen = {}
        copy = (val) ->
            return val if type(val) != 'table'
            return {} if seen[val]  -- nuke circular references which JSON doesn't support
            seen[val] = val
            {k, copy(v) for k, v in pairs val when type(k) != "string" or k\sub(1,1) != "_"}
        copy val


    getHive: (path) =>
        hive, msg = traverseHive path, @config
        switch hive
            when nil 
                return nil, msg
            when false
                res, msg = mergeHive path, makeHive(path), @config
                return nil, msg unless res

                hive, msg = traverseHive path, @config
                unless hive
                    @logger\warn msgs.getHive.unexpected, path, @filePath
                    return nil, msgs.getHive.unexpected\format path, @filePath

        return hive


    getView: (hivePath, defaults) =>
        success, view = pcall ConfigView, @, hivePath, defaults
        return if success
            view
        else nil, msgs.getView.failedView\format hivePath, @filePath, view


    load: (views, waitLockTime) =>
        return nil, msgs.load.noFilePath unless @filePath
        if type(views) == "table" and views.__class == ConfigView
            views = {views}

        config, msg = readFile @, waitLockTime
        return nil, msg if config == nil

        @logger\debug msgs.load.noFile, @filePath, msg unless config
        -- config file may not yet exist or have been reset due to corruption
        config or= {}

        -- TODO: reassign views on this handler
        if views == nil or @config == nil
            @config = config
            return true

        for view in *views
            hiveConfig, msg = traverseHive view.__hivePath, config
            switch hiveConfig
                when nil
                    return nil, msg
                when false
                    mergeHive view.__hivePath, makeHive(view.__hivePath), @config
                else mergeHive view.__hivePath, makeHive(view.__hivePath, hiveConfig), @config

            -- TODO: replace userConfig references with some metatable magic
            view.userConfig = @getHive view.__hivePath

        return true


    save: (views, waitLockTime) =>
        return nil, msgs.save.noFile unless @filePath
        if type(views) == "table" and views.__class == ConfigView
            views = {views}

        -- get a lock to avoid concurrent config file access
        lockState, msg = @lock\lock waitLockTime
        if lockState != Lock.LockState.Held
            return nil, msgs.save.failedLock\format "writing", msg

        -- read the config file
        config, err = readFile @
        if config == nil
            @lock\release!
            return nil, msgs.save.failedRead\format err

        @logger\trace msgs.save.fileCreate, @filePath unless config
        config or= {}

        -- save the whole config file if desired
        if views == nil
            success, msg = writeFile @, @config, nil, true
            @lock\release!
            return if success
                true
            else nil, msgs.save.failedWhole\format, @filePath, msg

        -- otherwise only merge in the specified views
        for view in *views
            success, msg = mergeHive view.__hivePath, @config, config
            unless success
                @lock\release!
                return nil, msgs.save.failedMerge, view.__hivePath, @filePath, msg

            success, msg = cleanHive view.__hivePath, config
            if success == nil
                @lock\release!
                return nil, msgs.save.failedClean\format view.__hivePath, @filePath, msg

        success, msg = writeFile @, config, nil, true
        @lock\release!
        return if success
            true
        else nil, msgs.save.failedHives\format, views, @filePath, msg


    purgeHive: (hive) =>
        purgeHive hive.__hivePath, @config
        return @getHive hive.__hivePath


    deleteFile: =>
