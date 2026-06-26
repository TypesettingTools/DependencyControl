-- UpdateTask tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "UpdateTask")!
() ->
  Common  = require "l0.DependencyControl.Common"
  UpdateTask = require "l0.DependencyControl.UpdateTask"
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
  SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"

  PromptThreshold = UpdateTask.PromptThreshold
  UpdateReason = UpdateTask.UpdateReason
  SourceChoiceStickiness = UpdateTask.SourceChoiceStickiness
  SourceFeedKind = UpdateTask.SourceFeedKind
  FeedTrustDecision = UpdateTask.FeedTrustDecision
  -- dialog button labels are module-private; the test suite reads them through the test-export seam
  msgs = UnitTestSuite\getTestExports(UpdateTask).msgs

  -- A candidate as pooled in run(): a feed record (with the fields selectCandidate reads — version
  -- string, namespace, checkPlatform predicate, files) plus its trust band and feed URL.
  -- opts: namespace, feedUrl, platform (false to fail platform), files (set {} to exclude).
  makeCandidate = (band, version, opts = {}) ->
    {
      trustBand: band
      feedUrl: opts.feedUrl or "feed://test"
      isDirect: opts.isDirect != false
      providesVersion: opts.providesVersion
      updateRecord: {
        namespace: opts.namespace or "l0.cand"
        :version
        files: opts.files == nil and {{}} or opts.files
        checkPlatform: -> opts.platform != false
      }
    }

  -- A stub task self for selectCandidate: it consults targetVersion, logger, record.feed (the
  -- declared-feed tie-break) and record.namespace (the ambiguity log). The metatable lets selectCandidate
  -- resolve its self-call to getCandidateRankVersion.
  makeSelectTask = (targetVersion, opts = {}) ->
    setmetatable {
      :targetVersion
      record: {namespace: "json", feed: opts.declaredFeed}
      logger: {log: (_, ...) -> opts.logged[#opts.logged + 1] = {...} if opts.logged}
      __class: UpdateTask
    }, __index: UpdateTask.__base

  -- A stub task self for the currentSource helpers (resolveRememberedFeedUrl, matchRememberedCandidate,
  -- feedSourceOf, persistSource). opts: feed (declared feed URL), userFeed, channel, targetVersion,
  -- currentSource (an existing persisted record), modules (installed-module config for provider feed
  -- lookup), onSave (called by record.config\save!). The metatable resolves the helpers' self-calls.
  makeSourceTask = (opts = {}) ->
    setmetatable {
      targetVersion: opts.targetVersion or 0
      channel: opts.channel
      record: {
        feed: opts.feed
        config: {
          c: {userFeed: opts.userFeed, currentSource: opts.currentSource}
          save: (=> opts.onSave! if opts.onSave)
        }
      }
      updater: {config: {getSectionHandler: (_, section) -> {c: opts.modules or {}}}}
      __class: UpdateTask
    }, __index: UpdateTask.__base

  -- A stub task self for shouldPrompt and the prompt methods. opts: reason (the task's UpdateReason,
  -- for shouldPrompt), trustedFeeds, onSave (called by config\save!). The metatable lets the methods
  -- resolve self-calls (e.g. promptTrustFeed -> addTrustedFeed).
  makeInteractiveTask = (opts = {}) ->
    setmetatable {
      reason: opts.reason
      record: {name: "TestMod", namespace: "l0.testmod", virtual: true, scriptType: Common.ScriptType.Module}
      logger: {log: ->}
      updater: {config: {c: {trustedFeeds: opts.trustedFeeds, blockedFeeds: opts.blockedFeeds}, save: (=> opts.onSave! if opts.onSave)}}
      __class: UpdateTask
    }, __index: UpdateTask.__base

  -- A stub task self for getTrustedFeeds/getBlockedFeeds: its updater supplies the official trust lists
  -- (via the getOfficial* methods) and the user config (extraFeeds/trustedFeeds/blockedFeeds).
  makeTrustTask = (opts = {}) ->
    setmetatable {
      updater: {
        config: {c: {extraFeeds: opts.extraFeeds, trustedFeeds: opts.trustedFeeds, blockedFeeds: opts.blockedFeeds}}
        getOfficialTrustedFeeds: => opts.officialTrusted or {}
        getOfficialBlockedFeeds: => opts.officialBlocked or {}
      }
      __class: UpdateTask
    }, __index: UpdateTask.__base

  -- resolve() drives all feed I/O through @loadFeed/@checkFeed and all prompting through @shouldPrompt
  -- /@promptSelectPackageSource/@promptTrustFeed; makeResolveTask stubs those so a test can place exactly
  -- the candidates each cascade tier should see and script the prompt outcomes. `feeds` maps a feedUrl to
  -- { direct?: <directRec>, providers?: {<providerRec>,...} }; a feed absent from the map fails to load.
  directRec = (spec) -> {
    version: spec.version, namespace: spec.namespace or "json", activeChannel: spec.channel or "release"
    files: spec.files == nil and {{}} or spec.files, checkPlatform: -> spec.platform != false
  }
  providerRec = (spec) -> {
    namespace: spec.namespace, provides: {{name: "json", version: spec.providesVersion}}
    files: spec.files == nil and {{}} or spec.files, checkPlatform: -> spec.platform != false
  }

  -- opts: declaredFeed, feeds, currentSource, userFeed, addFeeds, optional, virtual (default true),
  -- targetVersion, version (installed), modules (for provider feed lookup), officialTrusted/officialBlocked,
  -- config {extraFeeds, trustedFeeds, blockedFeeds, offerAllSources, *PromptThreshold}, allowPrompt (gates
  -- both prompts), selectReturn {pick, stickiness} (nil pick = abort), trustReturn (a FeedTrustDecision).
  makeResolveTask = (opts = {}) ->
    cfg = opts.config or {}
    calls = {select: 0, trust: 0}
    task = setmetatable {
      __class: UpdateTask
      :calls
      targetVersion: opts.targetVersion or 0
      optional: opts.optional
      reason: opts.reason
      channel: opts.channel
      addFeeds: opts.addFeeds or {}
      triedFeeds: {}
      _feeds: opts.feeds or {}
      record: {
        feed: opts.declaredFeed
        namespace: "json"
        name: "json"
        version: opts.version or 0
        virtual: opts.virtual != false
        scriptType: Common.ScriptType.Module
        config: {c: {userFeed: opts.userFeed, currentSource: opts.currentSource}}
      }
      updater: {
        renewLock: ->
        getOfficialTrustedFeeds: => opts.officialTrusted or {}
        getOfficialBlockedFeeds: => opts.officialBlocked or {}
        config: {
          c: {
            extraFeeds: cfg.extraFeeds, trustedFeeds: cfg.trustedFeeds, blockedFeeds: cfg.blockedFeeds
            packageChoiceOfferAllSources: cfg.offerAllSources
            packageChoicePromptThreshold: cfg.packageChoicePromptThreshold or PromptThreshold.UserRequested
            feedTrustPromptThreshold: cfg.feedTrustPromptThreshold or PromptThreshold.UserRequested
          }
          getSectionHandler: (_, section) -> {c: opts.modules or {}}
        }
      }
      logger: {log: ->, trace: ->, indent: 0}
      loadFeed: (url) =>
        return nil, "feed not found: #{url}" unless @_feeds[url]
        providers = @_feeds[url].providers or {}
        {__url: url, getProviders: (=> providers)}
      checkFeed: (feed) =>
        d = @_feeds[feed.__url].direct
        return nil, nil unless d
        return d, nil, SemanticVersioning\toNumber d.version
      shouldPrompt: (threshold) => opts.allowPrompt and true or false
      promptSelectPackageSource: (choices, preselect, noLongerAvail) =>
        calls.select += 1
        unpack(opts.selectReturn or {})
      promptTrustFeed: (selected) =>
        calls.trust += 1
        opts.trustReturn
    }, __index: UpdateTask.__base
    task

  {
    _description: "Tests for UpdateTask: candidate selection/ranking, interactivity gating, the trust/choice prompts, feed-prefix matching, and installed-provider lookup."

    -- UpdateTask.selectCandidate: ranks the pooled candidates by trust band, then version, then a
    -- deterministic tie-break (declared feed, then namespace); returns the winner or nil if none is eligible.

    -- eligibility: release version must meet the target version
    selectCandidate_filtersByVersion: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.0.0"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(2, "0.9.0", namespace: "l0.old"), makeCandidate(2, "1.5.0", namespace: "l0.ok")}
      ut\assertNotNil chosen
      ut\assertEquals chosen.updateRecord.namespace, "l0.ok"

    selectCandidate_noneSatisfiesVersion: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "3.0.0"
      ut\assertNil UpdateTask.selectCandidate task, {makeCandidate(2, "1.0.0"), makeCandidate(2, "2.9.0")}

    -- eligibility: a candidate whose channel can't run on the current platform is skipped
    selectCandidate_skipsUnsupportedPlatform: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(2, "2.0.0", namespace: "l0.win", platform: false), makeCandidate(2, "1.0.0", namespace: "l0.any")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.any"

    -- eligibility: a candidate with no files to install is skipped
    selectCandidate_skipsEmptyFiles: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(2, "2.0.0", namespace: "l0.nofiles", files: {}), makeCandidate(2, "1.0.0", namespace: "l0.ok")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.ok"

    selectCandidate_noneEligible: (ut) ->
      task = makeSelectTask 0
      ut\assertNil UpdateTask.selectCandidate task, {makeCandidate(2, "2.0.0", platform: false)}

    -- a lower (more trusted) band wins even against a higher-version candidate in a higher band
    selectCandidate_lowerBandBeatsHigherVersion: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(4, "9.9.9", namespace: "l0.untrusted"), makeCandidate(1, "1.0.0", namespace: "l0.trusted")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.trusted"
      ut\assertEquals chosen.trustBand, 1

    selectCandidate_highestVersionWithinBand: (ut) ->
      task = makeSelectTask 0
      chosen = UpdateTask.selectCandidate task, {makeCandidate(2, "1.0.0", namespace: "l0.a"), makeCandidate(2, "2.0.0", namespace: "l0.b")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.b"

    -- same band + version: the candidate from the declared feed wins (even with a higher namespace)
    selectCandidate_declaredFeedTiebreak: (ut) ->
      task = makeSelectTask 0, declaredFeed: "feed://declared"
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(2, "2.0.0", namespace: "l0.a", feedUrl: "feed://other"), makeCandidate(2, "2.0.0", namespace: "l0.z", feedUrl: "feed://declared")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.z"

    -- same band + version, neither declared: lexicographically lowest namespace wins; the tie is logged
    selectCandidate_namespaceTiebreakLogged: (ut) ->
      logged = {}
      task = makeSelectTask 0, logged: logged
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(3, "2.0.0", namespace: "l0.b"), makeCandidate(3, "2.0.0", namespace: "l0.a")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.a"
      ut\assertTrue #logged > 0

    selectCandidate_unambiguousNoLog: (ut) ->
      logged = {}
      task = makeSelectTask 0, logged: logged
      chosen = UpdateTask.selectCandidate task, {makeCandidate(1, "1.0.0", namespace: "l0.only")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.only"
      ut\assertEquals #logged, 0

    -- a provider is judged by the alias range it declares, not its own release version: the unrelated
    -- release 9.9.9 is ignored, and ~1.2 still covers the 1.2.4 target
    selectCandidate_providesVersionRangeSatisfies: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.2.4"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(3, "9.9.9", namespace: "l0.prov", isDirect: false, providesVersion: "~1.2")}
      ut\assertNotNil chosen
      ut\assertEquals chosen.updateRecord.namespace, "l0.prov"

    -- conversely, a high release version can't rescue a provider once its declared range no longer reaches the target
    selectCandidate_providesVersionRangeRejects: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.5.0"
      ut\assertNil UpdateTask.selectCandidate task, {makeCandidate(3, "9.9.9", namespace: "l0.prov", isDirect: false, providesVersion: "~1.2")}

    -- a target below the declared range stays satisfiable: the provider can still supply a version >= target
    selectCandidate_providesVersionRangeAboveTarget: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.0.0"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(3, "1.0.0", namespace: "l0.prov", isDirect: false, providesVersion: "~1.2")}
      ut\assertNotNil chosen
      ut\assertEquals chosen.updateRecord.namespace, "l0.prov"

    -- a provider that declares no range stands in for any version
    selectCandidate_providerNoRangeMatchesAny: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "5.0.0"
      chosen = UpdateTask.selectCandidate task, {makeCandidate(3, "1.0.0", namespace: "l0.prov", isDirect: false)}
      ut\assertNotNil chosen
      ut\assertEquals chosen.updateRecord.namespace, "l0.prov"

    -- among providers, the release version doesn't drive rank: the wider declared range (higher covered
    -- version) wins even though its provider has the lower release version
    selectCandidate_providerRankedByRangeMaxNotRelease: (ut) ->
      task = makeSelectTask SemanticVersioning\toNumber "1.0.0"
      chosen = UpdateTask.selectCandidate task,
        {makeCandidate(3, "9.9.9", namespace: "l0.a", isDirect: false, providesVersion: "^1"),
         makeCandidate(3, "1.0.0", namespace: "l0.b", isDirect: false, providesVersion: "^2")}
      ut\assertEquals chosen.updateRecord.namespace, "l0.b"

    -- selectCandidate's 2nd return is the set of candidates tied with the winner (for the chooser)
    selectCandidate_returnsTiedSet: (ut) ->
      task = makeSelectTask 0
      _, tied = UpdateTask.selectCandidate task,
        {makeCandidate(3, "1.0.0", namespace: "l0.a"), makeCandidate(3, "1.0.0", namespace: "l0.b"),
         makeCandidate(3, "1.0.0", namespace: "l0.c", platform: false)}
      ut\assertEquals #tied, 2   -- the platform-ineligible one is excluded

    -- UpdateTask.shouldPrompt: a task may prompt only when its reason is permitted by the given threshold

    shouldPrompt_withinThreshold: (ut) ->
      ut\assertTrue UpdateTask.shouldPrompt makeInteractiveTask({reason: UpdateReason.DependencyResolution}), PromptThreshold.DependencyResolution
      ut\assertTrue UpdateTask.shouldPrompt makeInteractiveTask({reason: UpdateReason.UserRequested}), PromptThreshold.AutoUpdates

    shouldPrompt_aboveThreshold: (ut) ->
      ut\assertFalse UpdateTask.shouldPrompt makeInteractiveTask({reason: UpdateReason.AutoUpdate}), PromptThreshold.UserRequested

    shouldPrompt_noReason: (ut) ->
      ut\assertFalse UpdateTask.shouldPrompt makeInteractiveTask({reason: nil}), PromptThreshold.AutoUpdates

    -- UpdateTask.promptTrustFeed: shows the dialog (callers gate it); "always" trusts the feed, "never"
    -- blocks it, and a cancelled prompt returns nil.

    promptTrustFeed_trustOnce: (ut) ->
      task = makeInteractiveTask!
      ut\stub(aegisub.dialog, "display")\calls -> msgs.promptTrustFeed.trustOnce
      ut\assertEquals UpdateTask.promptTrustFeed(task, {feedUrl: "feed://x"}), FeedTrustDecision.Once

    promptTrustFeed_cancelReturnsNil: (ut) ->
      task = makeInteractiveTask!
      ut\stub(aegisub.dialog, "display")\calls -> msgs.dialogCommon.cancel
      ut\assertNil UpdateTask.promptTrustFeed(task, {feedUrl: "feed://x"})

    promptTrustFeed_trustAlwaysPersists: (ut) ->
      saved = {}
      task = makeInteractiveTask trustedFeeds: {}, onSave: -> saved[1] = true
      ut\stub(aegisub.dialog, "display")\calls -> msgs.promptTrustFeed.trustAlways
      ut\assertEquals UpdateTask.promptTrustFeed(task, {feedUrl: "feed://new"}), FeedTrustDecision.Always
      ut\assertEquals task.updater.config.c.trustedFeeds[1], "feed://new"
      ut\assertTrue saved[1]

    promptTrustFeed_neverBlocks: (ut) ->
      saved = {}
      task = makeInteractiveTask blockedFeeds: {}, onSave: -> saved[1] = true
      ut\stub(aegisub.dialog, "display")\calls -> msgs.promptTrustFeed.trustNever
      ut\assertEquals UpdateTask.promptTrustFeed(task, {feedUrl: "feed://bad"}), FeedTrustDecision.Never
      ut\assertEquals task.updater.config.c.blockedFeeds[1], "feed://bad"
      ut\assertTrue saved[1]

    -- UpdateTask.promptSelectPackageSource: shows the dialog (callers gate it), returning the picked
    -- candidate and the chosen stickiness; an "auto" pick keeps the winner and an "abort" returns nil.

    promptSelectPackageSource_picksSelection: (ut) ->
      task = makeInteractiveTask!
      winner = {feedUrl: "feed://a", updateRecord: {namespace: "l0.a", name: "A"}}
      other  = {feedUrl: "feed://b", updateRecord: {namespace: "l0.b", name: "B"}}
      ut\stub(aegisub.dialog, "display")\calls -> msgs.promptSelectSource.retain, {choice: "B (feed://b)"}
      chosen, stickiness = UpdateTask.promptSelectPackageSource task, {winner, other}, winner
      ut\assertEquals chosen, other
      ut\assertEquals stickiness, SourceChoiceStickiness.Retain

    promptSelectPackageSource_autoKeepsWinner: (ut) ->
      task = makeInteractiveTask!
      winner = {feedUrl: "feed://a", updateRecord: {namespace: "l0.a", name: "A"}}
      other  = {feedUrl: "feed://b", updateRecord: {namespace: "l0.b", name: "B"}}
      -- "Let DepCtrl Decide" ignores the dropdown and keeps the algorithm's pick
      ut\stub(aegisub.dialog, "display")\calls -> msgs.promptSelectSource.auto, {choice: "B (feed://b)"}
      chosen, stickiness = UpdateTask.promptSelectPackageSource task, {winner, other}, winner
      ut\assertEquals chosen, winner
      ut\assertEquals stickiness, SourceChoiceStickiness.Auto

    promptSelectPackageSource_abortReturnsNil: (ut) ->
      task = makeInteractiveTask!
      winner = {feedUrl: "feed://a", updateRecord: {namespace: "l0.a", name: "A"}}
      other  = {feedUrl: "feed://b", updateRecord: {namespace: "l0.b", name: "B"}}
      ut\stub(aegisub.dialog, "display")\calls -> msgs.promptSelectSource.abort, {}
      ut\assertNil UpdateTask.promptSelectPackageSource task, {winner, other}, winner

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

    -- UpdateTask.resolveRememberedFeedUrl: derives the feed URL of a remembered source for every kind
    -- but `other` (which stores it), so a remembered choice survives a feed-URL migration.

    resolveRememberedFeedUrl_selfDeclared: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      ut\assertEquals UpdateTask.resolveRememberedFeedUrl(task, {feedSource: SourceFeedKind.SelfDeclared}), "feed://declared"

    resolveRememberedFeedUrl_userFeed: (ut) ->
      task = makeSourceTask userFeed: "feed://user"
      ut\assertEquals UpdateTask.resolveRememberedFeedUrl(task, {feedSource: SourceFeedKind.UserFeed}), "feed://user"

    resolveRememberedFeedUrl_other: (ut) ->
      task = makeSourceTask!
      ut\assertEquals UpdateTask.resolveRememberedFeedUrl(task, {feedSource: SourceFeedKind.Other, feedUrl: "feed://third"}), "feed://third"

    resolveRememberedFeedUrl_provider: (ut) ->
      task = makeSourceTask modules: {"l0.prov": {feed: "feed://prov"}}
      ut\assertEquals UpdateTask.resolveRememberedFeedUrl(task, {feedSource: SourceFeedKind.Provider, provider: {namespace: "l0.prov"}}), "feed://prov"

    resolveRememberedFeedUrl_providerMissing: (ut) ->
      task = makeSourceTask modules: {}
      ut\assertNil UpdateTask.resolveRememberedFeedUrl task, {feedSource: SourceFeedKind.Provider, provider: {namespace: "l0.gone"}}

    -- UpdateTask.matchRememberedCandidate: finds the pooled candidate corresponding to the remembered
    -- source, but only when it's still eligible to satisfy the task.

    matchRememberedCandidate_direct: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      candidates = {
        makeCandidate(2, "1.0.0", feedUrl: "feed://other", namespace: "l0.x")
        makeCandidate(1, "1.0.0", feedUrl: "feed://declared", namespace: "l0.x")
      }
      m = UpdateTask.matchRememberedCandidate task, candidates, {feedSource: SourceFeedKind.SelfDeclared}
      ut\assertNotNil m
      ut\assertEquals m.feedUrl, "feed://declared"

    matchRememberedCandidate_provider: (ut) ->
      task = makeSourceTask modules: {"l0.prov": {feed: "feed://prov"}}
      candidates = {makeCandidate(3, "0.1.0", feedUrl: "feed://prov", isDirect: false, namespace: "l0.prov", providesVersion: "*")}
      m = UpdateTask.matchRememberedCandidate task, candidates, {feedSource: SourceFeedKind.Provider, provider: {namespace: "l0.prov"}}
      ut\assertNotNil m
      ut\assertFalse m.isDirect

    matchRememberedCandidate_ineligibleVersion: (ut) ->
      task = makeSourceTask feed: "feed://declared", targetVersion: SemanticVersioning\toNumber "5.0.0"
      candidates = {makeCandidate(1, "1.0.0", feedUrl: "feed://declared")}
      ut\assertNil UpdateTask.matchRememberedCandidate task, candidates, {feedSource: SourceFeedKind.SelfDeclared}

    matchRememberedCandidate_noUrlMatch: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      candidates = {makeCandidate(1, "1.0.0", feedUrl: "feed://elsewhere")}
      ut\assertNil UpdateTask.matchRememberedCandidate task, candidates, {feedSource: SourceFeedKind.SelfDeclared}

    -- UpdateTask.feedSourceOf: classifies a chosen candidate's source kind for persistence.

    feedSourceOf_provider: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      ut\assertEquals UpdateTask.feedSourceOf(task, {isDirect: false, feedUrl: "feed://prov"}), SourceFeedKind.Provider

    feedSourceOf_selfDeclared: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      ut\assertEquals UpdateTask.feedSourceOf(task, {isDirect: true, feedUrl: "feed://declared"}), SourceFeedKind.SelfDeclared

    feedSourceOf_userFeed: (ut) ->
      task = makeSourceTask feed: "feed://declared", userFeed: "feed://user"
      ut\assertEquals UpdateTask.feedSourceOf(task, {isDirect: true, feedUrl: "feed://user"}), SourceFeedKind.UserFeed

    feedSourceOf_other: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      ut\assertEquals UpdateTask.feedSourceOf(task, {isDirect: true, feedUrl: "feed://third"}), SourceFeedKind.Other

    -- UpdateTask.persistSource: records the resolved source and stickiness, writing only when changed.

    persistSource_writesDirect: (ut) ->
      saved = {}
      task = makeSourceTask feed: "feed://declared", onSave: -> saved[1] = true
      selected = {isDirect: true, feedUrl: "feed://declared", updateRecord: {namespace: "l0.x", activeChannel: "main"}}
      UpdateTask.persistSource task, selected, SourceChoiceStickiness.Retain
      cs = task.record.config.c.currentSource
      ut\assertNotNil cs
      ut\assertEquals cs.feedSource, SourceFeedKind.SelfDeclared
      ut\assertEquals cs.stickiness, SourceChoiceStickiness.Retain
      ut\assertEquals cs.channel, "main"
      ut\assertTrue saved[1]

    persistSource_recordsProvider: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      selected = {isDirect: false, feedUrl: "feed://prov", providesVersion: "~1.2", updateRecord: {namespace: "l0.prov", activeChannel: "main"}}
      UpdateTask.persistSource task, selected, SourceChoiceStickiness.Pinned
      cs = task.record.config.c.currentSource
      ut\assertEquals cs.feedSource, SourceFeedKind.Provider
      ut\assertEquals cs.provider.namespace, "l0.prov"
      ut\assertEquals cs.provider.version, "~1.2"

    persistSource_storesFeedUrlForOther: (ut) ->
      task = makeSourceTask feed: "feed://declared"
      selected = {isDirect: true, feedUrl: "feed://third", updateRecord: {namespace: "l0.x", activeChannel: "main"}}
      UpdateTask.persistSource task, selected, SourceChoiceStickiness.Once
      ut\assertEquals task.record.config.c.currentSource.feedUrl, "feed://third"

    persistSource_skipsUnchanged: (ut) ->
      saves = {n: 0}
      existing = {feedSource: SourceFeedKind.SelfDeclared, channel: "main", stickiness: SourceChoiceStickiness.Retain}
      task = makeSourceTask feed: "feed://declared", currentSource: existing, onSave: -> saves.n += 1
      selected = {isDirect: true, feedUrl: "feed://declared", updateRecord: {namespace: "l0.x", activeChannel: "main"}}
      UpdateTask.persistSource task, selected, SourceChoiceStickiness.Retain
      ut\assertEquals saves.n, 0

    -- UpdateTask.getTrustedFeeds: merges the officially trusted feeds with the user's extraFeeds and trustedFeeds.

    getTrustedFeeds_mergesOfficialAndUser: (ut) ->
      task = makeTrustTask officialTrusted: {"feed://official": true}, extraFeeds: {"feed://extra"}, trustedFeeds: {"feed://trusted"}
      trusted = UpdateTask.getTrustedFeeds task
      ut\assertTrue trusted["feed://official"]
      ut\assertTrue trusted["feed://extra"]
      ut\assertTrue trusted["feed://trusted"]

    getTrustedFeeds_officialOnlyWhenNoUserFeeds: (ut) ->
      task = makeTrustTask officialTrusted: {"feed://official": true}
      trusted = UpdateTask.getTrustedFeeds task
      ut\assertTrue trusted["feed://official"]
      ut\assertNil trusted["feed://extra"]

    -- UpdateTask.getBlockedFeeds: official block list first, then the user's blockedFeeds appended.

    getBlockedFeeds_mergesOfficialThenUser: (ut) ->
      task = makeTrustTask officialBlocked: {"https://bad.example/"}, blockedFeeds: {"https://evil.example/"}
      blocked = UpdateTask.getBlockedFeeds task
      ut\assertEquals #blocked, 2
      ut\assertEquals blocked[1], "https://bad.example/"
      ut\assertEquals blocked[2], "https://evil.example/"

    getBlockedFeeds_officialOnlyWhenNoUserFeeds: (ut) ->
      task = makeTrustTask officialBlocked: {"https://bad.example/"}
      blocked = UpdateTask.getBlockedFeeds task
      ut\assertEquals #blocked, 1
      ut\assertEquals blocked[1], "https://bad.example/"

    -- UpdateTask.resolve: walks the lazy trust-ranked feed cascade and the currentSource stickiness tree,
    -- running prompts inline, and returns either a candidate to install or a terminal status code. It
    -- performs no installs, so it's tested directly with feed I/O and prompts stubbed (see makeResolveTask).

    -- cascade: a DeclaredDirect (band 1) winner short-circuits the rest of the cascade — the trusted tier
    -- is never even fetched (a higher-version candidate there is irrelevant).
    resolve_cascadeShortCircuitsOnDeclaredDirect: (ut) ->
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://decl": true}
        config: {extraFeeds: {"feed://extra"}}
        feeds: {"feed://decl": {direct: directRec version: "1.0.0"}, "feed://extra": {direct: directRec version: "9.9.9"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource.feedUrl, "feed://decl"
      ut\assertNil task.triedFeeds["feed://extra"]   -- tier 2 was never reached

    -- cascade: an empty declared feed falls through to a trusted feed (TrustedDirect, band 2)
    resolve_fallsThroughToTrustedDirect: (ut) ->
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://trusted": true}
        feeds: {"feed://decl": {}, "feed://trusted": {direct: directRec version: "2.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource.feedUrl, "feed://trusted"
      ut\assertEquals d.selectedSource.trustBand, 2

    -- trust gate: a required dependency whose only source is an untrusted feed (band 4) fails with -16
    -- when no prompt is permitted
    resolve_untrustedRequiredFailsWithoutPrompt: (ut) ->
      task = makeResolveTask {
        declaredFeed: "feed://decl", addFeeds: {"feed://un"}
        feeds: {"feed://decl": {}, "feed://un": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, -16

    -- trust gate: the same untrusted winner proceeds once the user approves it (Trust this time)
    resolve_untrustedApprovedProceeds: (ut) ->
      task = makeResolveTask {
        declaredFeed: "feed://decl", addFeeds: {"feed://un"}, allowPrompt: true, trustReturn: FeedTrustDecision.Once
        feeds: {"feed://decl": {}, "feed://un": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource.feedUrl, "feed://un"
      ut\assertEquals task.calls.trust, 1

    -- trust gate: an optional dependency from an untrusted feed is skipped (3) rather than failed
    resolve_untrustedOptionalSkips: (ut) ->
      task = makeResolveTask {
        declaredFeed: "feed://decl", addFeeds: {"feed://un"}, optional: true
        feeds: {"feed://decl": {}, "feed://un": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, 3

    -- no candidate: a required install with no source anywhere fails with -6
    resolve_noCandidateRequiredFails: (ut) ->
      task = makeResolveTask {declaredFeed: "feed://decl", feeds: {"feed://decl": {}}}
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, -6

    -- no candidate: an optional install with no source is skipped (3)
    resolve_noCandidateOptionalSkips: (ut) ->
      task = makeResolveTask {declaredFeed: "feed://decl", optional: true, feeds: {"feed://decl": {}}}
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, 3

    -- pinned: the remembered source is reused directly and the pin is preserved, no prompt
    resolve_pinnedReuseProceeds: (ut) ->
      cs = {feedSource: SourceFeedKind.SelfDeclared, channel: "release", stickiness: SourceChoiceStickiness.Pinned}
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://decl": true}, currentSource: cs
        feeds: {"feed://decl": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource.feedUrl, "feed://decl"
      ut\assertEquals d.stickiness, SourceChoiceStickiness.Pinned
      ut\assertEquals task.calls.select, 0

    -- pinned: a required dependency whose pinned source has vanished aborts with -17 (no silent switch)
    resolve_pinnedMissingRequiredAborts: (ut) ->
      cs = {feedSource: SourceFeedKind.SelfDeclared, channel: "release", stickiness: SourceChoiceStickiness.Pinned}
      task = makeResolveTask {declaredFeed: "feed://decl", currentSource: cs, feeds: {"feed://decl": {}}}
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, -17

    -- pinned: the same vanished pin only skips (3) for an optional dependency
    resolve_pinnedMissingOptionalSkips: (ut) ->
      cs = {feedSource: SourceFeedKind.SelfDeclared, channel: "release", stickiness: SourceChoiceStickiness.Pinned}
      task = makeResolveTask {declaredFeed: "feed://decl", optional: true, currentSource: cs, feeds: {"feed://decl": {}}}
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, 3

    -- retain: a still-eligible remembered source is reused without prompting
    resolve_retainReuseProceeds: (ut) ->
      cs = {feedSource: SourceFeedKind.SelfDeclared, channel: "release", stickiness: SourceChoiceStickiness.Retain}
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://decl": true}, currentSource: cs
        feeds: {"feed://decl": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource.feedUrl, "feed://decl"
      ut\assertEquals task.calls.select, 0

    -- retain (soft): when the remembered pick is gone and the run is non-interactive, fall back to the
    -- cascade's pick and downgrade the stickiness to Once
    resolve_retainMissingNonInteractiveDowngrades: (ut) ->
      cs = {feedSource: SourceFeedKind.Other, feedUrl: "feed://gone", channel: "release", stickiness: SourceChoiceStickiness.Retain}
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://decl": true}, currentSource: cs
        feeds: {"feed://decl": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource.feedUrl, "feed://decl"
      ut\assertEquals d.stickiness, SourceChoiceStickiness.Once
      ut\assertEquals task.calls.select, 0

    -- retain (soft): when the remembered pick is gone and the run is interactive, re-prompt and take the
    -- user's pick and stickiness
    resolve_retainMissingInteractivePicks: (ut) ->
      cs = {feedSource: SourceFeedKind.Other, feedUrl: "feed://gone", channel: "release", stickiness: SourceChoiceStickiness.Retain}
      pick = {feedUrl: "feed://decl", trustBand: 1, isDirect: true, updateRecord: {namespace: "json", version: "1.0.0"}}
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://decl": true}, currentSource: cs
        allowPrompt: true, selectReturn: {pick, SourceChoiceStickiness.Retain}
        feeds: {"feed://decl": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource, pick
      ut\assertEquals d.stickiness, SourceChoiceStickiness.Retain
      ut\assertEquals task.calls.select, 1

    -- the chooser aborts the update: a required dependency fails with -18
    resolve_choiceAbortRequiredFails: (ut) ->
      cs = {feedSource: SourceFeedKind.Other, feedUrl: "feed://gone", channel: "release", stickiness: SourceChoiceStickiness.Retain}
      task = makeResolveTask {
        declaredFeed: "feed://decl", officialTrusted: {"feed://decl": true}, currentSource: cs
        allowPrompt: true, selectReturn: {}
        feeds: {"feed://decl": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertFalse d.installRequired
      ut\assertEquals d.statusCode, -18

    -- auto: never prompts even when several equally-ranked candidates tie; takes the algorithm's pick
    resolve_autoNeverPrompts: (ut) ->
      cs = {feedSource: SourceFeedKind.SelfDeclared, channel: "release", stickiness: SourceChoiceStickiness.Auto}
      task = makeResolveTask {
        currentSource: cs, allowPrompt: true, officialTrusted: {"feed://a": true, "feed://b": true}
        feeds: {"feed://a": {direct: directRec version: "1.0.0"}, "feed://b": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals task.calls.select, 0

    -- offer-all-sources: with the global toggle on, the chooser fires whenever ≥2 candidates are eligible
    resolve_offerAllSourcesPromptsOnMultiple: (ut) ->
      pick = {feedUrl: "feed://b", trustBand: 2, isDirect: true, updateRecord: {namespace: "json", version: "1.0.0"}}
      task = makeResolveTask {
        allowPrompt: true, config: {offerAllSources: true}
        officialTrusted: {"feed://a": true, "feed://b": true}, selectReturn: {pick, SourceChoiceStickiness.Once}
        feeds: {"feed://a": {direct: directRec version: "1.0.0"}, "feed://b": {direct: directRec version: "1.0.0"}}
      }
      d = UpdateTask.resolve task
      ut\assertTrue d.installRequired
      ut\assertEquals d.selectedSource, pick
      ut\assertEquals task.calls.select, 1

    _order: {
      "selectCandidate_filtersByVersion", "selectCandidate_noneSatisfiesVersion",
      "selectCandidate_skipsUnsupportedPlatform", "selectCandidate_skipsEmptyFiles", "selectCandidate_noneEligible",
      "selectCandidate_lowerBandBeatsHigherVersion", "selectCandidate_highestVersionWithinBand",
      "selectCandidate_declaredFeedTiebreak", "selectCandidate_namespaceTiebreakLogged", "selectCandidate_unambiguousNoLog",
      "selectCandidate_providesVersionRangeSatisfies", "selectCandidate_providesVersionRangeRejects",
      "selectCandidate_providesVersionRangeAboveTarget", "selectCandidate_providerNoRangeMatchesAny",
      "selectCandidate_providerRankedByRangeMaxNotRelease", "selectCandidate_returnsTiedSet",
      "shouldPrompt_withinThreshold", "shouldPrompt_aboveThreshold", "shouldPrompt_noReason",
      "promptTrustFeed_trustOnce", "promptTrustFeed_cancelReturnsNil", "promptTrustFeed_trustAlwaysPersists",
      "promptTrustFeed_neverBlocks",
      "promptSelectPackageSource_picksSelection", "promptSelectPackageSource_autoKeepsWinner",
      "promptSelectPackageSource_abortReturnsNil",
      "feedMatchesPrefix_exactAndCaseInsensitive", "feedMatchesPrefix_hostPrefixBlocksEverythingUnder",
      "feedMatchesPrefix_noMatch", "feedMatchesPrefix_guards",
      "resolveRememberedFeedUrl_selfDeclared", "resolveRememberedFeedUrl_userFeed", "resolveRememberedFeedUrl_other",
      "resolveRememberedFeedUrl_provider", "resolveRememberedFeedUrl_providerMissing",
      "matchRememberedCandidate_direct", "matchRememberedCandidate_provider",
      "matchRememberedCandidate_ineligibleVersion", "matchRememberedCandidate_noUrlMatch",
      "feedSourceOf_provider", "feedSourceOf_selfDeclared", "feedSourceOf_userFeed", "feedSourceOf_other",
      "persistSource_writesDirect", "persistSource_recordsProvider", "persistSource_storesFeedUrlForOther",
      "persistSource_skipsUnchanged",
      "getTrustedFeeds_mergesOfficialAndUser", "getTrustedFeeds_officialOnlyWhenNoUserFeeds",
      "getBlockedFeeds_mergesOfficialThenUser", "getBlockedFeeds_officialOnlyWhenNoUserFeeds",
      "resolve_cascadeShortCircuitsOnDeclaredDirect", "resolve_fallsThroughToTrustedDirect",
      "resolve_untrustedRequiredFailsWithoutPrompt", "resolve_untrustedApprovedProceeds",
      "resolve_untrustedOptionalSkips", "resolve_noCandidateRequiredFails", "resolve_noCandidateOptionalSkips",
      "resolve_pinnedReuseProceeds", "resolve_pinnedMissingRequiredAborts", "resolve_pinnedMissingOptionalSkips",
      "resolve_retainReuseProceeds", "resolve_retainMissingNonInteractiveDowngrades",
      "resolve_retainMissingInteractivePicks", "resolve_choiceAbortRequiredFails",
      "resolve_autoNeverPrompts", "resolve_offerAllSourcesPromptsOnMultiple"
    }
  }
