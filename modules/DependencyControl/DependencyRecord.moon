Common = require "l0.DependencyControl.Common"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"

class DependencyRecord
  msgs = {
    new: {
      badRecordError: "Error: Bad DependencyControl record (%s)."
    }

    parseVersion: {
      badString: "Can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
      badType: "Argument had the wrong type: expected a string or number, got a %s. Content %s"
      overflow: "Error: %s version must be an integer < 255, got %s."
    }

    __import: {
      noUnmanagedMacros: "Creating unmanaged version records for macros is not permitted"
      missingNamespace: "No namespace defined"
      badVersion: "Couldn't parse version number: %s"
      badModuleTable: "Invalid required module table #%d (%s)."
    }
  }

  @RecordType = {
      Managed: 1
      Unmanaged: 2
  }

  @ScriptType = {
      Automation: 1
      Module: 2
      name: {
          legacy: { "macros", "modules" }
          canonical: {"automation", "modules"}
      }
  }


  recordClasses = {
    [@]: true
  }
  @__inherited = (cls) =>
    recordClasses[cls] or= true


  new: (args) =>
    success, errMsg = @__import args
    assert success, msgs.new.badRecordError\format errMsg


  __import: (args, readGlobalScriptVars = true) =>
    { @requiredModules, moduleName: @moduleName, configFile: configFile, :name,
      description: @description, url: @url, feed: @feed, recordType: @recordType,
      :namespace, author: @author, :version, configFile: @configFile } = args

    @recordType or= @@RecordType.Managed
    -- also support name key (as used in configuration) for required modules
    @requiredModules or= args.requiredModules

    if @moduleName
      @namespace = @moduleName
      @name = name or @moduleName
      @scriptType = @@ScriptType.Module

    else
      if readGlobalScriptVars
        @name = name or script_name
        @description or= script_description
        @author or= script_author
        @namespace = namespace or script_namespace
        version or= script_version
      else
        @name = name or namespace
        @namespace = namespace
        version or= 0

      return nil, msgs.__import.noUnmanagedMacros if @recordType != @@RecordType.Managed
      return nil, msgs.__import.missingNamespace unless @namespace
      @scriptType = @@ScriptType.Automation

    -- if the hosting macro doesn't have a namespace defined, define it for
    -- the first DepCtrled module loaded by the macro or its required modules
    unless script_namespace
      export script_namespace = @namespace

    -- non-depctrl record doesn't need to conform to namespace rules
    unless @recordType == @@RecordType.Unmanaged
      namespaceValid, errMsg = Common.validateNamespace @namespace
      return nil, errMsg unless namespaceValid

    @automationDir = Common.automationDir[@scriptType]
    @version, errMsg = @@parseVersion version
    unless @version
      return nil, msgs.__import.badVersion\format errMsg

    @requiredModules or= {}
    -- normalize short format module tables
    for i, mdl in pairs @requiredModules
      switch type mdl
        when "table"
          mdl.moduleName or= mdl[1]
          mdl[1] = nil
        when "string"
          @requiredModules[i] = {moduleName: mdl}
        else return nil, msgs.__import.badModuleTable\format i, tostring mdl

    return true


  -- static method to check wether the supplied object is a member of a descendant of VersionRecord
  -- optionally allows to check for specific class membership
  @isDependencyRecord = (record, cls) =>
    return false if type(record) != "table" or not record.__class
    return false if cls and cls != record.__class
    return recordClasses[record.__class] or false


  @getVersionString = SemanticVersioning.toString


  checkVersion: (value, precision = "patch") =>
    if @@isDependencyRecord value
      value = value.version

    return SemanticVersioning\check @version, value


  @parseVersion = SemanticVersioning.parse


  setVersion: (version) =>
    version, err = @@parseVersion version
    if version
      @version = version
      return version
    else return nil, err