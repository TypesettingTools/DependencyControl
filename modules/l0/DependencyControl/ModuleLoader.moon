-- Note: this is a private API intended to be exclusively for internal DependenyControl use
-- Everything in this class can and will change without any prior notice
-- and calling any method is guaranteed to interfere with DependencyControl operation

constants = require "l0.DependencyControl.Constants"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
ModuleProvider = require "l0.DependencyControl.ModuleProvider"
Common = require "l0.DependencyControl.Common"

DEPCTRL_DUMMY_MODULE_MARKER = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Dummy"

---Internal module loading helpers for DependencyControl-managed module dependencies.
---@class ModuleLoader
class ModuleLoader
  msgs = {
    checkOptionalModules: {
      downloadHint: "Please download the modules in question manually, put them in your %s folder and reload your automation scripts."
      missing: "Error: a %s feature you're trying to use requires additional modules that were not found on your system:\n%s\n%s"
    }
    formatVersionErrorTemplate: {
      missing: "— %s %s%s\n—— Reason: %s"
      outdated: "— %s (Installed: v%s; Required: v%s)%s\n—— Reason: %s"
    }
    loadModules: {
      missing: "Error: one or more of the modules required by %s could not be found on your system:\n%s\n%s"
      missingRecord: "Error: module '%s' is missing a version record."
      moduleError: "Error in required module %s:\n%s"
      outdated: [[Error: one or more of the modules required by %s are outdated on your system:
%s\nPlease update the modules in question manually and reload your automation scripts.]]
    }
  }

  @formatVersionErrorTemplate = (name, reqVersion, url, reason, ref) =>
    url = url and ": #{url}" or ""
    if ref
      -- unmanaged records have refs whose .version is a string instead of a DepCtrl record
      version = SemanticVersioning\toString type(ref.version) == "table" and ref.version.version or ref.version
      return msgs.formatVersionErrorTemplate.outdated\format name, version, reqVersion, url, reason
    else
      reqVersion = reqVersion and " (v#{reqVersion})" or ""
      return msgs.formatVersionErrorTemplate.missing\format name, reqVersion, url, reason

  @createDummyRef = =>
    return nil if @scriptType != Common.ScriptType.Module
    -- global module registry allows for circular dependencies:
    -- set a dummy reference to this module since this module is not ready
    -- when the other one tries to load it (and vice versa)
    export LOADED_MODULES = {} unless LOADED_MODULES
    unless LOADED_MODULES[@namespace]
      @ref = {}
      LOADED_MODULES[@namespace] = setmetatable {[DEPCTRL_DUMMY_MODULE_MARKER]: true, version: @}, @ref
      return true
    return false

  @removeDummyRef = =>
    return nil if @scriptType != Common.ScriptType.Module
    if LOADED_MODULES[@namespace] and LOADED_MODULES[@namespace][DEPCTRL_DUMMY_MODULE_MARKER]
      LOADED_MODULES[@namespace] = nil
      return true
    return  false

  @loadModule = (mdl, usePrivate, reload) =>
    with mdl
      ._missing, ._error = nil

      moduleName = usePrivate and "#{@namespace}.#{mdl.moduleName}" or .moduleName
      name = "#{mdl.name or mdl.moduleName}#{usePrivate and ' (Private Copy)' or ''}"

      if .outdated or reload
        -- clear old references
        package.loaded[moduleName], LOADED_MODULES[moduleName] = nil

      elseif ._ref = LOADED_MODULES[moduleName]
        -- module is already loaded, however it may or may not have been loaded by DepCtrl
        -- so we have to call any DepCtrl initializer if it hasn't been called yet
        ModuleProvider.runInitializer ._ref, @@
        return ._ref

      loaded, res = xpcall require, ModuleProvider.fullTraceback, moduleName
      unless loaded
        LOADED_MODULES[moduleName] = nil
        res or= "unknown error"
        ._missing = nil != res\find "module '#{moduleName}' not found:", nil, true
        ._error = res unless ._missing
        return nil

      -- set new references
      if reload and ._ref and ._ref[DEPCTRL_DUMMY_MODULE_MARKER]
        setmetatable ._ref, res
      ._ref, LOADED_MODULES[moduleName] = res, res

      -- run DepCtrl initializer if one was specified
      ModuleProvider.runInitializer res, @@

    return mdl._ref  -- having this in the with block breaks moonscript

  ---Loads required modules, updates missing/outdated ones, and validates version constraints.
  ---@param modules table[]
  ---@param addFeeds? string[] Extra feed URLs to search when fetching missing modules (default: this script's feed).
  ---@param skip? table<string, boolean> Module names to skip, keyed by name (default: this module itself).
  ---@return boolean success
  ---@return string err Combined error message (empty on success).
  @loadModules = (modules, addFeeds = {@feed}, skip = @moduleName and {[@moduleName]: true} or {}) =>
    for mdl in *modules
      continue if skip[mdl.moduleName]
      with mdl
        ._ref, ._updated, ._missing, ._outdated, ._reason, ._error = nil

        -- try to load private copies of required modules first
        ModuleLoader.loadModule @, mdl, true
        ModuleLoader.loadModule @, mdl unless ._ref

        -- try to fetch and load a missing module from the web
        if ._missing
          record = @@{moduleName:.moduleName, name:.name or .moduleName,
                version:-1, url:.url, feed:.feed, virtual:true}
          ._ref, code, extErr = @@updater\require record, .version, addFeeds, .optional
          if ._ref or .optional
            ._updated, ._missing = true, false
          else
            ._reason = @@updater\getUpdaterErrorMsg code, .name or .moduleName, true, true, extErr
            -- nuke dummy reference for circular dependencies
            LOADED_MODULES[.moduleName] = nil

        -- check if the version requirements are satisfied
        -- which is guaranteed for modules updated with \require, so we don't need to check again
        if .version and ._ref and not ._updated
          record = ._ref.version
          unless record
            ._error = msgs.loadModules.missingRecord\format .moduleName
            continue

          if not ModuleProvider.isDepCtrlVersionRecord record
            record = @@ moduleName: .moduleName, version: record, recordType: Common.RecordType.Unmanaged

          -- force an update for outdated modules
          if not record\checkVersion .version
            ref, code, extErr = @@updater\require record, .version, addFeeds
            if ref
              ._ref = ref
            elseif not .optional
              ._outdated = true
              ._reason = @@updater\getUpdaterErrorMsg code, .name or .moduleName, true, false, extErr

    missing, outdated, moduleError = {}, {}, {}
    for mdl in *modules
      with mdl
        name = .name or .moduleName
        if ._missing
          missing[#missing+1] = ModuleLoader.formatVersionErrorTemplate @, name, .version, .url, ._reason
        elseif ._outdated
          outdated[#outdated+1] = ModuleLoader.formatVersionErrorTemplate @, name, .version, .url, ._reason, ._ref
        elseif ._error
          moduleError[#moduleError+1] = msgs.loadModules.moduleError\format name, ._error

    errorMsg = {}
    if #moduleError > 0
      errorMsg[1] = table.concat moduleError, "\n"
    if #outdated > 0
      errorMsg[#errorMsg+1] = msgs.loadModules.outdated\format @name, table.concat outdated, "\n"
    if #missing > 0
      downloadHint = msgs.checkOptionalModules.downloadHint\format Common\getAutomationDir Common.ScriptType.Module
      errorMsg[#errorMsg+1] = msgs.loadModules.missing\format @name, table.concat(missing, "\n"), downloadHint

    return #errorMsg == 0, table.concat(errorMsg, "\n\n")

  ---Validates optional module availability for the requested feature set.
  ---@param modules string|string[] Feature name(s) whose optional modules to check.
  ---@return boolean available
  ---@return string? err Error message listing missing modules.
  @checkOptionalModules = (modules) =>
    modules = type(modules)=="string" and {[modules]:true} or {mdl,true for mdl in *modules}
    missing = [ModuleLoader.formatVersionErrorTemplate @, mdl.moduleName, mdl.version, mdl.url,
              mdl._reason for mdl in *@requiredModules when mdl.optional and mdl._missing and modules[mdl.name]]

    if #missing>0
      downloadHint = msgs.checkOptionalModules.downloadHint\format Common\getAutomationDir Common.ScriptType.Module
      errorMsg = msgs.checkOptionalModules.missing\format @name, table.concat(missing, "\n"), downloadHint
      return false, errorMsg
    return true
