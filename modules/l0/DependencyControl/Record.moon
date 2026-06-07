json = require "json"
lfs =  require "lfs"

constants =      require "l0.DependencyControl.Constants"
Common =         require "l0.DependencyControl.Common"
Logger =         require "l0.DependencyControl.Logger"
ConfigView =     require "l0.DependencyControl.ConfigView"
FileOps =        require "l0.DependencyControl.FileOps"
Updater =        require "l0.DependencyControl.Updater"
ModuleLoader =   require "l0.DependencyControl.ModuleLoader"
ModuleProvider = require "l0.DependencyControl.ModuleProvider"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
UnitTestSuite =  require "l0.DependencyControl.UnitTestSuite"

-- Global registry of live DepCtrl version records keyed by namespace, backed by a global table
--  so it survives DepCtrl self-update reloads. Required to reach the DepCtrl version records
-- of automation scripts/macros, which don't expose it globally (only a few script_* globals)
DEPCTRL_RECORDS_GLOBAL_KEY = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Records"
recordsByNamespace = _G[DEPCTRL_RECORDS_GLOBAL_KEY]
unless recordsByNamespace
    recordsByNamespace = {}
    _G[DEPCTRL_RECORDS_GLOBAL_KEY] = recordsByNamespace

--- Registers a record in the global registry under its namespace. Latest call wins.
-- @param record Record
-- @return Record the record passed in
registerRecord = (record) ->
    recordsByNamespace[record.namespace] = record if record.namespace
    return record

--- Removes a namespace's record from the registry (e.g. on uninstall).
-- @param namespace string
unregisterRecord = (namespace) -> recordsByNamespace[namespace] = nil


--- DependencyControl record representing one managed or unmanaged script/module.
-- @class Record
class Record extends Common
    msgs = {
        new: {
            badRecordError: "Error: Bad #{constants.DEPCTRL_NAME} record (%s)."
            badRecord: {
                noUnmanagedMacros: "Creating unmanaged version records for macros is not allowed"
                missingNamespace: "No namespace defined"
                badVersion: "Couldn't parse version number: %s"
                badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
                badModuleTable: "Invalid required module table #%d (%s)."
            }
        }
        uninstall: {
            noVirtualOrUnmanaged: "Can't uninstall %s %s '%s'. (Only installed scripts managed by #{constants.DEPCTRL_NAME} can be uninstalled)."
        }
        writeConfig: {
            error: "An error occurred while writing the #{constants.DEPCTRL_NAME} config file: %s"
            writing: "Writing updated %s data to config file..."
        }
    }

    @depConf = {
        file: aegisub.decode_path "?user/config/#{constants.DEPCTRL_NAMESPACE}.json",
        scriptFields: {"author", "configFile", "feed", "moduleName", "name", "namespace", "url", -- REMOVE
                       "requiredModules", "version", "unmanaged", "provides"},
        globalDefaults: {updaterEnabled:true, updateInterval:302400, traceLevel:3, extraFeeds:{},
                         tryAllFeeds:false, dumpFeeds:true, configDir:"?user/config",
                         logMaxFiles: 200, logMaxAge: 604800, logMaxSize:10*(10^6),
                         updateWaitTimeout: 60, updateOrphanTimeout: 600,
                         logDir: "?user/log", writeLogs: true}
    }

    --- Returns the live, installed record registered for a namespace, or nil if none is registered
    -- or the registered one is still a virtual (not-yet-installed) placeholder.
    -- @param namespace string
    -- @return Record|nil
    @getRecord = (namespace) =>
        record = recordsByNamespace[namespace]
        record unless record and record.virtual

    init = =>
        FileOps.mkdir @depConf.file, true
        @loadConfig!
        @logger = Logger { fileBaseName: constants.DEPCTRL_SHORT_NAME, fileSubName: script_namespace, prefix: "[#{constants.DEPCTRL_SHORT_NAME}] ",
                             toFile: @config.c.writeLogs, defaultLevel: @config.c.traceLevel,
                             maxAge: @config.c.logMaxAge,maxSize: @config.c.logMaxSize, maxFiles: @config.c.logMaxFiles,
                             logDir: @config.c.logDir }

        @updater = Updater script_namespace, @config, @logger
        @configDir = @config.c.configDir

        FileOps.mkdir aegisub.decode_path @configDir
        logsHaveBeenTrimmed or= @logger\trimFiles!
        FileOps.runScheduledRemoval @configDir


    --- Creates a DependencyControl record from explicit arguments and/or script globals.
    -- @param args table
    new: (args) =>
        init Record unless @@logger

        -- defaults
        args[k] = v for k, v in pairs {
            readGlobalScriptVars: true
            saveRecordToConfig: true
        } when args[k] == nil

        {@requiredModules, moduleName:@moduleName, configFile:configFile, virtual:@virtual, :name,
         description:@description, url:@url, feed:@feed, recordType:@recordType, :namespace,
         author:@author, :version, configFile:@configFile, :provides,
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
        @automationDir = Common\getAutomationDir @scriptType
        @testDir = Common\getTestDir @scriptType
        @version, err = SemanticVersioning\toNumber version
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

        -- normalize `provides` aliases (bare string -> {name: …}) and register them so
        -- `require`-ing a provided alias resolves to this module (see ModuleProvider)
        if @provides
            @provides = [type(alias) == "table" and alias or {name: alias} for alias in *@provides]
            ModuleProvider\registerRecord @

        -- publish this record so tooling can look it up by namespace after requiring the script
        registerRecord @

        -- write config file if contents are missing or are out of sync with the script version record
        -- ramp up the random wait time on first initialization (many scripts may want to write configuration data)
        -- we can't really profit from write concerting here because we don't know which module loads last
        shouldWriteConfig = @loadConfig!
        @writeConfig if shouldWriteConfig and saveRecordToConfig

    checkOptionalModules: ModuleLoader.checkOptionalModules

    --- Loads global DependencyControl configuration.
    -- @return ConfigView
    @loadConfig = =>
        if @config
            @config\load!
        else @config = ConfigView\get @depConf.file, {"config"}, @depConf.globalDefaults, @logger

    --- Loads this record's script/module configuration hive.
    -- @param[opt=false] importRecord boolean
    -- @return boolean
    loadConfig: (importRecord = false) =>
        -- virtual modules are not yet present on the user's system and have no persistent configuration
        @config or= ConfigView\get not @virtual and @@depConf.file,
                    { @@ScriptType.name.legacy[@scriptType], @namespace }, {}, @@logger, true

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

    --- Writes this record's persisted fields to the shared config file.
    -- @return nil
    writeConfig: =>
        unless @virtual or @config.file
            @config\setFile @@depConf.file

        @@logger\trace msgs.writeConfig.writing, @@terms.scriptType.singular[@scriptType]
        @config\import @, @@depConf.scriptFields, false, true
        success, errMsg = @config\save!

        assert success, msgs.writeConfig.error\format errMsg


    -- retained for compatibility with DepCtrl <= v0.6.3
    -- TODO: deprecate w/ v0.7.0 and remove in next major release
    @getVersionNumber = SemanticVersioning.toNumber
    @getVersionString = SemanticVersioning.toString


    --- Resolves this record's external config file path.
    -- @return string
    getConfigFileName: () =>
        return aegisub.decode_path "#{@@configDir}/#{@configFile}"

    --- Creates a ConfigView for this record's script-specific config file.
    -- @param[opt] defaults table
    -- @param[opt] section string|string[]
    -- @param[opt] noLoad boolean
    -- @return ConfigView
    getConfigHandler: (defaults, section, noLoad) =>
        return ConfigView\get @getConfigFileName!, section, defaults, nil, noLoad

    --- Creates a logger preconfigured for this record.
    -- @param[opt] args table
    -- @return Logger
    getLogger: (args = {}) =>
        args.fileBaseName or= @namespace
        args.toFile = @config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @config.c.logLevel
        args.prefix or= @moduleName and "[#{@name}]"

        return Logger args

    --- Checks whether this record's version satisfies a minimum version.
    -- @param value number|string|Record
    -- @param[opt="patch"] precision SemverPrecision
    -- @return boolean|nil
    -- @return number|string|nil
    checkVersion: (value, precision = "patch") =>
        if type(value) == "table" and value.__class == @@
            value = value.version
        return SemanticVersioning\check @version, value


    --- Retrieves managed submodules registered under this module namespace.
    -- @return string[]|nil
    -- @return ConfigView|nil
    getSubmodules: =>
        return nil if @virtual or @recordType == @@RecordType.Unmanaged or @scriptType != @@ScriptType.Module
        mdlConfig = @@config\getSectionHandler @@ScriptType.name.legacy[@@ScriptType.Module]
        pattern = "^#{@namespace}."\gsub "%.", "%%."
        return [mdl for mdl, _ in pairs mdlConfig.c when mdl\match pattern], mdlConfig

    --- Loads or updates required modules and returns their references.
    -- @param[opt] modules table[]
    -- @param[opt] addFeeds string[]
    -- @return ... any
    requireModules: (modules = @requiredModules, addFeeds = {@feed}) =>
        success, err = ModuleLoader.loadModules @, modules, addFeeds
        @@updater\releaseLock!
        unless success
            -- if we failed loading our required modules
            -- then that means we also failed to load
            LOADED_MODULES[@namespace] = nil
            @@logger\error err
        return unpack [mdl._ref for mdl in *modules]
    
    --- Registers DepUnit tests for this record if test modules are available.
    -- @param[opt] ... any
    registerTests: (...) =>
        return if @haveTestSuite == false or @testSuiteInitialized

        testSuiteIdentifier = UnitTestSuite\getTestSuiteRequireIdentifier @scriptType, @namespace
        @haveTestSuite, testsOrErrorMsg = pcall UnitTestSuite\require, testSuiteIdentifier
        if not @haveTestSuite
            @testSuiteLoadError = testsOrErrorMsg
            return
        
        @tests = testsOrErrorMsg
        @tests.name = @name

        modules = table.pack @requireModules!
        success, errMsg = nil, nil
        if @moduleName
            success, errMsg = pcall @tests\import, @ref, modules, ...
        else
            success, errMsg = pcall @tests\import, modules, ...

        if success
            @testSuiteInitialized = true
        else
            @testSuiteInitializeError = errMsg
            @@logger\warn "Error initializing test suite for #{@@terms.scriptType.singular[@scriptType]} '#{@name}': #{errMsg}"

    --- Finalizes module registration and swaps dummy module refs for real refs.
    -- @param selfRef table
    -- @param[opt] ... any
    -- @return table
    register: (selfRef, ...) =>
        -- replace dummy refs with real refs to own module
        @ref.__index, @ref, LOADED_MODULES[@moduleName] = selfRef, selfRef, selfRef
        @registerTests selfRef, ...
        return selfRef

    --- Registers a single Aegisub macro with DependencyControl update hooks.
    -- @param[opt] name string|function
    -- @param[opt] description string|function
    -- @param process function
    -- @param[opt] validate function
    -- @param[opt] isActive function
    -- @param[opt] submenu string|boolean
    registerMacro: (name=@name, description=@description, process, validate, isActive, submenu) =>
        @registerTests!
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

    --- Registers multiple macros declared in table form.
    -- @param[opt] macros table[]
    -- @param[opt=true] submenuDefault boolean
    registerMacros: (macros = {}, submenuDefault = true) =>
        @registerTests!
        for macro in *macros
            -- allow macro table to omit name and description
            submenuIdx = type(macro[1])=="function" and 4 or 6
            macro[submenuIdx] = submenuDefault if macro[submenuIdx] == nil
            @registerMacro unpack(macro, 1, 6)

    --- Parses and sets this record's semantic version.
    -- @param version number|string
    -- @return number|nil
    -- @return string|nil err
    setVersion: (version) =>
        version, err = SemanticVersioning\toNumber version
        if version
            @version = version
            return version
        else return nil, err

    --- Validates this record's namespace, always passing for virtual records.
    -- @return boolean
    validateNamespace: =>
        return true if @virtual
        return Common.validateNamespace @namespace

    --- Uninstalls this managed record and removes matching files from automation paths.
    -- @param[opt=true] removeConfig boolean
    -- @return boolean|nil
    -- @return table|string|nil
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

        -- drop the record from the registry so tooling no longer sees the removed script
        unregisterRecord @namespace
        return FileOps.remove toRemove, true, true
