json = require "json"
lfs = require "aegisub.lfs"
re = require "aegisub.re"
ffi = require "ffi"
Logger = require "l0.DependencyControl.Logger"
ConfigHandler = require "l0.DependencyControl.ConfigHandler"
PreciseTimer = require "PreciseTimer.PreciseTimer"
DownloadManager = require "DownloadManager.DownloadManager"

class DependencyControl
    semParts = {{"major", 16}, {"minor", 8}, {"patch", 0}}
    namespaceValidation = re.compile "^(?:[-\\w]+\\.)+[-\\w]+$"
    msgs = {
        badRecordError: "Bad {#@@__name} record (%s)."
        badRecord: {
            noUnmanagedMacros: "Creating unmanaged version records for macros is not allowed"
            missingNamespace: "No namespace defined"
            badVersion: "Couldn't parse version number: %s"
            badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        }
        missingModules: "Error: one or more of the modules required by %s could not be found on your system:\n%s\n%s"
        missingOptionalModules: "Error: a %s feature you're trying to use requires additional modules that were not found on your system:\n%s\n%s"
        missingModulesDownloadHint: "Please download the modules in question manually, put them in your %s folder and reload your automation scripts."
        missingTemplate: "— %s (v%s+)%s\n—— Reason: %s"
        outdatedModules: "Error: one or more of the modules required by %s are outdated on your system:
%s\nPlease update the modules in question manually and reload your automation scripts."
        outdatedTemplate: "— %s (Installed: v%s; Required: v%s)%s\n—— Reason: %s"
        missingRecord: "Error: module '%s' is missing a version record."
        moduleError: "Error in module %s:\n%s"
        badVersionString: "Can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
        badVersionType: "Argument had the wrong type: expected string or number, got '%s'"
        badModuleRecord: "Invalid required module record #%d (%s)."
        versionOverflow: "Error: %s version must be an integer < 255, got %s."
        updNoSuitableVersion: "The version of '%s' downloaded (v%s) did not satisfy the %s requirements (v%s)."
        updNoSuitableUpdate: "The installed version of '%s'(v%s) did not satisfy the %s requirements (v%s), but no update could be found."
        updNoNewVersion: "%s '%s' (v%s) is up-to-date."
        updUsingCached: "Using cached feed."
        updFetchingFeed: "Downloading feed to %s "
        updSuccess: "%s of %s '%s' (v%s) complete."
        updReloadNotice: "Please rescan your autoload directory for the changes to take effect."
        moveExistsNoFile: "Couldn't move file '%s' to '%s' because a %s of the same name is already present."
        moveGenericError: "An error occured while moving file '%s' to '%s':\n%s"
        moveCreateDirError: "Failed moving '%s' to '%s' (%s).",
        cantRemoveFile: "Couldn't overwrite file '%s': %s"
        cantRenameFile: "Couldn't move file '%s' to '%s': %s"
        createDir: {
            genericError: "Can't retrieve attributes: %s."
            createError: "Error creating directory: %s."
            otherExists: "Couldn't create directory because a %s of the same name is already present."
        }
        updateInfo: {
            starting: "Starting %supdate of %s '%s' (v%s)... "
            fetching: "Trying to %sfetch missing %s '%s'..."
            updateReqs: "Checking requirements..."
            feedCandidates: "Trying %d candidate feeds (%s mode)..."
            feedTrying: "Checking feed %d/%d (%s)..."
            tempDir: "Downloading files into temporary folder '%s'..."
            filesDownloading: "Downloading %d files..."
            fileUnchanged: "Skipped unchanged file '%s'."
            fileAddDownload: "Added Download %s ==> '%s'."
            updateReady: "Update ready. Using temporary directory '%s'."
            movingFiles: "Downloads complete. Now moving files to Aegisub automation directory '%s'..."
            movedFile: "Moved '%s' ==> '%s'."
            overwritingFile: "File '%s' already exists, overwriting..."
            createdDir: "Created target directory '%s'."
            changelog: "Changelog for %s v%s (released %s):"
            waiting: "Waiting for update intiated by %s to finish..."
            abortWait: "Timeout reached after %d seconds."
            waitFinished: "Waited %d seconds."
            unsetVirtual: "Update initated by %s already fetched %s '%s', switching to update mode."
            orphaned: "Ignoring orphaned in-progress update started by %s."
        }
        updateError: {
            [0]: "Couldn't %s %s '%s' because of a paradox: module not found but updater says up-to-date (%s)"
            [1]: "Couldn't %s %s '%s' because the updater is disabled.",
            [2]: "Skipping %s of unmanaged %s '%s'.",
            [3]: "No feed available to %s %s '%s' from.",
            [4]: "Skipping %s of %s '%s': Another update initiated by %s is already running."
            [7]: "Couldn't %s %s '%s': error parsing feed %s.",
            [8]: "The specified feed doesn't have the required data to %s the %s '%s'.",
            [9]: "Couldn't %s %s '%s' because the specified channel '%s' wasn't present in the feed.",
            [13]: "Couldn't %s %s '%s': feed contains an inalid version record (%s)."
            [15]: "Couldn't %s %s '%s' because its requirements could not be satisfied:",
            [20]: "Couldn't %s %s '%s': unsupported platform (%s).",
            [25]: "Couldn't %s %s '%s' because the feed doesn't specify any files for your platform (%s).",
            [30]: "Couldn't %s %s '%s': failed to create temporary download directory %s",
            [35]: "Aborted %s of %s '%s' because the feed contained a missing or malformed SHA-1 hash for file %s."
            [50]: "Couldn't finish %s of %s '%s' because some files couldn't be moved to their target location:\n—"
            [100]: "Error (%d) in component %s during %s of %s '%s':\n— %s"
        }
        updaterErrorComponent: {"DownloadManager (adding download)", "DownloadManager"}
    }
    depConf = {
        file: aegisub.decode_path "?user/config/l0.#{@@__name}.json",
        scriptFields: {"author", "configFile", "feed", "moduleName", "name", "namespace", "url",
                       "requiredModules", "version", "unmanaged"},
        globalDefaults: {updaterEnabled:true, updateInterval:302400, traceLevel:3, extraFeeds:{},
                         tryAllFeeds:false, dumpFeeds:false, configDir:"?user/config",
                         logMaxCount: 200, logMaxAge: 604800, logMaxSize:10*(10^6),
                         updateWaitTimeout: 30, updateOrphanTimeout: 600}
    }

    templateData = {
        maxDepth: 7,
        templates: {
            feedName:      {depth: 1, order: 1, key: "name"                                                  }
            baseUrl:       {depth: 1, order: 2, key: "baseUrl"                                               }
            namespace:     {depth: 3, order: 1, parentKeys: {macros:true, modules:true}                      }
            namespacePath: {depth: 3, order: 2, parentKeys: {macros:true, modules:true}, repl:"%.", to: "/"  }
            scriptName:    {depth: 3, order: 3, key: "name"                                                  }
            channel:       {depth: 5, order: 1, parentKeys: {channels:true}                                  }
            version:       {depth: 5, order: 2, key: "version"                                               }
            arch:          {depth: 5, order: 3, key: "arch"                                                  }
            fileName:      {depth: 7, order: 1, key: "name"                                                  }
            -- rolling templates
            fileBaseUrl:   {key: "fileBaseUrl", rolling: true                                                }
        }
        sourceAt: {}
    }
    -- precalculate some tables for the templater
    templateData.rolling = {n, true for n,t in pairs templateData.templates when t.rolling}
    templateData.sourceKeys = {t.key, t.depth for n,t in pairs templateData.templates when t.key}
    with templateData
        for i=1,.maxDepth
            .sourceAt[i], j = {}, 1
            for name, tmpl in pairs .templates
                if tmpl.depth==i and not tmpl.rolling
                    .sourceAt[i][j] = name
                    j += 1
            table.sort .sourceAt[i], (a,b) -> return .templates[a].order < .templates[b].order

    logger = Logger fileBaseName: @@__name, prefix: "[#{@@__name}] ", toFile: true, defaultLevel: depConf.globalDefaults.traceLevel
    dlm = DownloadManager!
    feedCache = {}
    configDirExists, logsHaveBeenTrimmed, reloadPending = false, false, false
    platform = "#{ffi.os}-#{ffi.arch}"

    @createDir depConf.file, true

    new: (args)=>
        {@requiredModules, moduleName:@moduleName, configFile:configFile, virtual:@virtual, name:@name,
         description:@description, url:@url, namespace:@namespace, feed:@feed, unmanaged:@unmanaged,
         author:@author, version:@version, configFile:@configFile} = args

        if @moduleName
            @namespace = @moduleName
            @type = "modules"

            -- global module registry allows for circular dependencies:
            -- set a dummy reference to this module since this module is not ready
            -- when the other one tries to load it (and vice versa)
            export LOADED_MODULES = {} unless LOADED_MODULES
            unless LOADED_MODULES[@moduleName]
                @ref = {}
                LOADED_MODULES[@moduleName] = setmetatable {}, @ref

        else
            @name, @description, @author, @version = script_name, script_description, script_author, script_version
            logger\assert not unmanaged, msgs.badRecordError, msgs.badRecord.noUnmanagedMacros
            logger\assert @namespace, msgs.badRecordError, msgs.badRecord.missingNamespace
            @type = "macros"

        logger\assert #namespaceValidation\find(@namespace) > 0, msgs.badRecord.badNamespace, @namespace
        @name = @namespace unless @name
        @configFile = configFile or "#{@namespace}.json"
        @version, err = @parse @version
        logger\assert @version, msgs.badRecordError, msgs.badRecord.badVersion\format err

        @requiredModules or= {}
        -- normalize short format module tables
        for i, mdl in pairs @requiredModules
            switch type mdl
                when "table"
                    mdl.moduleName or= mdl[1]
                    mdl[1] = nil
                when "string"
                    @requiredModules[i] = {moduleName: mdl}
                else logger\error msgs.badModuleRecord, i, tostring mdl

        firstInit, shouldWriteConfig = @loadConfig!

        -- write config file if contents are missing or are out of sync with the script version record
        -- ramp up the random wait time on first initialization (many scripts may want to write configuration data)
        -- we can't really profit from write concerting here because we don't know which module loads last
        hadReloadPending = @config.c.reloadPending
        @config.c.reloadPending = false

        @writeConfig firstInit and 5000 or 800, false, shouldWriteConfig or hadReloadPending

        logger.defaultLevel = @@config.c.traceLevel
        configDirExists or= @createDir @@config.c.configDir
        logsHaveBeenTrimmed or= @trimLogs!


    loadConfig: (forceReloadGlobal = false) =>
        -- load global config
        local firstInit
        if @@config
            @@config\load! if forceReloadGlobal
        else
            @@config = ConfigHandler depConf.file, depConf.globalDefaults, {"config"}, true
            firstInit = not @@config\load!

        -- load per-script config
        -- virtual modules are not yet present on the user's system and have no persistent configuration
        @config = ConfigHandler not @virtual and depConf.file, {}, {@type, @namespace}
        --  copy script information to the config
        shouldWriteConfig = not @virtual and @config\import @, depConf.scriptFields
        return firstInit, shouldWriteConfig

    writeConfig: (waitTime, concert = true, writeLocal, writeGlobal) =>
        if concert
            @@config\write true, waitTime
        else
            @@config\write false, waitTime if writeGlobal
            @config\write false, waitTime if writeLocal

    parse: (value) =>
        switch type value
            when "number" then return math.max value, 0
            when "nil" then return 0
            when "string"
                matches = {value\match "^(%d+).(%d+).(%d+)$"}
                if #matches!=3
                    return false, msgs.badVersionString\format value

                version = 0
                for i, part in ipairs semParts
                    value = tonumber(matches[i])
                    if type(value) != "number" or value>256
                        return false, msgs.versionOverflow\format part[1], tostring value
                    version += bit.lshift value, part[2]
                return version

            else return false, msgs.badVersionType\format type value

    get: (version = @version) =>
        parts = [bit.rshift(version, part[2])%256 for part in *semParts]
        return "%d.%d.%d"\format unpack parts

    getConfigFileName: () =>
        return aegisub.decode_path "#{@@config.c.configDir}/#{@configFile}"

    getConfigHandler: (defaults, section, noLoad) =>
        return ConfigHandler @getConfigFileName, default, section, noLoad

    getLogger: (args) =>
        args.fileBaseName or= @namespace
        args.toFile = @config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @config.c.logLevel
        args.prefix or= @moduleName and "[#{@name}]"

        return Logger args

    check: (value) =>
        if type(value) != "number"
            value, err = @parse value
            return nil, err unless value
        return @version >= value

    checkOptionalModules: (modules) =>
        modules = type(modules)=="string" and {[modules]:true} or {mdl,true for mdl in *modules}
        missing = [msgs.missingTemplate\format mdl.moduleName, mdl.version, mdl.url and ": #{mdl.url}" or "",
            mdl._reason or "" for mdl in *@requiredModules when mdl.optional and mdl._missing and modules[mdl.name]]

        if #missing>0
            downloadHint = msgs.missingModulesDownloadHint\format aegisub.decode_path "?user/automation/include"
            errorMsg = msgs.missingOptionalModules\format @name, table.concat(missing), downloadHint
            return false, errorMsg
        return true

    load: (mdl, usePrivate) =>
        moduleName = usePrivate and "#{@namespace}.#{mdl.moduleName}" or mdl.moduleName
        name = "#{mdl.name or mdl.moduleName}#{usePrivate and ' (Private Copy)' or ''}"

        -- pass already loaded modules as reference
        if LOADED_MODULES[moduleName]
            mdl._ref, mdl._missing = LOADED_MODULES[moduleName], false
            return mdl._ref

        loaded, res = pcall require, moduleName
        mdl._missing = not loaded and res\match "^module '.+' not found:"
        -- check for module errors
        unless loaded or mdl._missing
            logger\error msgs.moduleError, name, res

        if loaded
            mdl._ref, LOADED_MODULES[moduleName] = res, res
        return mdl._ref

    requireModules: (modules=@requiredModules, forceUpdate, returnErrorOnly, addFeeds={@feed}) =>
        for mdl in *modules
            with mdl
                ._ref, ._updated, ._missing, ._outdated, ._reason = nil, nil, nil, nil, nil
                -- try to load private copies of required modules first
                loaded = @load mdl, true
                loaded = @load mdl unless loaded

                unless loaded
                    -- try to fetch and load a missing module from the web
                    fetchedModule = @@{moduleName:.moduleName, name:.name or .moduleName,
                                       version:-1, url:.url, feed:.feed, virtual:true}
                    res, err, isPrivate = fetchedModule\update true, addFeeds
                    if res>0
                        @load mdl, isPrivate
                        ._updated = true
                    else
                        ._reason = @getUpdaterErrorMsg res, .name or .moduleName, true, true, err
                        LOADED_MODULES[.moduleName] = nil

                -- check version
                if .version and not ._missing
                    loadedVer = assert loaded.version, msgs.missingRecord\format(.moduleName)
                    if type(loadedVer)~="table" or loadedVer.__class~=@@
                        loadedVer = @@ moduleName:.moduleName, version:loadedVer, unmanaged:true

                    -- force an update check for outdated modules
                    if not loadedVer\check .version
                        -- module was freshly fetched/updated and still couldn't satisfy the version requirements
                        ._reason = msgs.updNoSuitableVersion\format loadedVer.name, loadedVer\get!, @name, .version
                        ._outdated = true
                        continue if ._updated

                        res, err, isPrivate = loadedVer\update true, addFeeds, true
                        if res > 0
                            if loadedVer\check .version
                                ._ref, ._outdated, ._reason = loadedVer._ref, false, nil
                        elseif res < 0 -- update failed, settle for the regular outdated message
                            ._reason = @getUpdaterErrorMsg res, .name or .moduleName, false, true, err
                        else ._reason = msgs.updNoSuitableUpdate\format loadedVer.name, loadedVer\get!, @name, .version

                    elseif loadedVer\update(forceUpdate, addFeeds) > 0 -- perform regular update
                        ._ref = loadedVer._ref
                    ._loaded = loadedVer
                else ._loaded = type(loaded) == "table" and loaded.version or true

        errorMsg = ""
        missing = [msgs.missingTemplate\format mdl.moduleName, mdl.version, mdl.url and ": #{mdl.url}" or "",
                   mdl._reason for mdl in *modules when mdl._missing and not mdl.optional]
        if #missing>0
            downloadHint = msgs.missingModulesDownloadHint\format aegisub.decode_path "?user/automation/include"
            errorMsg ..= msgs.missingModules\format @name, table.concat(missing), downloadHint

        outdated = [msgs.outdatedTemplate\format mdl.moduleName, mdl._loaded\get!, mdl.version, mdl.url and ": #{mdl.url}" or "",
                    mdl._reason for mdl in *modules when mdl._outdated]
        if #outdated>0
            errorMsg ..= msgs.outdatedModules\format @name, table.concat outdated

        if #errorMsg>0
            logger\error errorMsg if not returnErrorOnly
            return errorMsg

        return unpack [mdl._ref for mdl in *modules when mdl._loaded or mdl.optional] if not returnErrorOnly

    register: (selfRef) =>
        -- replace dummy refs with real refs to own module
        @ref.__index, @ref, LOADED_MODULES[@moduleName] = selfRef, selfRef, selfRef
        return selfRef

    registerMacro: (name=@name, description=@description, process, validate, isActive, useSubmenu) =>
        -- alternative signature
        if type(name)=="function"
            process, validate, isActive, useSubmenu = name, description, process, validate
            name, description = @name, @description

        menuName = {}
        menuName[1] = @config.c.customMenu if @config.c.customMenu
        menuName[#menuName+1] = @name if useSubmenu
        menuName[#menuName+1] = name

        -- check for updates before running a macro
        processHooked = (sub, sel) ->
            @update!
            return process sub, sel

        aegisub.register_macro table.concat(menuName, "/"), script_description, processHooked, validate, isActive

    registerMacros: (macros = {}, useSubmenuDefault = true) =>
        for macro in *macros
            useSubmenu = type(macro[1])=="function" and 4 or 6
            macro[useSubmenu] = useSubmenuDefault if macro[useSubmenu]==nil
            @registerMacro unpack(macro, 1, 6)

    getUpdaterErrorMsg: (code, name, ...) =>
        args = {...}
        if code <= -100
            -- Generic downstream error
            -- VarArgs: 1: isModule, 2: isFetch, 3: error msg
            return msgs.updateError[100]\format -code, msgs.updaterErrorComponent[math.floor(-code/100)],
                   args[2] and "fetch" or "update", args[1] and "module" or "macro", name, args[3]
        else
            -- Updater error:
            -- VarArgs: 1: isModule, 2: isFetch, 3: additional information
            return msgs.updateError[-code]\format args[2] and "fetch" or "update",
                                                  args[1] and "module" or "macro",
                                                  name, args[3]

    expandFeed: (feed) =>
        {:templates, :maxDepth, :sourceAt, :rolling, :sourceKeys} = templateData
        vars, rvars = {}, {i, {} for i=0, maxDepth}

        expandTemplates = (str, depth, rOff=0) ->
            return str\gsub "@{(.-)}", (name) ->
                return vars[name] or rvars[depth+rOff][name]

        recurse = (obj, depth = 1, parentKey = "", upKey = "") ->
            -- collect regular template variables first
            for name in *sourceAt[depth]
                with templates[name]
                    if not .key
                         -- template variables are not expanded if they are keys
                        vars[name] = parentKey if .parentKeys[upKey]
                    elseif .key and obj[.key]
                        -- expand other templates used in template variable
                        obj[.key] = expandTemplates obj[.key], depth
                        vars[name] = obj[.key]
                    vars[name] = vars[name]\gsub(.repl, .to) if .repl

            -- update rolling template variables last
            for name,_ in pairs rolling
                rvars[depth][name] = obj[templates[name].key] or rvars[depth-1][name] or ""
                rvars[depth][name] = expandTemplates rvars[depth][name], depth, -1
                obj[templates[name].key] and= rvars[depth][name]

            -- expand variables in non-template strings and recurse tables
            for k,v in pairs obj
                if sourceKeys[k] ~= depth and not rolling[k]
                    switch type v
                        when "string"
                            obj[k] = expandTemplates obj[k], depth
                        when "table"
                            recurse v, depth+1, k, parentKey
                            -- invalidate template variables created at depth+1
                            vars[name] = nil for name in *sourceAt[depth+1]
                            rvars[depth+1] = {}

        recurse feed
        return feed

    createDir: (path, isFile) =>
        dir = isFile and path\match("^(.+)[/\\].-$") or path
        mode, err = lfs.attributes dir, "mode"
        if err
            return false, msgs.createDir.genericError\format err
        elseif not mode
            res, err = lfs.mkdir dir
            if err -- can't create directory (possibly a permission error)
                return false, msgs.createDir.createError\format err
        elseif mode != "directory" -- a file of the same name as the target directory is already present
            return false, msgs.createDir.otherExists\format mode
        return dir

    moveFile: (source, target) =>
        mode, err = lfs.attributes target, "mode"
        if mode == "file"
            logger\log msgs.updateInfo.overwritingFile, target
            res, err = os.remove target
            unless res -- can't remove old target file, probably locked or lack of permissions
                return false, msgs.cantRemoveFile\format target, err
        elseif mode -- a directory (or something else) of the same name as the target file is already present
            return false, msgs.moveExistsNoFile\format source, target, mode
        elseif err  -- if retrieving the attributes of a file fails, something is probably wrong
            return false, msgs.moveGenericError\format source, target, err

        else -- target file not found, check directory
            dir, err = @createDir target, true
            unless dir
                return false, msgs.moveCreateDirError\format source, target, err
            logger\log msgs.updateInfo.createdDir, dir

        -- at this point the target directory exists and the target file doesn't, move the file
        res, err = os.rename source, target
        unless res -- renaming the file failed, probably a permission issue
            return false, msgs.cantRenameFile, source, target, err

        logger\log msgs.updateInfo.movedFile, source, target
        return true

    updateFromFeed: (feed, force = false) =>
        local feedData, feedFile
        if feedCache[feed]
            logger\log msgs.updUsingCached
            feedData = feedCache[feed]
        else
            feedFile = {aegisub.decode_path(@@config.c.dumpFeeds and "?user/" or "?temp"),
                        "l0.#{@@__name}_feed_", "%08X"\format(math.random 0, 16^8-1), ".json"}
            feedFilePath = table.concat feedFile

            dl, err = dlm\addDownload feed, feedFilePath
            unless dl
                logger\log @getUpdaterErrorMsg -105, @name, @moduleName, @virtual, err
                return -105, err

            dlm\waitForFinish (progress) ->
                logger\progress progress, msgs.updFetchingFeed, table.concat feedFile, "", 2
                return true
            logger\progress!
            if dl.error
                logger\log @getUpdaterErrorMsg -206, @name, @moduleName, @virtual, dl.error
                return -206, dl.error

            handle = io.open feedFilePath
            decoded, feedData = pcall json.decode, handle\read "*a"

            unless decoded and feedData
                logger\log @getUpdaterErrorMsg -7, @name, @moduleName, @virtual, feed
                return -7, feed
            else feedCache[feed] = @expandFeed feedData

            if @@config.c.dumpFeeds
                handle = io.open table.concat(feedFile, "", 1, 3)..".exp.json", "w"
                handle\write(json.encode feedData)\close!


        -- TODO: always check modules from own feed first
        -- TODO: for modules first look for private modules
        -- TODO: special handling for virtual versions

        scriptData = feedData[@type] and feedData[@type][@namespace]
        unless scriptData
            logger\log @getUpdaterErrorMsg -8, @name, @moduleName, @virtual
            return -8

        -- pick an update channel: user choice or the channel defined as default in the feed
        local data
        with @config.c
            .lastChannel, .channels = .activeChannel, {}
            for name, channel in pairs scriptData.channels
                .channels[#.channels+1] = name
                unless .lastChannel
                    .lastChannel = channel.default and name
            data = scriptData.channels[.lastChannel]

            unless data
                logger\log @getUpdaterErrorMsg -9, @name, @moduleName, @virtual, .lastChannel
                return -9, .lastChannel

        res, err = @check data.version
        if res == nil
            extErr = "#{@config.c.lastChannel}/#{tostring(data.version)}"
            logger\log @getUpdaterErrorMsg -13, @name, @moduleName, @virtual, extErr
            return -13, extErr
        elseif res
            logger\log msgs.updNoNewVersion, @moduleName and "Module" or "Macro", @name, @get!
            return 0

        -- force version check required modules first
        logger\log msgs.updateInfo.updateReqs
        logger.indent += 1
        err = @requireModules data.requiredModules or {}, true, true
        logger.indent -= 1
        if err
            logger\log @getUpdaterErrorMsg -15, @name, @moduleName, @virtual
            logger.indent += 1
            logger\log err
            logger.indent -= 1
            return -15, err

        platformExtErr = "#{platform};#{@config.c.lastChannel}"
        -- check if our platform is supported
        if data.platforms and not ({p,true for p in *data.platforms})[platform]
            logger\log @getUpdaterErrorMsg -20, @name, @moduleName, @virtual, platformExtErr
            return -20, platformExtErr

        -- check if any files are available for download
        files = data.files and [file for file in *data.files when not file.platform or file.platform == platform]
        unless files and #files>0
            logger\log @getUpdaterErrorMsg -25, @name, @moduleName, @virtual, platformExtErr
            return -25, platformExtErr


        -- download updated scripts to temp directory
        -- check hashes before download, only update changed files

        tmpDir = aegisub.decode_path "?temp/l0.#{@@__name}_#{'%04X'\format math.random 0, 16^4-1}"
        res, err = lfs.mkdir tmpDir
        if res or err
            extErr = "#{tmpDir} (#{err})"
            logger\log @getUpdaterErrorMsg -30, @name, @moduleName, @virtual, extErr
            return -30, extErr
        logger\log msgs.updateInfo.updateReady, tmpDir

        scriptSubDir = @moduleName and @moduleName\gsub("%.","/") or @namespace
        scriptDir = aegisub.decode_path "?user/automation/#{@moduleName and 'include' or 'autoload'}"
        baseName = "#{scriptDir}/#{scriptSubDir}"
        tmpBaseName = "#{tmpDir}/#{scriptSubDir}"

        dlm\clear!
        for file in *files
            tmpName, name, prettyName = tmpBaseName..file.name, baseName..file.name, scriptSubDir..file.name

            unless type(file.sha1)=="string" and #file.sha1 == 40 and tonumber(file.sha1, 16)
                extErr = "#{prettyName} (#{tostring(file.sha1)\lower!})"
                logger\log @getUpdaterErrorMsg -35, @name, @moduleName, @virtual, extErr
                return -35, extErr

            if dlm\checkFileSHA1 name, file.sha1
                logger\log msgs.updateInfo.fileUnchanged, prettyName
                continue

            dl, err = dlm\addDownload file.url, tmpName, file.sha1
            unless dl
                logger\log @getUpdaterErrorMsg -140, @name, @moduleName, @virtual, err
                return -140, err
            dl.targetFile = name
            logger\log msgs.updateInfo.fileAddDownload, file.url, prettyName

        dlm\waitForFinish (progress) ->
            logger\progress progress, msgs.updateInfo.filesDownloading, dlm.downloadCount
            return true
        logger\progress!

        if dlm.failedCount>0
            err = table.concat ["#{dl.url}: #{dl.error}" for dl in *dlm.failedDownloads], "\n —"
            logger\log @getUpdaterErrorMsg -245, @name, @moduleName, @virtual, err
            return -245, err

        logger\log msgs.updateInfo.movingFiles, scriptDir
        moveErrors = {}
        logger.indent += 1
        for dl in *dlm.downloads
            res, err = @moveFile dl.outfile, dl.targetFile
            -- don't immediately error out if moving of a single file failed
            -- try to move as many files as possible and let the user handle the rest
            moveErrors[#moveErrors+1] = err unless res
        logger.indent -= 1

        if #moveErrors>0
            extErr = table.concat moveErrors, "\n— "
            logger\log @getUpdaterErrorMsg -50, @name, @moduleName, @virtual, extErr
            return -50, err

        -- Update process finished


        -- Update script information/configuration
        {url:@url, author:@author, name:@name, description:@description} = scriptData
        @version = @parse data.version
        @requiredModules = data.requiredModules
        -- TODO: only set this flag if the script wasn't loaded before
        @config.c.reloadPending, reloadPending = true, true

        logger\log msgs.updSuccess, @virtual and "Download" or "Update",
                   @moduleName and "module" or "macro", @name, @get!
        @virtual = false

        -- display changelog
        if type(scriptData.changelog)=="table"
            changes = [{@parse(ver), entry} for ver, entry in pairs scriptData.changelog when @check ver]
            table.sort changes, (a,b) -> a[1]>b[1]
            if #changes>0
                logger\log msgs.updateInfo.changelog, @name, @get!, data.released or "<no date>"
                logger.indent += 1
                for chg in *changes
                    msg = type(chg[2]) ~= "table" and tostring(chg[2]) or table.concat chg[2], "\n • "
                    logger\logEx nil, "%s:\n • #{msg}", true, "", @get(chg[1])
                logger.indent -= 1

        logger\log msgs.updReloadNotice

        @writeConfig!

        -- TODO: platform specific file support
        -- TODO: additional variable: this feed url
        -- TODO: postpone update if other update in progress (lock file with macro as content)
        -- TODO: reload self: update global registry, return a new ref
        -- TODO: check handling of private module copies (need extra return value?)
        return 1, @get!

    update: (force = false, addFeeds = {}, tryAllFeeds = @virtual or @@config.c.tryAllFeeds) =>
        unless @@config.c.updaterEnabled
            logger\log @getUpdaterErrorMsg -1, @name, @moduleName, @virtual
            return -1

        -- don't do regular update checks for unmanaged modules because it's a waste of time
        if @unmanaged and not force
            logger\log @getUpdaterErrorMsg -2, @name, @moduleName, @virtual
            return -2

        if @config.c.lastUpdateCheck and (@config.c.lastUpdateCheck + @@config.c.updateInterval > os.time!) and not force
            return 0  -- the update interval has not yet been passed since the last update check

        @config.c.lastUpdateCheck = os.time!
        @config\write!
        logger\log @virtual and  msgs.updateInfo.fetching or msgs.updateInfo.starting, force and "forced " or "",
                   @moduleName and "module" or "macro", @name, not @virtual and @get!

        feeds = {}
        if @config.c.userFeed
            -- setting a userFeed for a module locks the module to that feed
            feeds[1] = @config.c.userFeed
        else
            feeds[1] = @feed
            feeds[#feeds+1] = feed for feed in *addFeeds
            feeds[#feeds+1] = feed for feed in *@@config.c.extraFeeds

        if #feeds==0
            logger\log @getUpdaterErrorMsg -3, @name, @moduleName, @virtual
            return -3

        -- check if an other update is already running
        -- wait our turn in forced mode, otherwise return an error

        @@config\load!
        running = @@config.c.updaterRunning
        if running and running.host != script_name
            otherHost = @@config.c.updaterRunning.host

            if running.time + @@config.c.updateOrphanTimeout < os.time!
                logger\log msgs.updateInfo.orphaned, otherHost
            elseif force or @virtual
                logger\log msgs.updateInfo.waiting, otherHost
                timeout = @@config.c.updateWaitTimeout
                while running and timeout > 0
                    PreciseTimer\sleep 1000*math.min 1, timeout
                    timeout -= 1
                    @@config\load!
                    running = @@config.c.updaterRunning
                logger\log timeout <= 0 and msgs.updateInfo.abortWait or msgs.updateInfo.waitFinished,
                           @@config.c.updateWaitTimeout

                -- check if a virtual module has been installed in the meantime
                -- and clear the flag if associated configuration was found
                if @virtual
                    @config\setFile depConf.file
                    if @config\load!
                        logger\log timeout msgs.updateInfo.unsetVirtual, otherHost,
                                   @moduleName and "module" or "macro", @name
                        @virtual = false
                    else @config\unsetFile depConf.file
                else @config\load!

                -- reload important module version information from configuration
                -- because the values we have might not be up-to-date anymore
                if @config.c.reloadPending and not @virtual
                    {moduleName:@moduleName, name:@name, namespace:@namespace,
                     feed:@feed, unmanaged:@unmanaged, version:@version} = @config.c
                    reloadPending = true

            else
                logger\log @getUpdaterErrorMsg -4, @name, @moduleName, @virtual, running.host
                return -4, running.host

        -- register the running update in the config file to prevent collisions
        -- with other scripts trying to update the same modules

        @@config.c.updaterRunning = host: script_name, time: os.time!
        @@config\write!

        minRes, minErr, res = 0
        logger\log msgs.updateInfo.feedCandidates, #feeds, tryAllFeeds and "exhaustive" or "normal"
        for i, feed in ipairs feeds
            logger\log msgs.updateInfo.feedTrying, i, #feeds, feed
            res, err = @updateFromFeed feed, force
            -- ignore up-to-date result and try other feeds when tryAllFeeds is set
            break if res > (tryAllFeeds and 0 or -1)
            -- since we have multiple possible error states (one for every feed)
            -- return the one that's the farthest in to the updates process
            normRes = -(-res%100)
            if res <0 and normRes < minRes
                minRes, minErr = res, err

        @@config.c.updaterRunning = false
        @@config\write!

        if res<0
            return minRes, minErr

        return res, err

    trimLogs: (doWipe, maxAge = @@config.c.logMaxAge, maxSize = @@config.c.logMaxSize, maxLogs = @@config.c.logMaxCount) =>
        files, totalSize, deletedSize, now = {}, 0, 0, os.time!

        for file in lfs.dir @@config.c.configDir
            attr = lfs.attributes file
            if type(attr) == "table" and attr.mode == "file" and file\find Logger.fileMatchTemplate
                count += 1
                file[count] = {name:file, modified:attr.modification, size:attr.size}

        table.sort files, (a,b) -> a.modified > b.modified
        total, kept = #files, 0

        for i, file in ipairs files
            totalSize += file.size
            if doWipe or kept > maxLogs or totalSize > maxSize or file.modified+maxAge < now
                deletedSize += file.size
                os.remove file
            else
                kept += 1

        return total-kept, deletedSize, total, totalSize

DependencyControl.__class.version = DependencyControl{
    name: "DependencyControl",
    version: "0.1.0",
    description: "Dependency Management for Aegisub macros and modules",
    author: "line0",
    url: "http://github.com/TypesettingCartel/DependencyControl",
    moduleName: "l0.DependencyControl"
}

return DependencyControl