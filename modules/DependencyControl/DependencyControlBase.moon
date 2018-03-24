json = require "json"
lfs =  require "lfs"
re =   require "aegisub.re"

Common =           require "l0.DependencyControl.Common"
Logger =           require "l0.DependencyControl.Logger"
ConfigHandler =    require "l0.DependencyControl.ConfigHandler"
FileOps =          require "l0.DependencyControl.FileOps"
Updater =          require "l0.DependencyControl.Updater"
ModuleLoader =     require "l0.DependencyControl.ModuleLoader"
Package =          require "l0.DependencyControl.Package"
DependencyRecord = require "l0.DependencyControl.DependencyRecord"
LocationResolver = require "l0.DependencyControl.LocationResolver"

class DependencyControlBase
    msgs = {
        init: {
            initializing: "Initializing DependencyControl for automation script environment '%s'"
            writeLogs: "Log writing is disabled in the DependencyControl configuration - end of file reached."
            globalConfigFailed: "Failed to load global config file (%s)."
        }
        new: {
            badRecordError: "Error: Bad #{@@__name} record (%s)."
        }
    }

    -- static initializer for common DependencyRecord infrastructure,
    -- such as the global config file and the shared updater
    init = =>
        @logger = Logger {fileBaseName: "DepCtrl", fileSubName: script_namespace, prefix: "[#{@@__name}] ", 
                         toFile: true, maxToFileLevel: 4}

        @logger\trace msgs.init.initializing, script_namespace

        FileOps.mkdir Common.globalConfig.file, true
        @configHandler, msg = ConfigHandler\get Common.globalConfig.file, @logger
        @logger\assert @configHandler, msgs.init.globalConfigFailed, msg

        @config, msg = @configHandler\getView {"config"}, Common.globalConfig.defaults
        @logger\assert @config, msgs.init.globalConfigFailed, msg

        @logger\hint msgs.init.writeLogs unless @config.c.writeLogs
        @logger[k] = v for k, v in pairs {
            toFile: @config.c.writeLogs
            defaultLevel: @config.c.traceLevel
            maxAge: @config.c.logMaxAge
            maxSize: @config.c.logMaxSize
            maxFiles: @config.c.logMaxFiles
            logDir: @config.c.logDir
            maxToFileLevel: @config.c.traceToFileLevel
        }

        @updater = Updater script_namespace, @config, @logger
        @configDir = @config.c.configDir

        FileOps.mkdir aegisub.decode_path @configDir
        logsHaveBeenTrimmed or= @logger\trimFiles!
        FileOps.runScheduledRemoval @configDir


    @getScriptConfig = (namespace, scriptType) =>
        ConfigHandler\getView Common.globalConfig.file, { Common.name.scriptType.canonical[scriptType], @record.namespace },
                              Common.defaultScriptConfig


    new: (args) =>
        init DependencyControlBase unless @@configHandler

        success, @record = pcall DependencyRecord, args
        @@logger\assert success, msgs.new.badRecordError, @record

        if @record.scriptType == DependencyRecord.ScriptType.Module and @record.recordType != DependencyRecord.RecordType.Unmanaged
            ModuleLoader.createDummyRef @

        @configFile = "#{@namespace}.json"

        @package = Package @record, @@logger
        @package\sync nil, Package.InstallState.Installed


    checkOptionalModules: ModuleLoader.checkOptionalModules


    getConfigFileName: =>
        return aegisub.decode_path "#{@@configDir}/#{@configFile}"


    getConfigHandler: (defaults, hivePath) =>
        handler, msg = ConfigHandler\get @getConfigFileName!
        return nil, msg unless handler

        view, msg = handler\getView hivePath, defaults
        return nil, msg unless view
        return view, handler


    getLogger: (args = {}) =>
        args.fileBaseName or= @record.namespace
        args.toFile = @package.config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @package.config.c.logLevel
        args.prefix or= @record.moduleName and "[#{@record.name}]"

        return Logger args


    requireModules: (modules = @record.requiredModules, addFeeds = {@record.feed}) =>
        success, err = ModuleLoader.loadModules @, modules, addFeeds
        @@updater\releaseLock!
        unless success
            -- if we failed loading our required modules
            -- then that means we also failed to load
            LOADED_MODULES[@record.namespace] = nil
            @@logger\error err
        return unpack [mdl._ref for mdl in *modules]


    registerTests: (...) =>
        -- load external tests
        resolver = LocationResolver @record.namespace, @record.scriptType, @@logger
        haveTests, tests = resolver\require LocationResolver.Category.Test

        if haveTests and not @testsLoaded
            @tests, tests.name = tests, @record.name
            modules =  table.pack @requireModules!
            if @record.moduleName
                @tests\import @ref, modules, ...
            else @tests\import modules, ...

            @tests\registerMacros!
            @testsLoaded = true


    register: (selfRef, ...) =>
        -- replace dummy refs with real refs to own module
        @ref.__index, @ref, LOADED_MODULES[@record.moduleName] = selfRef, selfRef, selfRef
        @registerTests selfRef, ...
        return selfRef


    registerMacro: (name=@record.name, description=@record.description, process, validate, isActive, submenu) =>
        -- alternative signature takes name and description from script
        if type(name)=="function"
            process, validate, isActive, submenu = name, description, process, validate
            name, description = @record.name, @record.description

        -- use automation script name for submenu by default
        submenu = @record.name if submenu == true

        menuName = { @package.config.c.customMenu }
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