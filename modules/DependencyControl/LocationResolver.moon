Common = require "l0.DependencyControl.Common"
DependencyRecord = require "l0.DependencyControl.DependencyRecord"
Enum = require "l0.DependencyControl.Enum"
fileOps = require "l0.DependencyControl.FileOps"
Logger = require "l0.DependencyControl.Logger"

automationBaseDir = aegisub.decode_path "?user/automation"
automationDirExt = ""

lifecycleBaseDir = "#{automationBaseDir}/lifecycle"
lifecycleDirExt = "DepLifecycle"

testBaseDir = "#{automationBaseDir}/test"
testDirExt = "DepUnit"

sqliteSchemaBaseDir = "#{automationBaseDir}/schema"
sqliteSchemaDirExt = "DepSqlite"

class LocationResolver
  msgs = {
    getPath: {
      illegalNesting: "Invalid base name '%s' - nesting is not legal for %s file of category '%s'."
      invalidPath: "Base name '%s' for %s file of category '%s' expands to an invalid path: %s "
    }
  }

  @logger = Logger fileBaseName: "DepCtrl.LocationResolver", toFile: true

  @Mode = Enum "LocationResolver.Mode", {
    Nested: 0
    AutomationFlat: 1
    AllFlat: 2
  }, @logger

  @Category = Enum "LocationResolver.Category", {
    Script: "script"
    Test: "test"
    Lifecycle: "lifecycle"
    SqliteSchema: "sqliteschema"
  }, @logger

  @Directories = {
    [@Category.Script]: {
      "#{automationBaseDir}/autoload",
      "#{automationBaseDir}/include",
      Base: automationBaseDir,
      Extension: automationDirExt
      Mode: @Mode.AutomationFlat
    }
    [@Category.Test]: {
      "#{testBaseDir}/#{testDirExt}/#{Common.name.scriptType.canonical[1]}",
      "#{testBaseDir}/#{testDirExt}/#{Common.name.scriptType.canonical[2]}",
      Base: testBaseDir,
      Extension: testDirExt
      Mode: @Mode.Nested
    }
    [@Category.Lifecycle]: {
      "#{lifecycleBaseDir}/#{lifecycleDirExt}/#{Common.name.scriptType.canonical[1]}",
      "#{lifecycleBaseDir}/#{lifecycleDirExt}/#{Common.name.scriptType.canonical[2]}",
      Base: lifecycleBaseDir,
      Extension: lifecycleDirExt
      Mode: @Mode.Nested
    }
    [@Category.SqliteSchema]: {
      "#{sqliteSchemaBaseDir}/#{sqliteSchemaDirExt}/#{Common.name.scriptType.canonical[1]}",
      "#{sqliteSchemaBaseDir}/#{sqliteSchemaDirExt}/#{Common.name.scriptType.canonical[2]}",
      Base: sqliteSchemaBaseDir,
      Extension: sqliteSchemaDirExt
      Mode: @Mode.Nested
    }
  }

  new: (@namespace, @scriptType, @logger = @@logger) =>
    @logger\assert Common.validateNamespace @namespace
    @logger\assert DependencyRecord.ScriptType\validate @scriptType, "scriptType"

    @directories = {k, v[@scriptType] for k, v in pairs @@Directories}

  getPath: (baseName, category) =>
    validCategory, msg = @@Category\validate category, "category"
    return nil, msg unless validCategory

    if @@Directories[category].Mode != @@Mode.Nested and baseName\match "[/\\]"
      return nil, msgs.getPath.illegalNesting\format baseName,
        Common.terms.scriptType.singular[@scriptType], @@Category\describe category

    fullPath, errMsg, dir, fileName = fileOps.validateFullPath "#{@getPathPrefix category}#{baseName}"
    return nil, msgs.getPath.invalidPath\format baseName, Common.terms.scriptType.singular[@scriptType],
      @@Category\describe(category), errMsg unless fullPath

    return fullPath, dir, fileName

  getPathPrefix: (category) =>
    validCategory, msg = @@Category\validate category, "category"
    return nil, msg unless validCategory

    return table.concat {
      @directories[category],
      @@Directories[category].Mode == @@Mode.Nested and @namespace\gsub("%.","/") or @namespace
    }, "/"

  require: (category, script) =>
    validCategory, msg = @@Category\validate category, "category"
    return nil, msg unless validCategory

    parts, haveExtension = {}, @@Directories[category].Extension != ""

    table.insert parts, @@Directories[category].Extension if haveExtension
    table.insert parts, @namespace
    table.insert parts, Common.name.scriptType.canonical[@scriptType]
    table.insert parts, script if script

    return pcall require, table.concat parts, '.'

