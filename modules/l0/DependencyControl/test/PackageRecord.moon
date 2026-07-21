-- PackageRecord tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "PackageRecord") basePath
(basePath) ->
  ffi = require "ffi"
  constants = require "l0.DependencyControl.Constants"
  Common = require "l0.DependencyControl.Common"
  FileOps = require "l0.DependencyControl.FileOps"
  PackageRecord = require "l0.DependencyControl.PackageRecord"
  Stub = require "l0.DependencyControl.Stub"
  {:stubSelf} = require "l0.DependencyControl.test.helpers.stub-helpers"

  DEPCTRL_RECORDS_GLOBAL_KEY = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Records"
  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"

  uniqueName = (prefix) -> "#{prefix}_#{'%08X'\format math.random 0, 16^8-1}"

  -- Drive prefix so stubbed paths are recognized as absolute on Windows too.
  DRIVE = ffi.os == "Windows" and "C:" or ""

  -- Map the ?user / ?data tokens to distinct absolute roots so the two automation
  -- directories differ (the non-portable case getEntryPointPath guards against).
  stubDistinctRoots = (ut) ->
    (ut\stub aegisub, "decode_path")\calls (path) ->
      ((path\gsub "^%?user", "#{DRIVE}/user")\gsub "^%?data", "#{DRIVE}/data")

  -- fileOps.getAttributes stub that reports a "file" mode for exactly the given full paths.
  stubFilesPresent = (ut, present) ->
    set = {p, true for p in *present}
    (ut\stub FILEOPS_MODULE_NAME, "getAttributes")\calls (path, key) ->
      return {attr: "file", path: path} if set[path]
      return {attr: false, path: path}

  -- Normalize a sub-path under a base dir the same way getPossibleEntryPointPaths does,
  -- so expected paths in tests always match what the production code produces.
  entryPath = (baseDir, subPath) -> FileOps.validateFullPath subPath, false, baseDir

  moduleRecord = {
    scriptType: Common.ScriptType.Module, namespace: "l0.Foo",
    getPossibleEntryPointPaths: PackageRecord.getPossibleEntryPointPaths,
    getEntryPointPath: PackageRecord.getEntryPointPath
  }
  macroRecord = {
    scriptType: Common.ScriptType.Automation, namespace: "l0.Foo.Bar",
    getPossibleEntryPointPaths: PackageRecord.getPossibleEntryPointPaths,
    getEntryPointPath: PackageRecord.getEntryPointPath
  }

  {
    _description: "Tests for PackageRecord, the core DependencyControl record class."

    ---@param ut UnitTest
    _setup: (ut) ->
      -- Snapshot the live registry keys so teardown can remove only what the tests added.
      registry = _G[DEPCTRL_RECORDS_GLOBAL_KEY]
      snapshot = {}
      if registry
        snapshot[k] = true for k, _ in pairs registry
      {:snapshot}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      registry = _G[DEPCTRL_RECORDS_GLOBAL_KEY]
      return unless registry and ctx
      -- Collect first, then remove, to avoid modifying the table during iteration.
      toRemove = [k for k, _ in pairs registry when not ctx.snapshot[k]]
      registry[k] = nil for k in *toRemove

    -- getEntryPointPath: locates a record's entry point and reports whether it is under the
    -- ?user or ?data automation directory.

    -- a module present only under ?data: found there, isUserPath = false
    module_dataOnly: (ut) ->
      stubDistinctRoots ut
      dataDir = aegisub.decode_path "?data/automation/include"
      expected = entryPath dataDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertFalse isUserPath

    -- modules may also be deployed as <namespace>/init.ext
    module_initLayout: (ut) ->
      stubDistinctRoots ut
      dataDir = aegisub.decode_path "?data/automation/include"
      expected = entryPath dataDir, "l0/Foo/init.lua"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertFalse isUserPath

    -- ?user copy takes precedence: found there, isUserPath = true
    module_alsoUnderUser: (ut) ->
      stubDistinctRoots ut
      userDir = aegisub.decode_path "?user/automation/include"
      dataDir = aegisub.decode_path "?data/automation/include"
      expected = entryPath userDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected, entryPath(dataDir, "l0/Foo.moon")}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertTrue isUserPath

    module_userOnly: (ut) ->
      stubDistinctRoots ut
      userDir = aegisub.decode_path "?user/automation/include"
      expected = entryPath userDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertTrue isUserPath

    -- not installed anywhere yet → both return values are nil
    notInstalled: (ut) ->
      stubDistinctRoots ut
      stubFilesPresent ut, {}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertNil path
      ut\assertNil isUserPath

    -- portable / "Local Config": ?user and ?data resolve to the same directory, so the file
    -- is found under ?user first and isUserPath is always true
    portable: (ut) ->
      (ut\stub aegisub, "decode_path")\calls (path) ->
        ((path\gsub "^%?user", "#{DRIVE}/same")\gsub "^%?data", "#{DRIVE}/same")
      sameDir = aegisub.decode_path "?user/automation/include"
      expected = entryPath sameDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertTrue isUserPath

    -- automation scripts live as a single file in the autoload directory
    macro_dataOnly: (ut) ->
      stubDistinctRoots ut
      dataDir = aegisub.decode_path "?data/automation/autoload"
      expected = entryPath dataDir, "l0.Foo.Bar.lua"
      stubFilesPresent ut, {expected}
      path, isUserPath = macroRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertFalse isUserPath

    checkVersion_equal: (ut) ->
      rec = {version: 65793, __class: PackageRecord}
      ut\assertTruthy PackageRecord.checkVersion rec, 65793

    checkVersion_greater: (ut) ->
      rec = {version: 65793, __class: PackageRecord}
      ut\assertTruthy PackageRecord.checkVersion rec, "1.0.0"

    checkVersion_older: (ut) ->
      rec = {version: 65793, __class: PackageRecord}
      ut\assertFalsy PackageRecord.checkVersion rec, "2.0.0"

    checkVersion_recordArg: (ut) ->
      rec = {version: 65793, __class: PackageRecord}
      otherRec = {version: 65536, __class: PackageRecord}
      ut\assertTruthy PackageRecord.checkVersion rec, otherRec

    setVersion_validString: (ut) ->
      rec = {}
      result = PackageRecord.setVersion rec, "2.3.4"
      ut\assertEquals result, 131844
      ut\assertEquals rec.semanticVersion\toPacked!, 131844 -- stored on the canonical instance

    setVersion_validNumber: (ut) ->
      rec = {}
      result = PackageRecord.setVersion rec, 65793
      ut\assertEquals result, 65793

    setVersion_invalid: (ut) ->
      rec = {}
      result, err = PackageRecord.setVersion rec, "x.y.z"
      ut\assertNil result
      ut\assertString err

    -- the `version` accessor: a packed-int view over the canonical @semanticVersion instance
    version_accessorGetsAndSets: (ut) ->
      SemanticVersion = require "l0.DependencyControl.SemanticVersion"
      -- a real PackageRecord-metatabled instance so `version` dispatches through the installed accessor
      rec = setmetatable {semanticVersion: SemanticVersion "1.2.3"}, PackageRecord.__base
      ut\assertEquals rec.version, SemanticVersion\toPacked "1.2.3" -- getter yields the packed int
      rec.version = "2.0.0" -- setter accepts a string
      ut\assertEquals tostring(rec.semanticVersion), "2.0.0" -- rebuilt the canonical instance
      ut\assertEquals rec.version, SemanticVersion\toPacked "2.0.0"

    validateNamespace_valid: (ut) ->
      rec = {namespace: "l0.DependencyControl", virtual: false, __class: PackageRecord}
      ut\assertTrue PackageRecord.validateNamespace rec

    validateNamespace_invalid_noDot: (ut) ->
      rec = {namespace: "no-dots", virtual: false, __class: PackageRecord}
      ut\assertFalse PackageRecord.validateNamespace rec

    validateNamespace_invalid_trailingDot: (ut) ->
      rec = {namespace: "l0.", virtual: false, __class: PackageRecord}
      ut\assertFalse PackageRecord.validateNamespace rec

    validateNamespace_virtual: (ut) ->
      rec = {namespace: "bad", virtual: true, __class: PackageRecord}
      ut\assertTrue PackageRecord.validateNamespace rec

    uninstall_virtual: (ut) ->
      rec = {
        virtual: true,
        scriptType: Common.ScriptType.Automation,
        name: "TestScript",
        __class: {RecordType: Common.RecordType, terms: Common.terms}
      }
      result, err = PackageRecord.uninstall rec
      ut\assertNil result
      ut\assertString err
      ut\assertContains err, "virtual"

    uninstall_unmanaged: (ut) ->
      rec = {
        virtual: false,
        recordType: Common.RecordType.Unmanaged,
        scriptType: Common.ScriptType.Module,
        name: "TestMod",
        __class: {RecordType: Common.RecordType, terms: Common.terms}
      }
      result, err = PackageRecord.uninstall rec
      ut\assertNil result
      ut\assertString err
      ut\assertContains err, "unmanaged"

    -- uninstall removes only the record's own files: a module's directory must equal the last
    -- namespace part exactly, so a sibling package sharing the name prefix survives the
    -- recursive delete
    uninstall_moduleSparesPrefixSiblings: (ut) ->
      root = FileOps.joinPath basePath, "uninstall-mod"
      ut\assertString root
      FileOps.mkdir FileOps.joinPath(root, "l0", "Functional"), false, true
      FileOps.mkdir FileOps.joinPath(root, "l0", "FunctionalExtras"), false, true
      FileOps.writeFile FileOps.joinPath(root, "l0", "Functional.moon"), "-- mod", true
      FileOps.writeFile FileOps.joinPath(root, "l0", "Functional", "sub.moon"), "-- sub", true
      FileOps.writeFile FileOps.joinPath(root, "l0", "FunctionalExtras.moon"), "-- sibling", true
      FileOps.writeFile FileOps.joinPath(root, "l0", "FunctionalExtras", "sub.moon"), "-- sibling sub", true
      rec = {
        virtual: false, recordType: Common.RecordType.Managed,
        scriptType: Common.ScriptType.Module,
        namespace: "l0.Functional", moduleName: "l0.Functional",
        automationDir: root,
        config: {delete: ->}, getSubmodules: -> nil,
        __class: {RecordType: Common.RecordType, terms: Common.terms}
      }
      success, results = PackageRecord.uninstall rec
      ut\assertTrue success
      ut\assertTable results
      ut\assertFalse FileOps.exists FileOps.joinPath(root, "l0", "Functional.moon"), "file"
      ut\assertFalse FileOps.exists FileOps.joinPath(root, "l0", "Functional"), "directory"
      ut\assertTrue FileOps.exists FileOps.joinPath(root, "l0", "FunctionalExtras.moon"), "file"
      ut\assertTrue FileOps.exists FileOps.joinPath(root, "l0", "FunctionalExtras", "sub.moon"), "file"

    -- automation file matching anchors the namespace on both sides and escapes pattern magic
    -- (a hyphen would otherwise act as a lazy quantifier)
    uninstall_automationEscapesAndTerminates: (ut) ->
      root = FileOps.joinPath basePath, "uninstall-auto"
      ut\assertString root
      FileOps.mkdir root, false, true
      FileOps.writeFile FileOps.joinPath(root, "a-mo.Script.moon"), "-- macro", true
      FileOps.writeFile FileOps.joinPath(root, "a-mo.ScriptExtra.moon"), "-- other macro", true
      FileOps.writeFile FileOps.joinPath(root, "amo.Script.moon"), "-- hyphen bait", true
      rec = {
        virtual: false, recordType: Common.RecordType.Managed,
        scriptType: Common.ScriptType.Automation,
        namespace: "a-mo.Script",
        automationDir: root,
        config: {delete: ->}, getSubmodules: -> nil,
        __class: {RecordType: Common.RecordType, terms: Common.terms}
      }
      success, results = PackageRecord.uninstall rec
      ut\assertTrue success
      ut\assertTable results
      ut\assertFalse FileOps.exists FileOps.joinPath(root, "a-mo.Script.moon"), "file"
      ut\assertTrue FileOps.exists FileOps.joinPath(root, "a-mo.ScriptExtra.moon"), "file"
      ut\assertTrue FileOps.exists FileOps.joinPath(root, "amo.Script.moon"), "file"

    getSubmodules_virtual: (ut) ->
      rec = {
        virtual: true,
        recordType: Common.RecordType.Managed,
        scriptType: Common.ScriptType.Module,
        __class: {RecordType: Common.RecordType, ScriptType: Common.ScriptType}
      }
      ut\assertNil PackageRecord.getSubmodules rec

    getSubmodules_unmanaged: (ut) ->
      rec = {
        virtual: false,
        recordType: Common.RecordType.Unmanaged,
        scriptType: Common.ScriptType.Module,
        __class: {RecordType: Common.RecordType, ScriptType: Common.ScriptType}
      }
      ut\assertNil PackageRecord.getSubmodules rec

    getSubmodules_nonModule: (ut) ->
      rec = {
        virtual: false,
        recordType: Common.RecordType.Managed,
        scriptType: Common.ScriptType.Automation,
        __class: {RecordType: Common.RecordType, ScriptType: Common.ScriptType}
      }
      ut\assertNil PackageRecord.getSubmodules rec

    getConfigFileName_basic: (ut) ->
      ut\stub(aegisub, "decode_path")\calls (path) -> path
      rec = {configFile: "test.json", __class: {configDir: "?user/config"}}
      result = PackageRecord.getConfigFileName rec
      ut\assertString result
      ut\assertContains result, "test.json"
      ut\assertContains result, "?user/config"

    registerMacro_basic: (ut) ->
      registered = {}
      ut\stub(aegisub, "register_macro")\calls (...) -> registered[#registered+1] = table.pack ...
      updaterMock = {scheduleUpdate: (->), releaseLock: ->}
      registerTestsStub = Stub!
      rec = {
        name: "TestScript",
        description: "desc",
        config: {c: {customMenu: "Automation"}},
        registerTests: registerTestsStub,
        registeredMacros: {},
        __class: {updater: updaterMock}
      }
      process = (->)
      PackageRecord.registerMacro rec, "MyMacro", "My macro", process
      ut\assertEquals #registered, 1
      ut\assertContains registered[1][1], "MyMacro"
      registerTestsStub\assertCalledOnceWith rec
      -- the macro is recorded under its name, exposing the unhooked process to the test suite
      ut\assertIs rec.registeredMacros.MyMacro.process, process

    -- namespace registry: getRegisteredRecord is the public lookup; registration happens
    -- internally (via the constructor), so these seed the process-global registry directly
    -- with unique namespaces. Teardown removes every key not present at setup time.

    registry_getReturnsRegistered: (ut) ->
      ns = uniqueName "registered"
      rec = {namespace: ns}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      ut\assertIs PackageRecord\getRegisteredRecord(ns), rec

    registry_getMissing: (ut) ->
      ut\assertNil PackageRecord\getRegisteredRecord uniqueName "absent"

    registry_getSkipsVirtual: (ut) ->
      ns = uniqueName "virtual"
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = {namespace: ns, virtual: true}
      ut\assertNil PackageRecord\getRegisteredRecord ns

    registry_returnsAfterUnvirtualized: (ut) ->
      ns = uniqueName "virtual"
      rec = {namespace: ns, virtual: true}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      ut\assertNil PackageRecord\getRegisteredRecord ns
      rec.virtual = false
      ut\assertIs PackageRecord\getRegisteredRecord(ns), rec

    registry_getRegisteredReturnsCopy: (ut) ->
      ns = uniqueName "allRegistered"
      rec = {namespace: ns}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      records = PackageRecord\getAllRegisteredRecords!
      ut\assertIs records[ns], rec
      -- a shallow copy: mutating the returned table must not affect the live registry
      records[ns] = nil
      ut\assertIs _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns], rec

    registry_getRegisteredIncludesVirtual: (ut) ->
      ns = uniqueName "allVirtual"
      rec = {namespace: ns, virtual: true}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      ut\assertIs PackageRecord\getAllRegisteredRecords![ns], rec

    -- Regression: the constructor must populate @provides (normalizing bare strings to ModuleAlias
    -- tables) and register every alias with the module-provides searcher. A field/local mix-up that
    -- left @provides nil silently disabled both alias resolution and update-feed `provides` mirroring.
    construct_populatesAndRegistersProvides: (ut) ->
      ModuleProvider = require "l0.DependencyControl.ModuleProvider"
      ns, alias = uniqueName("prov.mod"), uniqueName "alias"
      rec = PackageRecord {moduleName: ns, version: "1.0.0", feed: "https://example.com/feed.json",
        provides: {{name: alias, version: "^1"}, "bare.#{ns}"}}
      ut\assertNotNil rec.provides
      ut\assertEquals #rec.provides, 2
      ut\assertEquals rec.provides[1].name, alias
      ut\assertEquals rec.provides[1].version, "^1"
      ut\assertEquals rec.provides[2].name, "bare.#{ns}" -- bare string normalized to a table
      ut\assertEquals ModuleProvider\getProvider(alias), ns
      ut\assertEquals ModuleProvider\getProvider("bare.#{ns}"), ns

    -- getFileCache: a shared cache under the configured cache base, this script's namespace, and the given name
    getFileCache_namespacedUnderConfigBase: (ut) ->
      fakeSelf = {namespace: "l0.test.script", __class: {config: {c: {paths: {cache: "?user/cache"}}}}}
      cache = PackageRecord.getFileCache fakeSelf, "thumbnails"
      ut\assertNotNil cache
      ut\assertMatches cache.cacheDir, "l0%.test%.script/thumbnails$"

    -- getVersionNumber/getVersionString: deprecated <=0.6.x compat methods — callable on an instance and
    -- defaulting to the record's own version (regression: they'd been class fields, unreachable via rec\method)
    getVersion_compatMethods: (ut) ->
      SemanticVersion = require "l0.DependencyControl.SemanticVersion"
      fakeSelf = stubSelf PackageRecord, {version: SemanticVersion\toPacked "1.2.3"}
      ut\assertEquals fakeSelf\getVersionString!, "1.2.3" -- defaults to @version
      ut\assertEquals fakeSelf\getVersionNumber("2.0.0"), SemanticVersion\toPacked "2.0.0"
      ut\assertEquals fakeSelf\getVersionString(SemanticVersion\toPacked "3.1.0"), "3.1.0"

    -- loadConfig imports recordType from the stored config like any other persisted field
    loadConfig_importsRecordType: (ut) ->
      record = stubSelf PackageRecord, {
        __class: PackageRecord, virtual: false, namespace: "l0.x", scriptType: Common.ScriptType.Module
        config: {load: (=> true), c: {recordType: Common.RecordType.Unmanaged}}
      }
      PackageRecord.__base.loadConfig record, true
      ut\assertEquals record.recordType, Common.RecordType.Unmanaged

    _order: {
      "getFileCache_namespacedUnderConfigBase", "getVersion_compatMethods",
      "loadConfig_importsRecordType",
      "module_dataOnly", "module_initLayout", "module_alsoUnderUser", "module_userOnly",
      "notInstalled", "portable", "macro_dataOnly",
      "checkVersion_equal", "checkVersion_greater", "checkVersion_older", "checkVersion_recordArg",
      "setVersion_validString", "setVersion_validNumber", "setVersion_invalid", "version_accessorGetsAndSets",
      "validateNamespace_valid", "validateNamespace_invalid_noDot",
      "validateNamespace_invalid_trailingDot", "validateNamespace_virtual",
      "uninstall_virtual", "uninstall_unmanaged",
      "uninstall_moduleSparesPrefixSiblings", "uninstall_automationEscapesAndTerminates",
      "getSubmodules_virtual", "getSubmodules_unmanaged", "getSubmodules_nonModule",
      "getConfigFileName_basic", "registerMacro_basic",
      "registry_getReturnsRegistered", "registry_getMissing",
      "registry_getSkipsVirtual", "registry_returnsAfterUnvirtualized",
      "registry_getRegisteredReturnsCopy", "registry_getRegisteredIncludesVirtual",
      "construct_populatesAndRegistersProvides"
    }
  }
