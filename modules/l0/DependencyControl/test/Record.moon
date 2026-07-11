-- Record tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "Record")!
() ->
  ffi       = require "ffi"
  constants = require "l0.DependencyControl.Constants"
  Common    = require "l0.DependencyControl.Common"
  FileOps   = require "l0.DependencyControl.FileOps"
  Record    = require "l0.DependencyControl.Record"
  Stub      = require "l0.DependencyControl.Stub"

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

  -- fileOps.attributes stub that reports a "file" mode for exactly the given full paths.
  stubFilesPresent = (ut, present) ->
    set = {p, true for p in *present}
    (ut\stub FILEOPS_MODULE_NAME, "attributes")\calls (path, key) ->
      return "file", path if set[path]
      return false, path

  -- Normalize a sub-path under a base dir the same way getPossibleEntryPointPaths does,
  -- so expected paths in tests always match what the production code produces.
  entryPath = (baseDir, subPath) -> FileOps.validateFullPath subPath, false, baseDir

  moduleRecord = {
    scriptType: Common.ScriptType.Module, namespace: "l0.Foo",
    getPossibleEntryPointPaths: Record.getPossibleEntryPointPaths,
    getEntryPointPath: Record.getEntryPointPath
  }
  macroRecord = {
    scriptType: Common.ScriptType.Automation, namespace: "l0.Foo.Bar",
    getPossibleEntryPointPaths: Record.getPossibleEntryPointPaths,
    getEntryPointPath: Record.getEntryPointPath
  }

  {
    _description: "Tests for Record, the core DependencyControl record class."

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
      rec = {version: 65793, __class: Record}
      ut\assertTruthy Record.checkVersion rec, 65793

    checkVersion_greater: (ut) ->
      rec = {version: 65793, __class: Record}
      ut\assertTruthy Record.checkVersion rec, "1.0.0"

    checkVersion_older: (ut) ->
      rec = {version: 65793, __class: Record}
      ut\assertFalsy Record.checkVersion rec, "2.0.0"

    checkVersion_recordArg: (ut) ->
      rec = {version: 65793, __class: Record}
      otherRec = {version: 65536, __class: Record}
      ut\assertTruthy Record.checkVersion rec, otherRec

    setVersion_validString: (ut) ->
      rec = {}
      result = Record.setVersion rec, "2.3.4"
      ut\assertEquals result, 131844
      ut\assertEquals rec.version, 131844

    setVersion_validNumber: (ut) ->
      rec = {}
      result = Record.setVersion rec, 65793
      ut\assertEquals result, 65793

    setVersion_invalid: (ut) ->
      rec = {}
      result, err = Record.setVersion rec, "x.y.z"
      ut\assertNil result
      ut\assertString err

    validateNamespace_valid: (ut) ->
      rec = {namespace: "l0.DependencyControl", virtual: false, __class: Record}
      ut\assertTrue Record.validateNamespace rec

    validateNamespace_invalid_noDot: (ut) ->
      rec = {namespace: "no-dots", virtual: false, __class: Record}
      ut\assertFalse Record.validateNamespace rec

    validateNamespace_invalid_trailingDot: (ut) ->
      rec = {namespace: "l0.", virtual: false, __class: Record}
      ut\assertFalse Record.validateNamespace rec

    validateNamespace_virtual: (ut) ->
      rec = {namespace: "bad", virtual: true, __class: Record}
      ut\assertTrue Record.validateNamespace rec

    uninstall_virtual: (ut) ->
      rec = {
        virtual: true,
        scriptType: Common.ScriptType.Automation,
        name: "TestScript",
        __class: {RecordType: Common.RecordType, terms: Common.terms}
      }
      result, err = Record.uninstall rec
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
      result, err = Record.uninstall rec
      ut\assertNil result
      ut\assertString err
      ut\assertContains err, "unmanaged"

    getSubmodules_virtual: (ut) ->
      rec = {
        virtual: true,
        recordType: Common.RecordType.Managed,
        scriptType: Common.ScriptType.Module,
        __class: {RecordType: Common.RecordType, ScriptType: Common.ScriptType}
      }
      ut\assertNil Record.getSubmodules rec

    getSubmodules_unmanaged: (ut) ->
      rec = {
        virtual: false,
        recordType: Common.RecordType.Unmanaged,
        scriptType: Common.ScriptType.Module,
        __class: {RecordType: Common.RecordType, ScriptType: Common.ScriptType}
      }
      ut\assertNil Record.getSubmodules rec

    getSubmodules_nonModule: (ut) ->
      rec = {
        virtual: false,
        recordType: Common.RecordType.Managed,
        scriptType: Common.ScriptType.Automation,
        __class: {RecordType: Common.RecordType, ScriptType: Common.ScriptType}
      }
      ut\assertNil Record.getSubmodules rec

    getConfigFileName_basic: (ut) ->
      ut\stub(aegisub, "decode_path")\calls (path) -> path
      rec = {configFile: "test.json", __class: {configDir: "?user/config"}}
      result = Record.getConfigFileName rec
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
      Record.registerMacro rec, "MyMacro", "My macro", process
      ut\assertEquals #registered, 1
      ut\assertContains registered[1][1], "MyMacro"
      registerTestsStub\assertCalledOnceWith rec
      -- the macro is recorded under its name, exposing the unhooked process to the test suite
      ut\assertIs rec.registeredMacros.MyMacro.process, process

    -- namespace registry: getRegisteredRecord is the public lookup; registration happens
    -- internally (via the constructor), so these seed the process-global registry directly
    -- with unique namespaces. Teardown removes every key not present at setup time.

    registry_getReturnsRegistered: (ut) ->
      ns = uniqueName "regns"
      rec = {namespace: ns}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      ut\assertIs Record\getRegisteredRecord(ns), rec

    registry_getMissing: (ut) ->
      ut\assertNil Record\getRegisteredRecord uniqueName "absent"

    registry_getSkipsVirtual: (ut) ->
      ns = uniqueName "virtns"
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = {namespace: ns, virtual: true}
      ut\assertNil Record\getRegisteredRecord ns

    registry_returnsAfterUnvirtualized: (ut) ->
      ns = uniqueName "virtns"
      rec = {namespace: ns, virtual: true}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      ut\assertNil Record\getRegisteredRecord ns
      rec.virtual = false
      ut\assertIs Record\getRegisteredRecord(ns), rec

    registry_getRegisteredReturnsCopy: (ut) ->
      ns = uniqueName "allns"
      rec = {namespace: ns}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      records = Record\getAllRegisteredRecords!
      ut\assertIs records[ns], rec
      -- a shallow copy: mutating the returned table must not affect the live registry
      records[ns] = nil
      ut\assertIs _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns], rec

    registry_getRegisteredIncludesVirtual: (ut) ->
      ns = uniqueName "allvirtns"
      rec = {namespace: ns, virtual: true}
      _G[DEPCTRL_RECORDS_GLOBAL_KEY][ns] = rec
      ut\assertIs Record\getAllRegisteredRecords![ns], rec

    -- Regression: the constructor must populate @provides (normalizing bare strings to ModuleAlias
    -- tables) and register every alias with the module-provides searcher. A field/local mix-up that
    -- left @provides nil silently disabled both alias resolution and update-feed `provides` mirroring.
    construct_populatesAndRegistersProvides: (ut) ->
      ModuleProvider = require "l0.DependencyControl.ModuleProvider"
      ns, alias = uniqueName("prov.mod"), uniqueName "alias"
      rec = Record {moduleName: ns, version: "1.0.0", feed: "https://example.com/feed.json",
                    provides: {{name: alias, version: "^1"}, "bare.#{ns}"}}
      ut\assertNotNil rec.provides
      ut\assertEquals #rec.provides, 2
      ut\assertEquals rec.provides[1].name, alias
      ut\assertEquals rec.provides[1].version, "^1"
      ut\assertEquals rec.provides[2].name, "bare.#{ns}"   -- bare string normalized to a table
      ut\assertEquals ModuleProvider\getProvider(alias), ns
      ut\assertEquals ModuleProvider\getProvider("bare.#{ns}"), ns

    -- getFileCache: a shared cache under the configured cache base, this script's namespace, and the given name
    getFileCache_namespacedUnderConfigBase: (ut) ->
      fakeSelf = {namespace: "l0.test.script", __class: {config: {c: {paths: {cache: "?user/cache"}}}}}
      cache = Record.getFileCache fakeSelf, "thumbnails"
      ut\assertNotNil cache
      ut\assertMatches cache.cacheDir, "l0%.test%.script/thumbnails$"

    -- getVersionNumber/getVersionString: deprecated <=0.6.x compat methods — callable on an instance and
    -- defaulting to the record's own version (regression: they'd been class fields, unreachable via rec\method)
    getVersion_compatMethods: (ut) ->
      SemanticVersion = require "l0.DependencyControl.SemanticVersion"
      fakeSelf = setmetatable {version: SemanticVersion\toNumber "1.2.3"}, __index: Record.__base
      ut\assertEquals fakeSelf\getVersionString!, "1.2.3"                                 -- defaults to @version
      ut\assertEquals fakeSelf\getVersionNumber("2.0.0"), SemanticVersion\toNumber "2.0.0"
      ut\assertEquals fakeSelf\getVersionString(SemanticVersion\toNumber "3.1.0"), "3.1.0"

    -- loadConfig imports recordType from the stored config like any other persisted field
    loadConfig_importsRecordType: (ut) ->
      -- __base.loadConfig: the instance method (Record.loadConfig is a distinct static for the global config)
      record = setmetatable {
        __class: Record, virtual: false, namespace: "l0.x", scriptType: Common.ScriptType.Module
        config: {load: (=> true), c: {recordType: Common.RecordType.Unmanaged}}
      }, __index: Record.__base
      Record.__base.loadConfig record, true
      ut\assertEquals record.recordType, Common.RecordType.Unmanaged

    _order: {
      "getFileCache_namespacedUnderConfigBase", "getVersion_compatMethods",
      "loadConfig_importsRecordType",
      "module_dataOnly", "module_initLayout", "module_alsoUnderUser", "module_userOnly",
      "notInstalled", "portable", "macro_dataOnly",
      "checkVersion_equal", "checkVersion_greater", "checkVersion_older", "checkVersion_recordArg",
      "setVersion_validString", "setVersion_validNumber", "setVersion_invalid",
      "validateNamespace_valid", "validateNamespace_invalid_noDot",
      "validateNamespace_invalid_trailingDot", "validateNamespace_virtual",
      "uninstall_virtual", "uninstall_unmanaged",
      "getSubmodules_virtual", "getSubmodules_unmanaged", "getSubmodules_nonModule",
      "getConfigFileName_basic", "registerMacro_basic",
      "registry_getReturnsRegistered", "registry_getMissing",
      "registry_getSkipsVirtual", "registry_returnsAfterUnvirtualized",
      "registry_getRegisteredReturnsCopy", "registry_getRegisteredIncludesVirtual",
      "construct_populatesAndRegistersProvides"
    }
  }
