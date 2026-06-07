-- ModuleProvider tests: alias registration, searcher-based resolution, and the shared
-- __depCtrlInit runner. Called from test.moon as: (require "...test.ModuleProvider") basePath, DepCtrl
-- (Names are unique per run since the provider registry is process-global.)
(basePath, DepCtrl) ->
  constants = require "l0.DependencyControl.Constants"
  ModuleProvider = require "l0.DependencyControl.ModuleProvider"
  SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
  
  DEPCTRL_MODULE_INIT_HOOK_NAME = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Init"
  uniqueName = (prefix) -> "#{prefix}_#{'%08X'\format math.random 0, 16^8-1}"

  {
    _description: "Tests for ModuleProvider: alias registration, searcher resolution, and the shared __depCtrlInit runner."

    register_andGetProvider: (ut) ->
      name = uniqueName "alias"
      ut\assertTrue ModuleProvider\register name, "some.provider"
      ut\assertEquals ModuleProvider\getProvider(name), "some.provider"

    register_firstWins: (ut) ->
      name = uniqueName "alias"
      ut\assertTrue ModuleProvider\register name, "first.provider"
      ut\assertFalse ModuleProvider\register name, "second.provider"   -- already registered
      ut\assertEquals ModuleProvider\getProvider(name), "first.provider"

    registerRecord_normalizesAliases: (ut) ->
      stringAlias, tableAlias = uniqueName("string"), uniqueName "table"
      ModuleProvider\registerRecord {moduleName: "prov.A", provides: {stringAlias}}
      ModuleProvider\registerRecord {moduleName: "prov.B", provides: {{name: tableAlias}}}
      ut\assertEquals ModuleProvider\getProvider(stringAlias), "prov.A"
      ut\assertEquals ModuleProvider\getProvider(tableAlias), "prov.B"

    -- end to end: a require of a registered alias resolves to the provider module
    searcher_resolvesAliasToProvider: (ut) ->
      ModuleProvider\install!   -- idempotent; already installed during load
      name = uniqueName "aliasToSemver"
      ModuleProvider\register name, "l0.DependencyControl.SemanticVersioning"
      resolved = require name
      package.loaded[name] = nil   -- don't leak the alias into the module cache
      ut\assertIs resolved, SemanticVersioning

    -- runInitializer: shared __depCtrlInit guard + call (also used by ModuleLoader & UpdateFeed)

    -- a plain module with no initializer is returned untouched
    runInitializer_noInitHook: (ut) ->
      ref = {version: "1.0.0"}
      ut\assertIs ModuleProvider.runInitializer(ref, {__name: constants.DEPCTRL_NAME}), ref

    -- an uninitialized module (raw .version) gets its initializer run with the DepCtrl class
    runInitializer_runsWhenUninitialized: (ut) ->
      fakeDC, received = {__name: constants.DEPCTRL_NAME}, {}
      ref = {version: "raw-version-string", [DEPCTRL_MODULE_INIT_HOOK_NAME]: (dc) -> received[#received + 1] = dc}
      ModuleProvider.runInitializer ref, fakeDC
      ut\assertEquals #received, 1
      ut\assertIs received[1], fakeDC

    -- a module whose .version is already a DepCtrl record must NOT be re-initialized
    runInitializer_skipsWhenInitialized: (ut) ->
      fakeDC, calls = {__name: constants.DEPCTRL_NAME}, 0
      ref = {version: {__class: {__name: constants.DEPCTRL_NAME}}, [DEPCTRL_MODULE_INIT_HOOK_NAME]: -> calls += 1}
      ModuleProvider.runInitializer ref, fakeDC
      ut\assertEquals calls, 0

    _order: {
      "register_andGetProvider", "register_firstWins",
      "registerRecord_normalizesAliases", "searcher_resolvesAliasToProvider",
      "runInitializer_noInitHook", "runInitializer_runsWhenUninitialized",
      "runInitializer_skipsWhenInitialized"
    }
  }
