json = require "json"
lfs =  require "lfs"
re =   require "aegisub.re"

Common =         require "l0.DependencyControl.Common"
Logger =         require "l0.DependencyControl.Logger"
ConfigHandler =  require "l0.DependencyControl.ConfigHandler"
FileOps =        require "l0.DependencyControl.FileOps"
Updater =        require "l0.DependencyControl.Updater"
ModuleLoader =   require "l0.DependencyControl.ModuleLoader"

class Record extends Common
    semParts = {{"major", 16}, {"minor", 8}, {"patch", 0}}
    namespaceValidation = re.compile "^(?:[-\\w]+\\.)+[-\\w]+$"

    msgs = {
        parseVersion: {
            badString: "Can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
            badType: "Argument had the wrong type: expected a string or number, got a %s. Content %s"
            overflow: "Error: %s version must be an integer < 255, got %s."
        }
        new: {
            badRecordError: "Error: Bad #{@@__name} record (%s)."
            badRecord: {
                noUnmanagedMacros: "Creating unmanaged version records for macros is not allowed"
                missingNamespace: "No namespace defined"
                badVersion: "Couldn't parse version number: %s"
                badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
                badModuleTable: "Invalid required module table #%d (%s)."
            }
        }
        uninstall: {
            noVirtualOrUnmanaged: "Can't uninstall %s %s '%s'. (Only installed scripts managed by #{@@__name} can be uninstalled)."
        }
        writeConfig: {
            error: "An error occured while writing the #{@@__name} config file: %s"
            writing: "Writing updated %s data to config file..."
        }
    }

    @depConf = {
        file: aegisub.decode_path "?user/config/l0.#{@@__name}.json",
        scriptFields: {"author", "configFile", "feed", "moduleName", "name", "namespace", "url", -- REMOVE
                       "requiredModules", "version", "unmanaged"},
        globalDefaults: {updaterEnabled:true, updateInterval:302400, traceLevel:3, extraFeeds:{},
                         tryAllFeeds:false, dumpFeeds:true, configDir:"?user/config",
                         logMaxFiles: 200, logMaxAge: 604800, logMaxSize:10*(10^6),
                         updateWaitTimeout: 60, updateOrphanTimeout: 600,
                         logDir: "?user/log", writeLogs: true}
    }

    init = =>
        FileOps.mkdir @depConf.file, true
        @loadConfig!
        @logger = Logger { fileBaseName: "DepCtrl", fileSubName: script_namespace, prefix: "[#{@@__name}] ",
                             toFile: @config.c.writeLogs, defaultLevel: @config.c.traceLevel,
                             maxAge: @config.c.logMaxAge,maxSize: @config.c.logMaxSize, maxFiles: @config.c.logMaxFiles,
                             logDir: @config.c.logDir }

        @updater = Updater script_namespace, @config, @logger
        @configDir = @config.c.configDir

        FileOps.mkdir aegisub.decode_path @configDir
        logsHaveBeenTrimmed or= @logger\trimFiles!
        FileOps.runScheduledRemoval @configDir


    new: (args) =>
        init Record unless @@logger

        -- defaults
        args[k] = v for k, v in pairs {
            readGlobalScriptVars: true
            saveRecordToConfig: true
        } when args[k] == nil

        {@requiredModules, moduleName:@moduleName, configFile:configFile, virtual:@virtual, :name,
         description:@description, url:@url, feed:@feed, recordType:@recordType, :namespace,
         author:@author, :version, configFile:@configFile,
         :readGlobalScriptVars, :saveRecordToConfig} = args

        @recordType or= @@RecordType.Managed
        -- also support name key (as used in configuration) for required modules
        @requiredModules or= args.requiredModules

        if @moduleName
            @namespace = @moduleName
            @name = name or @moduleName
            @scriptType = @@ScriptType.Module
            ModuleLoader.createDummyRef @ unless @virtual or @recordType == @@RecordType.Unmanaged

        else
            if @virtual or not readGlobalScriptVars
                @name = name or namespace
                @namespace = namespace
                version or= 0
            else
                @name = name or script_name
                @description or= script_description
                @author or= script_author
                version or= script_version

            @namespace = namespace or script_namespace
            assert @recordType == @@RecordType.Managed, msgs.new.badRecordError\format msgs.new.badRecord.noUnmanagedMacros
            assert @namespace, msgs.new.badRecordError\format msgs.new.badRecord.missingNamespace
            @scriptType = @@ScriptType.Automation

        -- if the hosting macro doesn't have a namespace defined, define it for
        -- the first DepCtrled module loaded by the macro or its required modules
        unless script_namespace
            export script_namespace = @namespace

        -- non-depctrl record don't need to conform to namespace rules
        assert @virtual or @recordType == @@RecordType.Unmanaged or @validateNamespace!,
               msgs.new.badRecord.badNamespace\format @namespace

        @configFile = configFile or "#{@namespace}.json"
        @automationDir = @@automationDir[@scriptType]
        @testDir = @@testDir[@scriptType]
        @version, err = @@parseVersion version
        assert @version, msgs.new.badRecordError\format msgs.new.badRecord.badVersion\format err

        @requiredModules or= {}
        -- normalize short format module tables
        for i, mdl in pairs @requiredModules
            switch type mdl
                when "table"
                    mdl.moduleName or= mdl[1]
                    mdl[1] = nil
                when "string"
                    @requiredModules[i] = {moduleName: mdl}
                else error msgs.new.badRecordError\format msgs.new.badRecord.badModuleTable\format i, tostring mdl

        shouldWriteConfig = @loadConfig!

        -- write config file if contents are missing or are out of sync with the script version record
        -- ramp up the random wait time on first initialization (many scripts may want to write configuration data)
        -- we can't really profit from write concerting here because we don't know which module loads last
        @writeConfig if shouldWriteConfig and saveRecordToConfig

    checkOptionalModules: ModuleLoader.checkOptionalModules

    -- loads the DependencyControl global configuration
    @loadConfig = =>
        if @config
            @config\load!
        else @config = ConfigHandler @depConf.file, @depConf.globalDefaults, {"config"}, nil, @logger

    -- loads the script configuration
    loadConfig: (importRecord = false) =>
        -- virtual modules are not yet present on the user's system and have no persistent configuration
        @config or= ConfigHandler not @virtual and @@depConf.file, {},
                    { @@ScriptType.name.legacy[@scriptType], @namespace }, true, @@logger

        -- import and overwrites version record from the configuration
        if importRecord
            -- check if a module that was previously virtual was installed in the meantime
            -- TODO: prevent issues caused by orphaned config entries
            haveConfig = false
            if @virtual
                @config\setFile @@depConf.file
                if @config\load!
                    haveConfig, @virtual = true, false
                else @config\unsetFile!
            else
                haveConfig = @config\load!

            -- only need to refresh data if the record was changed by an update
            if haveConfig
                @[key] = @config.c[key] for key in *@@depConf.scriptFields

        elseif not @virtual
            --  copy script information to the config
            @config\load!
            shouldWriteConfig = @config\import @, @@depConf.scriptFields, false, true
            return shouldWriteConfig

        return false

    writeConfig: =>
        unless @virtual or @config.file
            @config\setFile @@depConf.file

        @@logger\trace msgs.writeConfig.writing, @@terms.scriptType.singular[@scriptType]
        @config\import @, @@depConf.scriptFields, false, true
        success, errMsg = @config\write false

        assert success, msgs.writeConfig.error\format errMsg

    @parseVersion = (value) =>
        switch type value
            when "number" then return math.max value, 0
            when "nil" then return 0
            when "string"
                matches = {value\match "^(%d+).(%d+).(%d+)$"}
                if #matches!=3
                    return false, msgs.parseVersion.badString\format value

                version = 0
                for i, part in ipairs semParts
                    value = tonumber(matches[i])
                    if type(value) != "number" or value>256
                        return false, msgs.parseVersion.overflow\format part[1], tostring value
                    version += bit.lshift value, part[2]
                return version

            else return false, msgs.parseVersion.badType\format type(value), @logger\dumpToString value

    @getVersionString = (version, precision = "patch") =>
        if type(version) == "string"
            version = @parseVersion version
        parts = {0, 0, 0}
        for i, part in ipairs semParts
            parts[i] = bit.rshift(version, part[2])%256
            break if precision == part[1]

        return "%d.%d.%d"\format unpack parts

    getConfigFileName: () =>
        return aegisub.decode_path "#{@@configDir}/#{@configFile}"

    getConfigHandler: (defaults, section, noLoad) =>
        return ConfigHandler @getConfigFileName!, defaults, section, noLoad

    getLogger: (args = {}) =>
        args.fileBaseName or= @namespace
        args.toFile = @config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @config.c.logLevel
        args.prefix or= @moduleName and "[#{@name}]"

        return Logger args

    checkVersion: (value, precision = "patch") =>
        if type(value) == "table" and value.__class == @@
            value = value.version
        if type(value) != "number"
            value, err = @@parseVersion value
            return nil, err unless value
        mask = 0
        for part in *semParts
            mask += 0xFF * 2^part[2]
            break if precision == part[1]

        value = bit.band value, mask
        return @version >= value, value

    getSubmodules: =>
        return nil if @virtual or @recordType == @@RecordType.Unmanaged or @scriptType != @@ScriptType.Module
        mdlConfig = @@config\getSectionHandler @@ScriptType.name.legacy[@@ScriptType.Module]
        pattern = "^#{@namespace}."\gsub "%.", "%%."
        return [mdl for mdl, _ in pairs mdlConfig.c when mdl\match pattern], mdlConfig

    requireModules: (modules = @requiredModules, addFeeds = {@feed}) =>
        success, err = ModuleLoader.loadModules @, modules, addFeeds
        @@updater\releaseLock!
        unless success
            -- if we failed loading our required modules
            -- then that means we also failed to load
            LOADED_MODULES[@namespace] = nil
            @@logger\error err
        return unpack [mdl._ref for mdl in *modules]

    registerTests: (...) =>
        -- load external tests
        haveTests, tests = pcall require, "DepUnit.#{@@ScriptType.name.legacy[@scriptType]}.#{@namespace}"

        if haveTests and not @testsLoaded
            @tests, tests.name = tests, @name
            modules =  table.pack @requireModules!
            if @moduleName
                @tests\import @ref, modules, ...
            else @tests\import modules, ...

            @tests\registerMacros!
            @testsLoaded = true

    register: (selfRef, ...) =>
        -- replace dummy refs with real refs to own module
        @ref.__index, @ref, LOADED_MODULES[@moduleName] = selfRef, selfRef, selfRef
        @registerTests selfRef, ...
        return selfRef

    registerMacro: (name=@name, description=@description, process, validate, isActive, submenu) =>
        -- alternative signature takes name and description from script
        if type(name)=="function"
            process, validate, isActive, submenu = name, description, process, validate
            name, description = @name, @description

        -- use automation script name for submenu by default
        submenu = @name if submenu == true

        menuName = { @config.c.customMenu }
        menuName[#menuName+1] = submenu if submenu
        menuName[#menuName+1] = name

        -- check for updates before running a macro
        processHooked = (sub, sel, act) ->
            @@updater\scheduleUpdate @
            @@updater\releaseLock!
            return process sub, sel, act

        aegisub.register_macro table.concat(menuName, "/"), description, processHooked, validate, isActive

    registerMacros: (macros = {}, submenuDefault = true) =>
        for macro in *macros
            -- allow macro table to omit name and description
            submenuIdx = type(macro[1])=="function" and 4 or 6
            macro[submenuIdx] = submenuDefault if macro[submenuIdx] == nil
            @registerMacro unpack(macro, 1, 6)

    setVersion: (version) =>
        version, err = @@parseVersion version
        if version
            @version = version
            return version
        else return nil, err

    validateNamespace: (namespace = @namespace, isVirtual = @virtual) =>
        return isVirtual or namespaceValidation\match @namespace

    uninstall: (removeConfig = true) =>
        if @virtual or @recordType == @@RecordType.Unmanaged
            return nil, msgs.uninstall.noVirtualOrUnmanaged\format @virtual and "virtual" or "unmanaged",
                                                                   @@terms.scriptType.singular[@scriptType],
                                                                   @name
        @config\delete!
        subModules, mdlConfig = @getSubmodules!
        -- uninstalling a module also removes all submodules
        if subModules and #subModules > 0
            mdlConfig.c[mdl] = nil for mdl in *subModules
            mdlConfig\write!

        toRemove, pattern, dir = {}
        if @moduleName
            nsp, name = @namespace\match "(.+)%.(.+)"
            pattern = "^#{name}"
            dir = "#{@automationDir}/#{nsp\gsub '%.', '/'}"
        else
            pattern = "^#{@namespace}"\gsub "%.", "%%."
            dir = @automationDir

        lfs.chdir dir
        for file in lfs.dir dir
            mode, path = FileOps.attributes file, "mode"
            -- parent level module files must be <last part of namespace>.ext
            currPattern = @moduleName and mode == "file" and pattern.."%." or pattern
            -- automation scripts don't use any subdirectories
            if (@moduleName or mode == "file") and file\match currPattern
                toRemove[#toRemove+1] = path
        return FileOps.remove toRemove, true, true