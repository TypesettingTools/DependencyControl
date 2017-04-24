json = require "json"
lfs =  require "lfs"
re =   require "aegisub.re"

Common =           require "l0.DependencyControl.Common"
Logger =           require "l0.DependencyControl.Logger"
ConfigHandler =    require "l0.DependencyControl.ConfigHandler"
FileOps =          require "l0.DependencyControl.FileOps"
Updater =          require "l0.DependencyControl.Updater"
ModuleLoader =     require "l0.DependencyControl.ModuleLoader"
InstalledPackage = require "l0.DependencyControl.InstalledPackage"
VersionRecord =    require "l0.DependencyControl.VersionRecord"

class DependencyRecord extends VersionRecord
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
        @logger = Logger fileBaseName: "DepCtrl", fileSubName: script_namespace, prefix: "[#{@@__name}] ", toFile: true
        @logger\trace msgs.init.initializing, script_namespace

        FileOps.mkdir @globalConfig.file, true
        @configHandler, msg = ConfigHandler\get @globalConfig.file, @logger
        @logger\assert @configHandler, msgs.init.globalConfigFailed, msg

        @config, msg = @configHandler\getView {"config"}, @globalConfig.defaults
        @logger\assert @config, msgs.init.globalConfigFailed, msg

        @logger\hint msgs.init.writeLogs unless @config.c.writeLogs
        @logger[k] = v for k, v in pairs {
            toFile: @config.c.writeLogs
            defaultLevel: @config.c.traceLevel
            maxAge: @config.c.logMaxAge
            maxSize: @config.c.logMaxSize
            maxFiles: @config.c.logMaxFiles
            logDir: @config.c.logDir
        }

        @updater = Updater script_namespace, @config, @logger
        @configDir = @config.c.configDir

        FileOps.mkdir aegisub.decode_path @configDir
        logsHaveBeenTrimmed or= @logger\trimFiles!
        FileOps.runScheduledRemoval @configDir


    new: (args) =>
        init DependencyRecord unless @@configHandler

        success, errMsg = @__import args
        @@logger\assert success, msgs.new.badRecordError, errMsg

        if @scriptType == @@ScriptType.Module and @recordType != @@RecordType.Unmanaged
            ModuleLoader.createDummyRef @

        @configFile = "#{@namespace}.json"
        @testDir = @@testDir[@scriptType]

        @package = InstalledPackage @, @@logger unless @virtual


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
        args.fileBaseName or= @namespace
        args.toFile = @package.config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @package.config.c.logLevel
        args.prefix or= @moduleName and "[#{@name}]"

        return Logger args


    -- TODO: completely broken, FIXME using db
    getSubmodules: =>
        return nil if @virtual or @recordType == @@RecordType.Unmanaged or @scriptType != @@ScriptType.Module
        mdlConfig = @@configHandler\getView @@ScriptType.name.legacy[@@ScriptType.Module]
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