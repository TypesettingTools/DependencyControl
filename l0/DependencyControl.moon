json = require "json"
class DependencyControl
    semParts = {{"major", 16}, {"minor", 8}, {"patch", 0}}
    msgs = {
        missingModules: "Error: one or more of the modules required by %s could not be found on your system:\n%s\n%s"
        missingOptionalModules: "Error: a %s feature you're trying to use requires additional modules that were not found on your system:\n%s\n%s"
        missingModulesDownloadHint: "Please download the modules in question, put them in your %s folder and reload your automation scripts."
        missingTemplate: "— %s (v%s+)%s\n"
        outdatedModules: "Error: one or more of the modules required by %s are outdated on your system:
%sPlease update the modules in question and reload your automation scripts."
        outdatedTemplate: "— %s (Installed: v%s; Required: v%s)%s\n"
        missingRecord: "Error: module '%s' is missing a version record."
        moduleError: "Error in module %s:\n%s"
        badVersionString: "Error: can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
        versionOverflow: "Error: %s version must be an integer < 255, got %s."
    }

    new: (args)=>
        {@requiredModules, moduleName:@moduleName, configFile:configFile, url:@url, namespace:@namespace} = args
        @name, @description, @author = args.name or script_name, args.description or script_description, args.author or script_author
        @version = @parse args.version or script_version
        @configFile = configFile or @moduleName and "#{@moduleName}.json" or "#{@name}.json"
        -- global module registry allows for circular dependencies:
        -- set a dummy reference to this module since this module is not ready
        -- when the other one tries to load it (and vice versa)
        export LOADED_MODULES = {} unless LOADED_MODULES
        if @moduleName and not LOADED_MODULES[@moduleName]
            @ref = {}
            LOADED_MODULES[@moduleName] = setmetatable {}, @ref

        unless args.hasNoDepControl
            configFile, config = aegisub.decode_path "?user/#{@@__name}.json"

            handle = io.open configFile
            if not handle
                -- first module ever registered is always DependencyControl
                config = {modules: {[@moduleName]: @}, macros: {}}
                handle = io.open configFile, "w"
                handle\write json.encode config
            else config = json.decode handle\read "*a"
            handle\close!

            scriptType, scriptKey = @moduleName and "modules" or "macros", @moduleName or @name
            configRecord = config[scriptType][scriptKey]

            @customMenu = configRecord and configRecord.customMenu
            unless configRecord and configRecord.version == @version
                config[scriptType][scriptKey] = @
                io.open(configFile, "w")\write(json.encode config)\close!

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

    getConfigFileName: (ext = "json") =>
        return aegisub.decode_path "?user/#{@configFile}.#{ext}"

    check: (value) =>
        if type(value)=="string"
            value = @parse value
        return @version>=value

    checkOptionalModules: (modules, noAssert) =>
        modules = type(modules)=="string" and {[modules]:true} or {mdl,true for mdl in *modules}
        missing = [msgs.missingTemplate\format mdl[1], mdl.version,
                   mdl.url and ": #{mdl.url}" or "" for mdl in *@requiredModules when mdl.optional and mdl.missing and modules[mdl.name]]

        if #missing>0
            downloadHint = msgs.missingModulesDownloadHint\format aegisub.decode_path "?user/automation/include"
            errorMsg = msgs.missingOptionalModules\format @name, table.concat(missing), downloadHint
            return errorMsg if noAssert
            error errorMsg
        return nil

    load: (mdl, usePrivate) =>
        name = usePrivate and @moduleName and "#{@moduleName}.#{mdl[1]}" or mdl[1]

        -- pass already loaded modules as reference
        if LOADED_MODULES[name]
            mdl.ref, mdl.missing = LOADED_MODULES[name], false
            return mdl.ref

        loaded, res = pcall require, name
        mdl.missing = not loaded and res\match "^module '.+' not found:"
        -- check for module errors
        assert loaded or mdl.missing, msgs.moduleError\format(name, res)

        if loaded
            mdl.ref, LOADED_MODULES[name] = res, res
        return mdl.ref

    requireModules: (modules=@requiredModules) =>
        for i,mdl in ipairs modules
            if type(mdl)=="string"
                modules[i] = {mdl}
                mdl = modules[i]

            -- try to load private copies of required modules first
            loaded = @load mdl, true
            loaded = @load mdl unless loaded

            unless loaded continue
            -- check version
            if mdl.version and not mdl.missing
                loadedVer = assert loaded.version, msgs.missingRecord\format(mdl[1])
                if type(loadedVer)~="table" or loadedVer.__class~=@@
                    loadedVer = @@{moduleName:mdl[1], version:loadedVer, hasNoDepControl:true}
                unless loadedVer\check(mdl.version)
                    mdl.outdated = true
                mdl.loaded = loadedVer
            else mdl.loaded = type(loaded)=="table" and loaded.version or true

        errorMsg = ""
        missing = [msgs.missingTemplate\format mdl[1], mdl.version,
                   mdl.url and ": #{mdl.url}" or "" for mdl in *modules when mdl.missing and not mdl.optional]
        if #missing>0
            downloadHint = msgs.missingModulesDownloadHint\format aegisub.decode_path "?user/automation/include"
            errorMsg ..= msgs.missingModules\format @name, table.concat(missing), downloadHint

        outdated = [msgs.outdatedTemplate\format mdl[1], mdl.loaded\get!, mdl.version,
                    mdl.url and ": #{mdl.url}" or "" for mdl in *modules when mdl.outdated]
        if #outdated>0
            errorMsg ..= msgs.outdatedModules\format @name, table.concat outdated

        error errorMsg if #errorMsg>0
        return unpack [mdl.ref for mdl in *modules when mdl.loaded or mdl.optional]

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
        menuName[1] = @customMenu if @customMenu
        menuName[#menuName+1] = @name if useSubmenu
        menuName[#menuName+1] = name

        aegisub.register_macro table.concat(menuName, "/"), script_description, process, validate, isActive

    registerMacros: (macros = {}, useSubmenuDefault = true) =>
        for macro in *macros
            useSubmenu = type(macro[1])=="function" and 4 or 6
            macro[useSubmenu] = useSubmenuDefault if macro[useSubmenu]==nil
            @registerMacro unpack(macro, 1, 6)

DependencyControl.__class.version = DependencyControl{
    name: "DependencyControl",
    version: "0.1.0",
    description: "Dependency Management for Aegisub macros and modules",
    author: "line0",
    url: "http://github.com/TypesettingCartel/DependencyControl",
    moduleName: "l0.DependencyControl"
}

return DependencyControl