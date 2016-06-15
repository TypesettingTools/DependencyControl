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
        new: {
            badRecordError: "Error: Bad #{@@__name} record (%s)."
        }
    }

    init = =>
        FileOps.mkdir @globalConfig.file, true
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
        init DependencyRecord unless @@config

        success, errMsg = @__import args
        @@logger\assert success, msgs.new.badRecordError, errMsg

        if @scriptType == @@ScriptType.Module and @recordType != @@RecordType.Unmanaged
            ModuleLoader.createDummyRef @

        @configFile = configFile or "#{@namespace}.json"
        @testDir = @@testDir[@scriptType]

        @package = InstalledPackage @, @@logger unless @virtual


    checkOptionalModules: ModuleLoader.checkOptionalModules


    -- loads the DependencyControl global configuration
    @loadConfig = =>
        if @config
            @config\load!
        else @config = ConfigHandler @globalConfig.file, @globalConfig.defaults, {"config"}, nil, @logger


    getConfigFileName: =>
        return aegisub.decode_path "#{@@configDir}/#{@configFile}"


    getConfigHandler: (defaults, section, noLoad) =>
        return ConfigHandler @getConfigFileName!, defaults, section, noLoad


    getLogger: (args = {}) =>
        args.fileBaseName or= @namespace
        args.toFile = @package.config.c.logToFile if args.toFile == nil
        args.defaultLevel or= @package.config.c.logLevel
        args.prefix or= @moduleName and "[#{@name}]"

        return Logger args


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