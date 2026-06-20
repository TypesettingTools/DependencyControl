-- Updater tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "Updater")!
() ->
  ffi     = require "ffi"
  Common  = require "l0.DependencyControl.Common"
  FileOps = require "l0.DependencyControl.FileOps"
  Record  = require "l0.DependencyControl.Record"
  Updater = require "l0.DependencyControl.Updater"
  SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"

  UpdateTask = Updater.UpdateTask

  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"

  -- A candidate as pooled in run(): a feed record (with the fields selectCandidate reads — version
  -- string, namespace, checkPlatform predicate, files) plus its trust band and feed URL.
  -- opts: namespace, feedUrl, platform (false to fail platform), files (set {} to exclude).
  makeCandidate = (band, version, opts = {}) ->
    {
      :band
      feedUrl: opts.feedUrl or "feed://test"
      direct: opts.direct != false
      providesVersion: opts.providesVersion
      record: {
        namespace: opts.namespace or "l0.cand"
        :version
        files: opts.files == nil and {{}} or opts.files
        checkPlatform: -> opts.platform != false
      }
    }

  -- A stub task self for selectCandidate: it consults targetVersion, logger, record.feed (the
  -- declared-feed tie-break) and record.namespace (the ambiguity log).
  makeSelectTask = (targetVersion, opts = {}) ->
    {
      :targetVersion
      record: {namespace: "json", feed: opts.declaredFeed}
      logger: {log: (_, ...) -> opts.logged[#opts.logged + 1] = {...} if opts.logged}
      __class: UpdateTask
    }

  -- A stub task self for getInstalledProviderFor: its updater.config returns the given persisted module
  -- records (keyed by namespace) from getSectionHandler.
  taskWithInstalledModules = (modulesConfig) ->
    {updater: {config: {getSectionHandler: (_, section) -> {c: modulesConfig}}}, __class: UpdateTask}

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
    _description: "Tests for Record.getEntryPointPath: locates a record's entry point and reports whether it is under the ?user or ?data automation directory."

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

    -- UpdateTask.selectCandidate: ranks the pooled candidates by trust band, then version, then a
    -- deterministic tie-break (declared feed, then namespace); returns the winner or nil if none is eligible.

    -- eligibility: release version must meet the target version
    selectCandidate_filtersByVersion: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.0.0"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(2, "0.9.0", namespace: "l0.old"), makeCandidate(2, "1.5.0", namespace: "l0.ok")}
      ut\assertNotNil chosen
      ut\assertEquals chosen.record.namespace, "l0.ok"

    selectCandidate_noneSatisfiesVersion: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "3.0.0"
      ut\assertNil UpdateTask.selectCandidate task, {makeCandidate(2, "1.0.0"), makeCandidate(2, "2.9.0")}

    -- eligibility: a candidate whose channel can't run on the current platform is skipped
    selectCandidate_skipsUnsupportedPlatform: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(2, "2.0.0", namespace: "l0.win", platform: false), makeCandidate(2, "1.0.0", namespace: "l0.any")}
      ut\assertEquals chosen.record.namespace, "l0.any"

    -- eligibility: a candidate with no files to install is skipped
    selectCandidate_skipsEmptyFiles: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(2, "2.0.0", namespace: "l0.nofiles", files: {}), makeCandidate(2, "1.0.0", namespace: "l0.ok")}
      ut\assertEquals chosen.record.namespace, "l0.ok"

    selectCandidate_noneEligible: (ut) ->
      task = makeSelectTask 0
      ut\assertNil UpdateTask.selectCandidate task, {makeCandidate(2, "2.0.0", platform: false)}

    -- a lower (more trusted) band wins even against a higher-version candidate in a higher band
    selectCandidate_lowerBandBeatsHigherVersion: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(4, "9.9.9", namespace: "l0.untrusted"), makeCandidate(1, "1.0.0", namespace: "l0.trusted")}
      ut\assertEquals chosen.record.namespace, "l0.trusted"
      ut\assertEquals chosen.band, 1

    selectCandidate_highestVersionWithinBand: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task, {makeCandidate(2, "1.0.0", namespace: "l0.a"), makeCandidate(2, "2.0.0", namespace: "l0.b")}
      ut\assertEquals chosen.record.namespace, "l0.b"

    -- same band + version: the candidate from the declared feed wins (even with a higher namespace)
    selectCandidate_declaredFeedTiebreak: (ut) ->
      task = makeSelectTask 0, declaredFeed: "feed://declared"
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(2, "2.0.0", namespace: "l0.a", feedUrl: "feed://other"), makeCandidate(2, "2.0.0", namespace: "l0.z", feedUrl: "feed://declared")}
      ut\assertEquals chosen.record.namespace, "l0.z"

    -- same band + version, neither declared: lexicographically lowest namespace wins; the tie is logged
    selectCandidate_namespaceTiebreakLogged: (ut) ->
      logged = {}
      task = makeSelectTask 0, logged: logged
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(3, "2.0.0", namespace: "l0.b"), makeCandidate(3, "2.0.0", namespace: "l0.a")}
      ut\assertEquals chosen.record.namespace, "l0.a"
      ut\assertTrue #logged > 0

    selectCandidate_unambiguousNoLog: (ut) ->
      logged = {}
      task = makeSelectTask 0, logged: logged
      chosen = UpdateTask.selectCandidate task, {makeCandidate(1, "1.0.0", namespace: "l0.only")}
      ut\assertEquals chosen.record.namespace, "l0.only"
      ut\assertEquals #logged, 0

    -- a provider is judged by the alias range it declares, not its own release version: the unrelated
    -- release 9.9.9 is ignored, and ~1.2 still covers the 1.2.4 target
    selectCandidate_providesVersionRangeSatisfies: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.2.4"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(3, "9.9.9", namespace: "l0.prov", direct: false, providesVersion: "~1.2")}
      ut\assertNotNil chosen
      ut\assertEquals chosen.record.namespace, "l0.prov"

    -- conversely, a high release version can't rescue a provider once its declared range no longer reaches the target
    selectCandidate_providesVersionRangeRejects: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.5.0"
      ut\assertNil UpdateTask.selectCandidate task, {makeCandidate(3, "9.9.9", namespace: "l0.prov", direct: false, providesVersion: "~1.2")}

    -- a target below the declared range stays satisfiable: the provider can still supply a version >= target
    selectCandidate_providesVersionRangeAboveTarget: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.0.0"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(3, "1.0.0", namespace: "l0.prov", direct: false, providesVersion: "~1.2")}
      ut\assertNotNil chosen
      ut\assertEquals chosen.record.namespace, "l0.prov"

    -- a provider that declares no range stands in for any version
    selectCandidate_providerNoRangeMatchesAny: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "5.0.0"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(3, "1.0.0", namespace: "l0.prov", direct: false)}
      ut\assertNotNil chosen
      ut\assertEquals chosen.record.namespace, "l0.prov"

    -- among providers, the release version doesn't drive rank: the wider declared range (higher covered
    -- version) wins even though its provider has the lower release version
    selectCandidate_providerRankedByRangeMaxNotRelease: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.0.0"
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(3, "9.9.9", namespace: "l0.a", direct: false, providesVersion: "^1"),
         makeCandidate(3, "1.0.0", namespace: "l0.b", direct: false, providesVersion: "^2")}
      ut\assertEquals chosen.record.namespace, "l0.b"

    -- UpdateTask.feedMatchesPrefix: case-insensitive, prefix-based block-list matching

    feedMatchesPrefix_exactAndCaseInsensitive: (ut) ->
      ut\assertTrue UpdateTask\feedMatchesPrefix "https://example.com/feed.json", {"https://example.com/feed.json"}
      ut\assertTrue UpdateTask\feedMatchesPrefix "https://Example.COM/Feed.json", {"https://example.com/feed.json"}

    feedMatchesPrefix_hostPrefixBlocksEverythingUnder: (ut) ->
      ut\assertTrue UpdateTask\feedMatchesPrefix "https://example.com/a/b.json", {"https://example.com/"}

    feedMatchesPrefix_noMatch: (ut) ->
      ut\assertFalse UpdateTask\feedMatchesPrefix "https://other.com/feed.json", {"https://example.com/"}

    -- guards: nil url, no entries, and an empty entry (which must not match everything)
    feedMatchesPrefix_guards: (ut) ->
      ut\assertFalse UpdateTask\feedMatchesPrefix nil, {"https://example.com/"}
      ut\assertFalse UpdateTask\feedMatchesPrefix "https://example.com/x", {}
      ut\assertFalse UpdateTask\feedMatchesPrefix "https://example.com/x", {""}

    -- UpdateTask.getInstalledProviderFor: finds the installed module that provides an alias (from the
    -- persisted module config), so resolution can stay pinned to the already-installed provider.

    getInstalledProviderFor_findsByProvides: (ut) ->
      task = taskWithInstalledModules {
        "l0.dkjson": {provides: {{name: "json"}, {name: "dkjson"}}}
        "l0.other":  {provides: {{name: "yaml"}}}
      }
      ut\assertEquals UpdateTask.getInstalledProviderFor(task, "json"), "l0.dkjson"
      ut\assertEquals UpdateTask.getInstalledProviderFor(task, "yaml"), "l0.other"

    getInstalledProviderFor_handlesBareStrings: (ut) ->
      task = taskWithInstalledModules {"l0.prov": {provides: {"toml"}}}
      ut\assertEquals UpdateTask.getInstalledProviderFor(task, "toml"), "l0.prov"

    getInstalledProviderFor_noMatch: (ut) ->
      task = taskWithInstalledModules {"l0.dkjson": {provides: {{name: "json"}}}, "l0.plain": {}}
      ut\assertNil UpdateTask.getInstalledProviderFor task, "xml"

    _order: {
      "module_dataOnly", "module_initLayout",
      "module_alsoUnderUser", "module_userOnly",
      "notInstalled", "portable",
      "macro_dataOnly",
      "selectCandidate_filtersByVersion", "selectCandidate_noneSatisfiesVersion",
      "selectCandidate_skipsUnsupportedPlatform", "selectCandidate_skipsEmptyFiles", "selectCandidate_noneEligible",
      "selectCandidate_lowerBandBeatsHigherVersion", "selectCandidate_highestVersionWithinBand",
      "selectCandidate_declaredFeedTiebreak", "selectCandidate_namespaceTiebreakLogged", "selectCandidate_unambiguousNoLog",
      "selectCandidate_providesVersionRangeSatisfies", "selectCandidate_providesVersionRangeRejects",
      "selectCandidate_providesVersionRangeAboveTarget", "selectCandidate_providerNoRangeMatchesAny",
      "selectCandidate_providerRankedByRangeMaxNotRelease",
      "feedMatchesPrefix_exactAndCaseInsensitive", "feedMatchesPrefix_hostPrefixBlocksEverythingUnder",
      "feedMatchesPrefix_noMatch", "feedMatchesPrefix_guards",
      "getInstalledProviderFor_findsByProvides", "getInstalledProviderFor_handlesBareStrings", "getInstalledProviderFor_noMatch"
    }
  }
