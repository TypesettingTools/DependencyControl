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

---Registers a record in the global registry under its namespace. Latest call wins.
---@param record Record
---@return Record record The record passed in.
registerRecord = (record) ->
    recordsByNamespace[record.namespace] = record if record.namespace
    return record

---Removes a namespace's record from the registry (e.g. on uninstall).
---@param namespace string
unregisterRecord = (namespace) -> recordsByNamespace[namespace] = nil


---A provided-module alias: the `require` name this module satisfies plus optional metadata. In a
---`provides` list a bare string is shorthand for `{name = <string>}`; records and feeds store the
---normalized table form. `version` is the version of the provided module the provider satisfies
---(reserved — not yet consulted during resolution, which uses the provider's own release version).
---@alias ModuleAlias { name: string, version?: string }

---Constructor arguments for a [Record](lua://Record). All fields are optional; unset fields are
---filled from script_* globals (for automation scripts) or sensible defaults.
---@class RecordArgs
---@field [1]? table[] Required module specs, passed positionally.
---@field moduleName? string Module namespace; its presence marks this record as a module rather than an automation script.
---@field name? string Display name (defaults to the script/module name).
---@field description? string Description (defaults to script_description).
---@field author? string Author (defaults to script_author).
---@field version? number|string Semantic version (defaults to script_version).
---@field namespace? string Unique namespace (defaults to script_namespace).
---@field url? string Project or homepage URL.
---@field feed? string Update feed URL.
---@field configFile? string Config file name (defaults to "<namespace>.json").
---@field virtual? boolean Mark as a not-yet-installed placeholder record.
---@field recordType? RecordType A Common.RecordType value (default Managed).
---@field requiredModules? table[] Required module specs (alternative to the positional list).
---@field provides? (string|ModuleAlias)[] Module aliases this module satisfies for `require` (bare strings are normalized to ModuleAlias tables).
---@field readGlobalScriptVars? boolean Read script_* globals for unset fields (default true).
---@field saveRecordToConfig? boolean Persist this record to the config file (default true).

---DependencyControl record representing one managed or unmanaged script/module.
---@class Record
class Record
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
                         trustedFeeds:{}, blockedFeeds:{},
                         feedTrustPromptThreshold: Updater.PromptThreshold.AutoUpdates,
                         packageChoicePromptThreshold: Updater.PromptThreshold.UserRequested,
                         packageChoiceOfferAllSources: false,
                         dumpFeeds:true, configDir:"?user/config",
                         logMaxFiles: 200, logMaxAge: 604800, logMaxSize:10*(10^6),
                         updateWaitTimeout: 60, updateOrphanTimeout: 50,
                         logDir: "?user/log", writeLogs: true}
    }

    ---Returns the live, installed record registered for a namespace, or nil if none is registered
    ---or the registered one is still a virtual (not-yet-installed) placeholder.
    ---@param namespace string
    ---@return Record? record
    @getRegisteredRecord = (namespace) =>
        record = recordsByNamespace[namespace]
        record unless record and record.virtual

    ---Returns all currently registered live records keyed by namespace.
    ---Includes virtual (not-yet-installed) placeholders.
    ---@return table<string, Record> records
    @getAllRegisteredRecords = => {ns, record for ns, record in pairs recordsByNamespace}

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


    ---Creates a DependencyControl record from explicit arguments and/or script globals.
    ---@param args RecordArgs
    new: (args) =>
        init Record unless @@logger

        Common.addDefaults args, {
            readGlobalScriptVars: true
            saveRecordToConfig: true
        }

        {@requiredModules, moduleName:@moduleName, configFile:configFile, virtual:@virtual, :name,
         description:@description, url:@url, feed:@feed, recordType:@recordType, :namespace,
         author:@author, :version, configFile:@configFile, :provides,
         :readGlobalScriptVars, :saveRecordToConfig} = args

        @recordType or= Common.RecordType.Managed
        -- also support name key (as used in configuration) for required modules
        @requiredModules or= args.requiredModules

        if @moduleName
            @namespace = @moduleName
            @name = name or @moduleName
            @scriptType = Common.ScriptType.Module
            ModuleLoader.createDummyRef @ unless @virtual or @recordType == Common.RecordType.Unmanaged

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
            assert @recordType == Common.RecordType.Managed, msgs.new.badRecordError\format msgs.new.badRecord.noUnmanagedMacros
            assert @namespace, msgs.new.badRecordError\format msgs.new.badRecord.missingNamespace
            @scriptType = Common.ScriptType.Automation

        -- if the hosting macro doesn't have a namespace defined, define it for
        -- the first DepCtrled module loaded by the macro or its required modules
        unless script_namespace
            export script_namespace = @namespace

        -- non-depctrl record don't need to conform to namespace rules
        assert @virtual or @recordType == Common.RecordType.Unmanaged or @validateNamespace!,
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
        if provides
            @provides = [type(alias) == "table" and alias or {name: alias} for alias in *provides]
            ModuleProvider\registerRecord @

        -- publish this record so tooling can look it up by namespace after requiring the script
        registerRecord @

        -- write config file if contents are missing or are out of sync with the script version record
        -- ramp up the random wait time on first initialization (many scripts may want to write configuration data)
        -- we can't really profit from write concerting here because we don't know which module loads last
        shouldWriteConfig = @loadConfig!
        @writeConfig if shouldWriteConfig and saveRecordToConfig

    checkOptionalModules: ModuleLoader.checkOptionalModules

    ---Loads global DependencyControl configuration.
    ---@return ConfigView config
    @loadConfig = =>
        if @config
            @config\load!
        else @config = ConfigView\get @depConf.file, {"config"}, @depConf.globalDefaults, @logger

    ---Loads this record's script/module configuration hive.
    ---@param importRecord? boolean Overwrite this record's fields from the stored config (default false).
    ---@return boolean shouldWriteConfig
    loadConfig: (importRecord = false) =>
        -- virtual modules are not yet present on the user's system and have no persistent configuration
        @config or= ConfigView\get not @virtual and @@depConf.file,
                    { Common.ScriptTypeSection[@scriptType], @namespace }, {}, @@logger, true

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

    ---Writes this record's persisted fields to the shared config file.
    writeConfig: =>
        unless @virtual or @config.file
            @config\setFile @@depConf.file

        @@logger\trace msgs.writeConfig.writing, Common.terms.scriptType.singular[@scriptType]
        @config\import @, @@depConf.scriptFields, false, true
        success, errMsg = @config\save!

        assert success, msgs.writeConfig.error\format errMsg


    -- retained for compatibility with DepCtrl <= v0.6.3
    -- TODO: deprecate w/ v0.7.0 and remove in next major release
    @getVersionNumber = SemanticVersioning.toNumber
    @getVersionString = SemanticVersioning.toString


    ---Resolves this record's external config file path.
    ---@return string path
    getConfigFileName: () =>
        return aegisub.decode_path "#{@@configDir}/#{@configFile}"

    ---Creates a ConfigView for this record's script-specific config file.
    ---@param defaults? table Default values for the config.
    ---@param section? string|string[] Config section path.
    ---@param noLoad? boolean Skip loading the file immediately.
    ---@return ConfigView
    getConfigHandler: (defaults, section, noLoad) =>
        return ConfigView\get @getConfigFileName!, section, defaults, nil, noLoad

    ---Creates a logger preconfigured for this record.
    ---@param args? table Logger options; missing fields are filled from this record's config.
    ---@return Logger
    getLogger: (args = {}) =>
        args.fileBaseName or= @namespace
        args.toFile = @config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @config.c.logLevel
        args.prefix or= @moduleName and "[#{@name}]"

        return Logger args

    ---Checks whether this record's version satisfies a minimum version.
    ---@param value number|string|Record Version, or record, to compare against.
    ---@param precision? SemverPrecision Precision to compare at (default "patch").
    ---@return boolean? satisfied
    ---@return number|string|nil maskedOrError Masked comparison value on success, or an error message.
    checkVersion: (value, precision = "patch") =>
        if type(value) == "table" and value.__class == @@
            value = value.version
        return SemanticVersioning\check @version, value, precision


    ---Retrieves managed submodules registered under this module namespace.
    ---@return string[]? submodules Submodule namespaces, or nil for non-module records.
    ---@return ConfigView? config The module config section handler.
    getSubmodules: =>
        return nil if @virtual or @recordType == Common.RecordType.Unmanaged or @scriptType != Common.ScriptType.Module
        mdlConfig = @@config\getSectionHandler Common.ScriptTypeSection[Common.ScriptType.Module]
        pattern = "^#{@namespace}."\gsub "%.", "%%."
        return [mdl for mdl, _ in pairs mdlConfig.c when mdl\match pattern], mdlConfig

    ---Loads or updates required modules and returns their references.
    ---@param modules? table[] Module specs to load (default: this record's requiredModules).
    ---@param addFeeds? string[] Extra feed URLs to search (default: this record's feed).
    ---@return any ... The loaded module references, in order.
    requireModules: (modules = @requiredModules, addFeeds = {@feed}) =>
        success, err = ModuleLoader.loadModules @, modules, addFeeds
        @@updater\releaseLock!
        unless success
            -- if we failed loading our required modules
            -- then that means we also failed to load
            LOADED_MODULES[@namespace] = nil
            @@logger\error err
        return unpack [mdl._ref for mdl in *modules]
    
    ---Registers DepUnit tests for this record if test modules are available.
    ---@param ... any Forwarded to the test suite's import().
    registerTests: (...) =>
        return if @haveTestSuite == false or @testSuiteInitialized

        testSuiteIdentifier = UnitTestSuite\getTestSuiteRequireIdentifier @scriptType, @namespace
        @haveTestSuite, testsOrErrorMsg = xpcall UnitTestSuite\require, ModuleProvider.fullTraceback, testSuiteIdentifier
        if not @haveTestSuite
            @testSuiteLoadError = testsOrErrorMsg unless testsOrErrorMsg\match "module '[^']+' not found"
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
            @@logger\warn "Error initializing test suite for #{Common.terms.scriptType.singular[@scriptType]} '#{@name}': #{errMsg}"

        -- Automation scripts run in their own isolated environment exactly once, so they register
        -- their own test menu right here. Modules, by contrast, load in every script's environment;
        -- registering from here would create duplicate menu entries, so their test menus are
        -- registered centrally by the Toolbox (which loads each module exactly once).
        @tests\registerMacros! if @testSuiteInitialized and @scriptType == Common.ScriptType.Automation

    ---Finalizes module registration and swaps dummy module refs for real refs.
    ---@param selfRef table The module's real exported table.
    ---@param ... any Forwarded to registerTests().
    ---@return table selfRef
    register: (selfRef, ...) =>
        -- replace dummy refs with real refs to own module
        @ref.__index, @ref, LOADED_MODULES[@moduleName] = selfRef, selfRef, selfRef
        @registerTests selfRef, ...
        return selfRef

    ---Registers a single Aegisub macro with DependencyControl update hooks.
    ---When the first argument is a function, name and description are taken from the script and the
    ---remaining arguments shift left.
    ---@param name? string|function Macro name, or the process function in the short signature.
    ---@param description? string|function Macro description, or the validate function in the short signature.
    ---@param process function Macro processing callback.
    ---@param validate? function Aegisub validation callback.
    ---@param isActive? function Aegisub is-active callback.
    ---@param submenu? string|boolean Submenu name, or true to use the script name.
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

    ---Registers multiple macros declared in table form.
    ---@param macros? table[] Macro definitions, each an argument list for registerMacro.
    ---@param submenuDefault? boolean Default submenu value applied when a macro omits it (default true).
    registerMacros: (macros = {}, submenuDefault = true) =>
        @registerTests!
        for macro in *macros
            -- allow macro table to omit name and description
            submenuIdx = type(macro[1])=="function" and 4 or 6
            macro[submenuIdx] = submenuDefault if macro[submenuIdx] == nil
            @registerMacro unpack(macro, 1, 6)

    ---Parses and sets this record's semantic version.
    ---@param version number|string
    ---@return number? version The parsed integer version, or nil on error.
    ---@return string? err
    setVersion: (version) =>
        version, err = SemanticVersioning\toNumber version
        if version
            @version = version
            return version
        else return nil, err

    ---Validates this record's namespace, always passing for virtual records.
    ---@return boolean valid
    ---@return string? err
    validateNamespace: =>
        return true if @virtual
        return Common.validateNamespace @namespace

    ---Returns all candidate entry point paths for this record under a given base directory,
    ---covering .moon and .lua extensions and init.* variants for modules.
    ---@param baseDir string Absolute automation base directory.
    ---@return string[] paths
    getPossibleEntryPointPaths: (baseDir) =>
        isModule = @scriptType == Common.ScriptType.Module
        subPath = isModule and @namespace\gsub("%.", "/") or @namespace
        paths = {}
        for ext in *{".moon", ".lua"}
            if path = FileOps.validateFullPath "#{subPath}#{ext}", false, baseDir
                paths[#paths+1] = path
            if isModule
                if path = FileOps.validateFullPath "#{subPath}/init#{ext}", false, baseDir
                    paths[#paths+1] = path
        return paths

    ---Finds this record's primary entry point file, checking ?user then ?data automation directories.
    ---@return string? path
    ---@return boolean? isUserPath True when found under ?user, false when found under ?data, nil when not found.
    getEntryPointPath: =>
        userDir = Common\getAutomationDir @scriptType, "?user"
        for path in *@getPossibleEntryPointPaths userDir
            return path, true if "file" == FileOps.attributes path, "mode"

        dataDir = Common\getAutomationDir @scriptType, "?data"
        if dataDir and dataDir != userDir
            for path in *@getPossibleEntryPointPaths dataDir
                return path, false if "file" == FileOps.attributes path, "mode"

        -- TODO: what if a module is available in another package search path?
        return nil, nil

    ---Uninstalls this managed record and removes matching files from automation paths.
    ---@param removeConfig? boolean Also delete the record's config (default true).
    ---@return boolean? success nil when the record can't be uninstalled (virtual/unmanaged).
    ---@return table|string|nil result Per-file removal results, or an error message.
    uninstall: (removeConfig = true) =>
        if @virtual or @recordType == Common.RecordType.Unmanaged
            return nil, msgs.uninstall.noVirtualOrUnmanaged\format @virtual and "virtual" or "unmanaged",
                                                                   Common.terms.scriptType.singular[@scriptType],
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
