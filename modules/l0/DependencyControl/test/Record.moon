-- Record tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "Record")!
() ->
  constants = require "l0.DependencyControl.Constants"
  Common    = require "l0.DependencyControl.Common"
  Record    = require "l0.DependencyControl.Record"
  Stub      = require "l0.DependencyControl.Stub"

  DEPCTRL_RECORDS_GLOBAL_KEY = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Records"

  uniqueName = (prefix) -> "#{prefix}_#{'%08X'\format math.random 0, 16^8-1}"

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
        __class: {updater: updaterMock}
      }
      Record.registerMacro rec, "MyMacro", "My macro", (->)
      ut\assertEquals #registered, 1
      ut\assertContains registered[1][1], "MyMacro"
      registerTestsStub\assertCalledOnceWith rec

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

    _order: {
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
