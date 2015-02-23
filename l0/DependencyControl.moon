json = require "json"
lfs = require "lfs"
ffi = require "ffi"
Logger = require "l0.Logger"
PreciseTimer = require "PreciseTimer.PreciseTimer"
DownloadManager = require "DownloadManager.DownloadManager"

class DependencyControl
    semParts = {{"major", 16}, {"minor", 8}, {"patch", 0}}
    namespaceValidation = re.compile "^(?:[-\\w]+\\.)+[-\\w]+$"
    msgs = {
        missingModules: "Error: one or more of the modules required by %s could not be found on your system:\n%s\n%s"
        missingOptionalModules: "Error: a %s feature you're trying to use requires additional modules that were not found on your system:\n%s\n%s"
        missingModulesDownloadHint: "Please download the modules in question, put them in your %s folder and reload your automation scripts."
        missingTemplate: "— %s (v%s+)%s\n—— Reason: %s"
        outdatedModules: "Error: one or more of the modules required by %s are outdated on your system:
%s\nPlease update the modules in question manually and reload your automation scripts."
        outdatedTemplate: "— %s (Installed: v%s; Required: v%s)%s\n—— Reason: %s"
        missingRecord: "Error: module '%s' is missing a version record."
        moduleError: "Error in module %s:\n%s"
        badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        badVersionString: "Error: can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
        versionOverflow: "Error: %s version must be an integer < 255, got %s."
        updNoSuitableVersion: "The version of '%s' downloaded (v%s) did not satisfy the %s requirements (v%s)."
        updNoSuitableUpdate: "The installed version of '%s'(v%s) did not satisfy the %s requirements (v%s), but no update could be found."
        updNoNewVersion: "%s '%s' (v%s) is up-to-date."
        updUsingCached: "Using cached feed."
        updFetchingFeed: "Downloading feed to %s "
        updSuccess: "%s of %s '%s' (v%s) complete."
        updReloadNotice: "Please rescan your autoload directory for the changes to take effect."
        moveExistsNoFile: "Couldn't move file '%s' to '%s' because a %s of the same name is already present."
        moveExistsNoDir: "Couldn't create directory '%s' because a %s of the same name is already present. File '%s' not moved to '%s'"
        moveGenericError: "An error occured while moving file '%s' to '%s':\n%s"
        moveCreateDirError: "Couldn't create directory '%s' (%s), file '%s' not moved to '%s'.",
        cantRemoveFile: "Couldn't overwrite file '%s': %s"
        cantRenameFile: "Couldn't move file '%s' to '%s': %s"
        updateInfo: {
            starting: "Starting %supdate of %s '%s' (v%s)... ",
            fetching: "Trying to %sfetch missing %s '%s'...",
            updateReqs: "Checking requirements...",
            feedCandidates: "Trying %d candidate feeds (%s mode)...",
            feedTrying: "Checking feed %d/%d (%s)...",
            tempDir: "Downloading files into temporary folder '%s'...",
            filesDownloading: "Downloading %d files...",
            fileUnchanged: "Skipped unchanged file '%s'.",
            fileAddDownload: "Addeding Download %s ==> '%s'.",
            updateReady: "Update ready. Using temporary directory '%s'.",
            movingFiles: "Downloads complete. Now moving files to Aegisub automation directory '%s'..."
        }
        updateError: {
            [1]: "Couldn't %s %s '%s' because the updater is disabled.",
            [2]: "Skipping %s of unmanaged %s '%s'.",
            [3]: "No feed available to %s %s '%s' from.",
            [7]: "Couldn't %s %s '%s': error parsing feed %s.",
            [8]: "The specified feed doesn't have the required data to %s the %s '%s'.",
            [9]: "Couldn't %s %s '%s' because the specified channel '%s' wasn't present in the feed.",
            [10]: "Couldn't %s %s '%s' because its requirements could not be satisfied:",
            [11]: "Couldn't %s %s '%s': unsupported platform (%s).",
            [12]: "Couldn't %s %s '%s' because the feed doesn't specify any files for your platform (%s).",
            [13]: "Couldn't %s %s '%s': failed to create temporary download directory %s",
            [14]: "Aborted %s of %s '%s' because the feed contained a missing or malformed SHA-1 hash for file %s."
            [17]: "Couldn't finish %s of %s '%s' because some files couldn't be moved to their target location:\n—"
            [100]: "Error in component %s during %s of %s '%s':\n — %s"
        }
        updaterErrorComponent: {"DownloadManager", "cURL"}
    }
    depConf = {
        file: aegisub.decode_path "?user/#{@@__name}.json",
        scriptFields: {"author", "configFile", "feed", "moduleName", "name", "namespace", "url",
                       "requiredModules", "version", "unmanaged"},
        ignoreFields: {ref:true, config:true, virtual:true, type:true},
        globalDefaults: {updaterEnabled:true, updateInterval:302400, traceLevel:3, extraFeeds:{},
                         tryAllFeeds:false, dumpFeeds:true}
    }

    templateData = {
        maxDepth: 7,
        templates: {
            feedName:      {depth: 1, order: 1, key: "name"                                                  }
            baseURL:       {depth: 1, order: 2, key: "baseURL"                                               }
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
            assert not unmanaged, "Error: creating unmanaged version records for macros is not allowed."
            assert @namespace, "Error: namespace required"
            @type = "macros"

        assert #namespaceValidation\find(@namespace) > 0, msgs.badNamespace\format @namespace
        @name = @namespace unless @name
        @configFile = configFile or "#{@namespace}.json"
        @version = @parse @version

        @loadConfig!
        logger.defaultLevel = @@config.traceLevel
        @@config.platform = "#{ffi.os}-#{ffi.arch}"

    loadConfig: (forceReloadGlobal=false) =>
        return false if @virtual and @@config and not forceReloadGlobal

        handle = io.open depConf.file, "r"
        config = handle and json.decode handle\read "*a"
        handle\close!
        needUpdateConfig = {false, not config}

        -- load global config and fill in missing default config values
        unless @@config and not forceReloadGlobal
            @@config = config and config.config or {}
            for k,v in pairs depConf.globalDefaults
                if @@config[k] == nil
                    @@config[k], needUpdateConfig[2] = v, true

        -- load per-script config
        -- virtual modules are not yet present on the user's system and have no persistent configuration
        if @virtual
            @config = {}
        else
            @config = config and config[@type][@namespace] or {}
            needUpdateConfig[1] = @updateScriptConfigFields!

        -- write config file if contents are missing or are out of sync with the script version record
        @writeConfig unpack needUpdateConfig

    writeConfig: (writeLocal=true, writeGlobal=false) =>
        writeLocal or= @updateScriptConfigFields!
        unless writeLocal or writeGlobal return false

        -- first module ever registered is always DependencyControl
        configScheme = {config: @@config, modules: {[@@version and @@version.moduleName or @moduleName]: @}, macros: {}}

        -- avoid concurrent config file access
        -- TODO: better and actually safe implementation
        PreciseTimer\sleep math.random!*30 for i=1,20
        lockFile, limit = depConf.file..".lock", 50
        locked = lfs.attributes lockFile, "mode"
        while locked and limit>0
            PreciseTimer\sleep 100
            locked = lfs.attributes lockFile, "mode"
            limit -= 1
        lfs.touch lockFile

        handle, config = io.open depConf.file, "r"

        if handle
            config = json.decode(handle\read "*a") or {}
            handle\close!
            for k,v in pairs configScheme
                config[k] = v unless config[k]

            config.config = @@config if writeGlobal
            if writeLocal and not @virtual
                config[@type][@namespace] = {k,v for k,v in pairs @config when not depConf.ignoreFields[k]}
        else config = configScheme

        handle = io.open(depConf.file, "w")\write(json.encode config)
        handle\flush!
        handle\close!
        os.remove lockFile

    updateScriptConfigFields: =>
        needUpdateConfig = false
        for k in *depConf.scriptFields
            unless @config[k]==@[k] or type(@[k])=="table" and type(@config[k])=="table" and #@[k] == #@config[k]
                @config[k], needUpdateConfig = @[k], true
        return needUpdateConfig

    parse: (value) =>
        return value if type(value)=="number"
        return 0 if not value or type(value)~="string"

        matches = {value\match "^(%d+).(%d+).(%d+)$"}
        assert #matches==3, msgs.badVersionString\format value

        version = 0
        for i, part in ipairs semParts
            value = tonumber(matches[i])
            assert type(value)=="number" and value<256, msgs.versionOverflow\format(part[1], tostring value)
            version += bit.lshift value, part[2]

        return version

    get: =>
        parts = [bit.rshift(@version, part[2])%256 for part in *semParts]
        return "%d.%d.%d"\format unpack parts

    getConfigFileName: () =>
        return aegisub.decode_path "?user/#{@configFile}"

    check: (value) =>
        if type(value)=="string"
            value = @parse value
        return @version>=value

    checkOptionalModules: (modules, noAssert) =>
        modules = type(modules)=="string" and {[modules]:true} or {mdl,true for mdl in *modules}
        missing = [msgs.missingTemplate\format mdl[1], mdl.version, mdl.url and ": #{mdl.url}" or "",
            mdl.reason or "" for mdl in *@requiredModules when mdl.optional and mdl.missing and modules[mdl.name]]

        if #missing>0
            downloadHint = msgs.missingModulesDownloadHint\format aegisub.decode_path "?user/automation/include"
            errorMsg = msgs.missingOptionalModules\format @name, table.concat(missing), downloadHint
            return errorMsg if noAssert
            logger\error errorMsg
        return nil

    load: (mdl, usePrivate) =>
        moduleName = usePrivate and "#{@namespace}.#{mdl[1]}" or mdl[1]
        name = "#{mdl.name or mdl[1]}#{usePrivate and ' (Private Copy)'}"

        -- pass already loaded modules as reference
        if LOADED_MODULES[moduleName]
            mdl.ref, mdl.missing = LOADED_MODULES[moduleName], false
            return mdl.ref

        loaded, res = pcall require, moduleName
        mdl.missing = not loaded and res\match "^module '.+' not found:"
        -- check for module errors
        assert loaded or mdl.missing, msgs.moduleError\format(name, res)

        if loaded
            mdl.ref, LOADED_MODULES[moduleName] = res, res
        return mdl.ref

    requireModules: (modules=@requiredModules, forceUpdate, returnErrorOnly) =>
        for i,mdl in ipairs modules
            if type(mdl)=="string"
                modules[i] = {mdl}
                mdl = modules[i]
            elseif mdl["1"]
                mdl[1] = mdl["1"]  -- artifact of lua->json->lua

            -- try to load private copies of required modules first
            loaded = @load mdl, true
            loaded = @load mdl unless loaded

            with mdl
                unless loaded
                    -- try to fetch and load a missing module from the web
                    fetchedModule = @@ moduleName:mdl[1], name:.name or mdl[1], version:-1, url:.url, feed:.feed, virtual:true
                    res, err, isPrivate = fetchedModule\update true, {@feed}
                    if res>0
                        @load mdl, isPrivate
                        .updated = true
                    else
                        .reason = @getUpdaterErrorMsg res, .name or mdl[1], true, true, err
                        LOADED_MODULES[mdl[1]] = nil

                -- check version
                if .version and not .missing
                    loadedVer = assert loaded.version, msgs.missingRecord\format(mdl[1])
                    if type(loadedVer)~="table" or loadedVer.__class~=@@
                        loadedVer = @@ moduleName:mdl[1], version:loadedVer, unmanaged:true

                    -- force an update check for outdated modules
                    if not loadedVer\check .version
                        -- module was freshly fetched/updated and still couldn't satisfy the version requirements
                        .reason = msgs.updNoSuitableVersion\format loadedVer.name, loadedVer\get!, @name, .version
                        .outdated = true
                        continue if .updated

                        res, err, isPrivate = loadedVer\update true, {@feed}, true
                        if res > 0
                            if loadedVer\check .version
                                .ref, .outdated, .reason = loadedVer.ref, false, nil
                        elseif res < 0 -- update failed, settle for the regular outdated message
                            .reason = @getUpdaterErrorMsg res, .name or mdl[1], false, true, err
                        else .reason = msgs.updNoSuitableUpdate\format loadedVer.name, loadedVer\get!, @name, .version

                    elseif loadedVer\update(forceUpdate) > 0 -- perform regular update
                        .ref = loadedVer.ref
                    .loaded = loadedVer
                else .loaded = type(loaded)=="table" and loaded.version or true

        errorMsg = ""
        missing = [msgs.missingTemplate\format mdl[1], mdl.version, mdl.url and ": #{mdl.url}" or "",
                   mdl.reason for mdl in *modules when mdl.missing and not mdl.optional]
        if #missing>0
            downloadHint = msgs.missingModulesDownloadHint\format aegisub.decode_path "?user/automation/include"
            errorMsg ..= msgs.missingModules\format @name, table.concat(missing), downloadHint

        outdated = [msgs.outdatedTemplate\format mdl[1], mdl.loaded\get!, mdl.version, mdl.url and ": #{mdl.url}" or "",
                    mdl.reason for mdl in *modules when mdl.outdated]
        if #outdated>0
            errorMsg ..= msgs.outdatedModules\format @name, table.concat outdated

        if #errorMsg>0
            error errorMsg if not returnErrorOnly
            return errorMsg

        return unpack [mdl.ref for mdl in *modules when mdl.loaded or mdl.optional] if not returnErrorOnly

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
        menuName[1] = @config.customMenu if @config.customMenu
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
            return msgs.updateError[100]\format msgs.updaterErrorComponent[math.floor(-code/100)], args[2] and "fetch" or "update",
                   args[1] and "module" or "macro", name, args[3]
        else
            -- Updater error:
            -- VarArgs: 1: isModule, 2: isFetch, 3: additional information
            error tostring(code) unless msgs.updateError[-code]
            return msgs.updateError[-code]\format args[2] and "fetch" or "update", args[1] and "module" or "macro",
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
                rvars[depth][name] = obj[templates[name].key] or rvars[depth-1][name]
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

    moveFile: (source, target) =>
        -- msg: moving file
        mode, err = lfs.attributes target, "mode"
        if mode == "file"
            -- msg: file already exists, overwriting
            res, err = os.remove target
            unless res -- can't remove old target file, probably locked or lack of permissions
                return false, msgs.cantRemoveFile\format target, err
        elseif mode -- a directory (or something else) of the same name as the target file is already present
            return false, msgs.moveExistsNoFile\format source, target, mode
        elseif err  -- if retrieving the attributes of a file fails, something is probably wrong
            return false, msgs.moveGenericError\format source, target, err

        else -- target file not found, check directory
            dir = dl.targetFile\match "^(.+)[/\\].-$"
            mode, err = lfs.attributes dir, "mode"
            if err
                return false, msgs.moveGenericError\format source, target, err
            elseif not mode
                -- msg: target directory doesn't exist, create it
                res, err = lfs.mkdir dir
                if err -- can't create directory (possibly a permission error)
                    return false, msgs.moveCreateDirError\format dir, err, dl.outfile, dl.targetFile
            elseif mode != "directory" -- a file of the same name as the target directory is already present
                return false, msgs.moveExistsNoDir\format dir, mode, source, target

        -- at this point the target directory exists and the target file doesn't, move the file
        res, err = os.rename source target
        unless res -- renaming the file failed, probably a permission issue
            return false, msgs.cantRenameFile, source, target, err

        return true

    updateFromFeed: (feed, force = false) =>
        local feedData
        if feedCache[feed]
            logger\log msgs.updUsingCached
            feedData = feedCache[feed]
        else
            feedFile = {aegisub.decode_path("?user/"), "l0.#{@@__name}_feed_",
                        @@config.dumpFeeds and "%08X"\format(math.random 0, 16^8-1) or "latest", ".json"}
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

            if @@config.dumpFeeds
                handle = io.open table.concat(feedFile, "", 1, 3).."exp.json", "w"
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
        with @config
            .lastChannel, .channels = .activeChannel, {}
            for name, channel in pairs scriptData.channels
                .channels[#.channels+1] = name
                unless .lastChannel
                    .lastChannel = channel.default and name
            data = scriptData.channels[.lastChannel]

            unless data
                logger\log @getUpdaterErrorMsg -9, @name, @moduleName, @virtual, .lastChannel
                return -9, .lastChannel

        if @check data.version
            logger\log msgs.updNoNewVersion, @moduleName and "Module" or "Macro", @name, @get!
            return 0

        -- force version check required modules first
        logger\log msgs.updateInfo.updateReqs
        logger.indent += 1
        err = @requireModules data.requiredModules or {}, true, true
        logger.indent -= 1
        if err
            logger\log @getUpdaterErrorMsg -10, @name, @moduleName, @virtual
            logger.indent += 1
            logger\log err
            logger.indent -= 1
            return -10, err

        platformExtErr = "#{@@config.platform};#{@config.lastChannel}"
        -- check if our platform is supported
        if data.platforms and not ({p,true for p in *data.platforms})[@@config.platform]
            logger\log @getUpdaterErrorMsg -11, @name, @moduleName, @virtual, platformExtErr
            return -11, extErr

        -- check if any files are available for download
        unless data.files
            extErr = "#{@@config.platform};#{@config.lastChannel}"
            logger\log @getUpdaterErrorMsg -12, @name, @moduleName, @virtual, platformExtErr
            return -12, extErr

        -- download updated scripts to temp directory
        -- check hashes before download, only update changed files

        tmpDir = aegisub.decode_path "?temp/l0.#{@@__name}_#{'%04X'\format math.random 0, 16^4-1}"
        res, err = lfs.mkdir tmpDir
        if res or err
            extErr = "#{tmpDir} (#{err})"
            logger\log @getUpdaterErrorMsg -13, @name, @moduleName, @virtual, extErr
            return -13, extErr
        logger\log msgs.updateInfo.updateReady, tmpDir

        scriptSubDir = @moduleName and @moduleName\gsub("%.","/") or @namespace
        scriptDir = aegisub.decode_path "?user/automation/#{@moduleName and 'include' or 'autoload'}"
        baseName = "#{scriptDir}/#{@scriptSubDir}"
        tmpBaseName = "#{tmpDir}/#{@scriptSubDir}"

        dlm\clear!
        for file in *data.files
            tmpName, name, prettyName = tmpBaseName..file.name, baseName..file.name, scriptSubDir..file.name

            unless type(file.sha1)=="string" and #file.sha1 == 40 and tonumber(file.sha1, 16)
                extErr = "#{prettyName} (#{tostring(file.sha1)\lower!})"
                logger\log @getUpdaterErrorMsg -14, @name, @moduleName, @virtual, extErr
                return -14, extErr

            if dlm\checkFileSHA1 name, file.sha1
                logger\log msgs.updateInfo.fileUnchanged, prettyName
                continue

            logger\log msgs.updateInfo.fileAddDownload, file.url, prettyName
            dl, err = dlm\addDownload file.url, tmpName, file.sha1
            unless id
                logger\log @getUpdaterErrorMsg -115, @name, @moduleName, @virtual, err
                return -115, err
            dl.targetFile = name

        dlm\waitForFinish (progress) ->
            logger\progress progress, updateInfo.filesDownloading, dlm.downloadCount
            return true
        logger\progress!

        if dlm.failedCount>0
            err = table.concat ["#{dl.url}: #{dl.error}" for dl in *dlm.failedDownloads], "\n —"
            logger\log @getUpdaterErrorMsg -216, @name, @moduleName, @virtual, err
            return -216, err

        logger\log msgs.updateInfo.movingFiles, scriptDir
        moveErrors = {}
        for dl in *dlm.downloads
            res, err = @moveFile dl.outfile, dl.targetFile
            -- don't immediately error out if moving of a single file failed
            -- try to move as many files as possible and let the user handle the rest
            moveErrors[#moveErrors+1] = err unless res

        if #moveErrors>0
            extErr = table.concat moveErrors, "\n— "
            logger\log @getUpdaterErrorMsg -17, @name, @moduleName, @virtual, extErr
            return -17, err

        -- Update process finished


        -- Update script information/configuration
        -- TODO: check json [1]->["1"] issue in requiredModules
        {url:@url, author:@author, name:@name, description:@description} = scriptData
        @version = @parse data.version
        @requiredModules = data.requiredModules
        -- TODO: only set this flag if the script wasn't loaded before
        @config.needsReload = true

        logger\log msgs.updSuccess, @virtual and "Download" or "Update",
                   @moduleName and "module" or "macro", @name, @get!
        @virtual = false

        -- TODO: display changelog
        logger\log msgs.updReloadNotice

        @writeConfig!

        -- TODO: reload self: update global registry, return a new ref
        -- TODO: check handling of private module copies (need extra return value?)
        return 1, @get!

    update: (force = false, addFeeds = {}, tryAllFeeds = @virtual or @@config.tryAllFeeds) =>
        unless @@config.updaterEnabled
            logger\log @getUpdaterErrorMsg -1, @name, @moduleName, @virtual
            return -1

        -- don't do regular update checks for unmanaged modules because it's a waste of time
        if @unmanaged and not force
            logger\log @getUpdaterErrorMsg -2, @name, @moduleName, @virtual
            return -2

        if @config.lastUpdateCheck and (@config.lastUpdateCheck + @@config.updateInterval > os.time!) and not force
            return 0  -- the update interval has not yet been passed since the last update check

        @config.lastUpdateCheck = os.time!
        logger\log @virtual and  msgs.updateInfo.fetching or msgs.updateInfo.starting, force and "forced " or "",
                   @moduleName and "module" or "macro", @name, not @virtual and @get!

        feeds = {}
        if @config.userFeed
            -- setting a userFeed for a module locks the module to that feed
            feeds[1] = @config.userFeed
        else
            feeds[1] = @feed
            feeds[#feeds+1] = feed for feed in *addFeeds
            feeds[#feeds+1] = feed for feed in *@@config.extraFeeds

        if #feeds==0
            logger\log @getUpdaterErrorMsg -3, @name, @moduleName, @virtual
            return -3

        minRes, minErr, res = 0
        logger\log msgs.updateInfo.feedCandidates, #feeds, tryAllFeeds and "exhaustive" or "normal"
        for i, feed in ipairs feeds
            logger\log msgs.updateInfo.feedTrying, i, #feeds, feed
            res, err = @updateFromFeed feed, force
            -- ignore up-to-date result and try other feeds when tryAllFeeds is set
            break if res > (tryAllFeeds and 0 or -1)
            -- since we have multiple possible error states (one for every feed)
            -- return the one that's the farthest in to the updates process
            if res%100 < res
                minRes, minErr = res, err

        if res<0
            return minRes, minErr

        return res, err

DependencyControl.__class.version = DependencyControl{
    name: "DependencyControl",
    version: "0.1.0",
    description: "Dependency Management for Aegisub macros and modules",
    author: "line0",
    url: "http://github.com/TypesettingCartel/DependencyControl",
    moduleName: "l0.DependencyControl"
}

return DependencyControl