Common = require "l0.DependencyControl.Common"

class VersionRecord extends Common
  semParts = {{"major", 16}, {"minor", 8}, {"patch", 0}}
  versionClasses = {}
  msgs = {
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


  @__inherited = (cls) =>
    versionClasses[@] or= true
    versionClasses[cls] or= true


  -- Shared base constructor for all inheriting classes
  -- Does not use the new keyword, as VersionRecord itself is an abstract class
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
        version or= script_version
      else
        @name = name or namespace
        @namespace = namespace
        version or= 0

      @namespace = namespace or script_namespace
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

    @automationDir = @@automationDir[@scriptType]
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
  @isVersionRecord = (record, cls) =>
    return false if type(record) != "table" or not record.__class
    return false if cls and cls != record.__class
    return versionClasses[record.__class] or false


  @getVersionString = (version, precision = "patch") =>
    if type(version) == "string"
      version = @parseVersion version
    parts = {0, 0, 0}
    for i, part in ipairs semParts
      parts[i] = bit.rshift(version, part[2])%256
      break if precision == part[1]

    return "%d.%d.%d"\format unpack parts


  checkVersion: (value, precision = "patch") =>
    if @@isVersionRecord value
      value = value.version
    else if type(value) != "number"
      value, err = @@parseVersion value
      return nil, err unless value

    mask = 0
    for part in *semParts
      mask += 0xFF * 2^part[2]
      break if precision == part[1]

    value = bit.band value, mask
    return @version >= value, value


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


  setVersion: (version) =>
    version, err = @@parseVersion version
    if version
      @version = version
      return version
    else return nil, err