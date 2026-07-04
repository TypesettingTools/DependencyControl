-- FeedTrust tests: the consolidated feed-trust model — official/user merge, trust queries, and mutations.
-- Called from test.moon as: (controls\requireTest "FeedTrust")!
() ->
  FeedTrust = require "l0.DependencyControl.FeedTrust"

  -- A FeedTrust seeded with the official sets (so it never loads the live DepCtrl feed) over a stub config.
  -- opts: officialTrusted (set), officialBlocked (list), extraFeeds, trustedFeeds, blockedFeeds, onSave.
  make = (opts = {}) ->
    setmetatable {
      config: {
        c: {extraFeeds: opts.extraFeeds, trustedFeeds: opts.trustedFeeds, blockedFeeds: opts.blockedFeeds}
        save: (=> opts.onSave! if opts.onSave)
      }
      __official: {trusted: opts.officialTrusted or {}, blocked: opts.officialBlocked or {}}
      logger: {log: ->}
    }, __index: FeedTrust.__base

  {
    _description: "FeedTrust: official/user trust merge, trust queries, and config mutations."

    -- getOfficial* short-circuit when the official cache is present (loadOfficial returns it without
    -- rebuilding): assertIs proves the same table comes back.
    getOfficialTrustedFeeds_usesCacheWhenPresent: (ut) ->
      cached = {trusted: {"feed://a": true}, blocked: {}}
      ft = setmetatable {__official: cached}, __index: FeedTrust.__base
      ut\assertTrue FeedTrust.getOfficialTrustedFeeds(ft)["feed://a"]
      ut\assertIs ft.__official, cached

    getOfficialBlockedFeeds_usesCacheWhenPresent: (ut) ->
      cached = {trusted: {}, blocked: {{url: "https://bad.example/"}}}
      ft = setmetatable {__official: cached}, __index: FeedTrust.__base
      ut\assertEquals FeedTrust.getOfficialBlockedFeeds(ft), {{url: "https://bad.example/"}}
      ut\assertIs ft.__official, cached

    -- getTrustedFeeds merges the official trusted set with the user's extraFeeds and trustedFeeds.
    getTrustedFeeds_mergesOfficialAndUser: (ut) ->
      ft = make officialTrusted: {"feed://official": true}, extraFeeds: {"feed://extra"}, trustedFeeds: {"feed://trusted"}
      trusted = FeedTrust.getTrustedFeeds ft
      ut\assertTrue trusted["feed://official"]
      ut\assertTrue trusted["feed://extra"]
      ut\assertTrue trusted["feed://trusted"]

    getTrustedFeeds_officialOnlyWhenNoUserFeeds: (ut) ->
      ft = make officialTrusted: {"feed://official": true}
      trusted = FeedTrust.getTrustedFeeds ft
      ut\assertTrue trusted["feed://official"]
      ut\assertNil trusted["feed://extra"]

    -- getBlockedFeeds: official entries first (tagged official), then the user's, each normalized to an object.
    getBlockedFeeds_mergesOfficialThenUser: (ut) ->
      ft = make officialBlocked: {{url: "https://bad.example/"}}, blockedFeeds: {{url: "https://evil.example/"}}
      blocked = FeedTrust.getBlockedFeeds ft
      ut\assertEquals #blocked, 2
      ut\assertEquals blocked[1].url, "https://bad.example/"
      ut\assertTrue blocked[1].isOfficial
      ut\assertEquals blocked[2].url, "https://evil.example/"
      ut\assertFalse blocked[2].isOfficial

    getBlockedFeeds_officialOnlyWhenNoUserFeeds: (ut) ->
      ft = make officialBlocked: {{url: "https://bad.example/"}}
      blocked = FeedTrust.getBlockedFeeds ft
      ut\assertEquals #blocked, 1
      ut\assertEquals blocked[1].url, "https://bad.example/"
      ut\assertEquals blocked[1].matchMode, "prefix"

    -- isTrusted checks the merged set (exact match), guarding nil; isBlocked uses prefix matching.
    isTrusted_checksMergedSet: (ut) ->
      ft = make officialTrusted: {"feed://o": true}, trustedFeeds: {"feed://t"}
      ut\assertTrue FeedTrust.isTrusted ft, "feed://o"
      ut\assertTrue FeedTrust.isTrusted ft, "feed://t"
      ut\assertFalse FeedTrust.isTrusted ft, "feed://x"
      ut\assertFalse FeedTrust.isTrusted ft, nil

    isBlocked_prefixMatch: (ut) ->
      ft = make officialBlocked: {{url: "https://bad.example/"}}
      ut\assertTrue FeedTrust.isBlocked ft, "https://bad.example/a/b.json"
      ut\assertFalse FeedTrust.isBlocked ft, "https://ok.example/"

    -- trust/block append to the user config, persist, and invalidate the cached merged set so the new
    -- feed is immediately reflected.
    trust_appendsPersistsAndInvalidates: (ut) ->
      saved = {}
      ft = make trustedFeeds: {}, onSave: -> saved[1] = true
      FeedTrust.getTrustedFeeds ft   -- prime the cache
      FeedTrust.trust ft, "feed://new"
      ut\assertEquals ft.config.c.trustedFeeds[1], "feed://new"
      ut\assertTrue saved[1]
      ut\assertTrue FeedTrust.isTrusted ft, "feed://new"

    block_appendsPersistsAndInvalidates: (ut) ->
      saved = {}
      ft = make blockedFeeds: {}, onSave: -> saved[1] = true
      FeedTrust.getBlockedFeeds ft   -- prime the cache
      FeedTrust.block ft, "https://bad/"
      ut\assertEquals ft.config.c.blockedFeeds[1], {url: "https://bad/", matchMode: "prefix"}
      ut\assertTrue saved[1]
      ut\assertTrue FeedTrust.isBlocked ft, "https://bad/x"

    -- trust/block/addExtraFeed ignore an exact duplicate: no second entry, no save, return false.
    trust_ignoresDuplicate: (ut) ->
      saved = {}
      ft = make trustedFeeds: {"feed://a"}, onSave: -> saved[1] = true
      ut\assertFalse FeedTrust.trust ft, "feed://a"
      ut\assertEquals ft.config.c.trustedFeeds, {"feed://a"}
      ut\assertNil saved[1]

    block_ignoresDuplicate: (ut) ->
      saved = {}
      ft = make blockedFeeds: {{url: "https://bad/", matchMode: "prefix"}}, onSave: -> saved[1] = true
      ut\assertFalse FeedTrust.block ft, "https://bad/"
      ut\assertEquals ft.config.c.blockedFeeds, {{url: "https://bad/", matchMode: "prefix"}}
      ut\assertNil saved[1]

    -- untrust removes only the user's trustedFeeds entry, persists, and invalidates the cached set.
    untrust_removesPersistsAndInvalidates: (ut) ->
      saved = {}
      ft = make trustedFeeds: {"feed://a", "feed://b"}, onSave: -> saved[1] = true
      FeedTrust.getTrustedFeeds ft   -- prime the cache
      ut\assertTrue FeedTrust.untrust ft, "feed://a"
      ut\assertEquals ft.config.c.trustedFeeds, {"feed://b"}
      ut\assertTrue saved[1]
      ut\assertFalse FeedTrust.isTrusted ft, "feed://a"

    untrust_returnsFalseWhenAbsent: (ut) ->
      saved = {}
      ft = make trustedFeeds: {"feed://a"}, onSave: -> saved[1] = true
      ut\assertFalse FeedTrust.untrust ft, "feed://missing"
      ut\assertNil saved[1]
      ut\assertEquals ft.config.c.trustedFeeds, {"feed://a"}

    -- untrust can't remove a feed trusted only through the official set (block it to override).
    untrust_leavesOfficialTrusted: (ut) ->
      ft = make officialTrusted: {"feed://o": true}, trustedFeeds: {}
      ut\assertFalse FeedTrust.untrust ft, "feed://o"
      ut\assertTrue FeedTrust.isTrusted ft, "feed://o"

    unblock_removesPersistsAndInvalidates: (ut) ->
      saved = {}
      ft = make blockedFeeds: {{url: "https://bad/", matchMode: "prefix"}, {url: "https://evil/", matchMode: "prefix"}}, onSave: -> saved[1] = true
      FeedTrust.getBlockedFeeds ft   -- prime the cache
      ut\assertTrue FeedTrust.unblock ft, "https://bad/"
      ut\assertEquals ft.config.c.blockedFeeds, {{url: "https://evil/", matchMode: "prefix"}}
      ut\assertTrue saved[1]
      ut\assertFalse FeedTrust.isBlocked ft, "https://bad/x"

    unblock_leavesOfficialBlocked: (ut) ->
      ft = make officialBlocked: {{url: "https://bad/"}}, blockedFeeds: {}
      ut\assertFalse FeedTrust.unblock ft, "https://bad/"
      ut\assertTrue FeedTrust.isBlocked ft, "https://bad/x"

    -- addExtraFeed adds a trusted discovery root, persists, and invalidates the merged trusted set.
    addExtraFeed_addsPersistsAndInvalidates: (ut) ->
      saved = {}
      ft = make extraFeeds: {}, onSave: -> saved[1] = true
      FeedTrust.getTrustedFeeds ft   -- prime the cache
      ut\assertTrue FeedTrust.addExtraFeed ft, "feed://extra"
      ut\assertEquals ft.config.c.extraFeeds, {"feed://extra"}
      ut\assertTrue saved[1]
      ut\assertTrue FeedTrust.isTrusted ft, "feed://extra"

    removeExtraFeed_removesAndInvalidates: (ut) ->
      ft = make extraFeeds: {"feed://x"}
      FeedTrust.getTrustedFeeds ft   -- prime the cache
      ut\assertTrue FeedTrust.removeExtraFeed ft, "feed://x"
      ut\assertEquals ft.config.c.extraFeeds, {}
      ut\assertFalse FeedTrust.isTrusted ft, "feed://x"

    -- an exact block matches only the exact URL (case-insensitively), not sub-paths.
    block_exactMatchModeMatchesExactUrlOnly: (ut) ->
      ft = make blockedFeeds: {}
      FeedTrust.block ft, "https://x.example/feed.json", {matchMode: "exact", reason: "typosquat"}
      ut\assertTrue FeedTrust.isBlocked ft, "https://X.example/Feed.json"
      ut\assertFalse FeedTrust.isBlocked ft, "https://x.example/feed.json/pkg"

    -- every block is stored as a `{url, matchMode, reason?}` object (blocks have no bare-string form).
    block_alwaysStoresObject: (ut) ->
      ft = make blockedFeeds: {}
      FeedTrust.block ft, "https://a/", {reason: "bad"}
      FeedTrust.block ft, "https://b/"
      ut\assertEquals ft.config.c.blockedFeeds[1], {url: "https://a/", matchMode: "prefix", reason: "bad"}
      ut\assertEquals ft.config.c.blockedFeeds[2], {url: "https://b/", matchMode: "prefix"}

    -- block dedups by url + match mode: the same prefix is ignored, but the same url at a different mode is allowed.
    block_dedupsByUrlAndMatchMode: (ut) ->
      saved = {}
      ft = make blockedFeeds: {{url: "https://d/", matchMode: "prefix"}}, onSave: -> saved[1] = true
      ut\assertFalse FeedTrust.block ft, "https://d/"
      ut\assertNil saved[1]
      ut\assertTrue FeedTrust.block ft, "https://d/", {matchMode: "exact"}

    -- getBlockingEntry surfaces the matching entry's reason and marks official blocks.
    getBlockingEntry_surfacesReasonAndOfficial: (ut) ->
      ft = make officialBlocked: {{url: "https://bad/", reason: "malware"}}
      entry = FeedTrust.getBlockingEntry ft, "https://bad/pkg.json"
      ut\assertEquals entry.reason, "malware"
      ut\assertEquals entry.matchMode, "prefix"
      ut\assertTrue entry.isOfficial
      ut\assertNil FeedTrust.getBlockingEntry ft, "https://ok/"

    -- urlMatchesPrefix: case-insensitive, prefix-based block-list matching (the evasion-resistant primitive).
    urlMatchesPrefix_exactAndCaseInsensitive: (ut) ->
      ut\assertTrue FeedTrust\urlMatchesPrefix "https://example.com/feed.json", {"https://example.com/feed.json"}
      ut\assertTrue FeedTrust\urlMatchesPrefix "https://Example.COM/Feed.json", {"https://example.com/feed.json"}

    urlMatchesPrefix_hostPrefixBlocksEverythingUnder: (ut) ->
      ut\assertTrue FeedTrust\urlMatchesPrefix "https://example.com/a/b.json", {"https://example.com/"}

    urlMatchesPrefix_noMatch: (ut) ->
      ut\assertFalse FeedTrust\urlMatchesPrefix "https://other.com/feed.json", {"https://example.com/"}

    -- guards: nil url, no entries, and an empty entry (which must not match everything)
    urlMatchesPrefix_guards: (ut) ->
      ut\assertFalse FeedTrust\urlMatchesPrefix nil, {"https://example.com/"}
      ut\assertFalse FeedTrust\urlMatchesPrefix "https://example.com/x", {}
      ut\assertFalse FeedTrust\urlMatchesPrefix "https://example.com/x", {""}

    _order: {
      "getOfficialTrustedFeeds_usesCacheWhenPresent", "getOfficialBlockedFeeds_usesCacheWhenPresent"
      "getTrustedFeeds_mergesOfficialAndUser", "getTrustedFeeds_officialOnlyWhenNoUserFeeds"
      "getBlockedFeeds_mergesOfficialThenUser", "getBlockedFeeds_officialOnlyWhenNoUserFeeds"
      "isTrusted_checksMergedSet", "isBlocked_prefixMatch"
      "trust_appendsPersistsAndInvalidates", "block_appendsPersistsAndInvalidates"
      "trust_ignoresDuplicate", "block_ignoresDuplicate"
      "untrust_removesPersistsAndInvalidates", "untrust_returnsFalseWhenAbsent", "untrust_leavesOfficialTrusted"
      "unblock_removesPersistsAndInvalidates", "unblock_leavesOfficialBlocked"
      "addExtraFeed_addsPersistsAndInvalidates", "removeExtraFeed_removesAndInvalidates"
      "block_exactMatchModeMatchesExactUrlOnly", "block_alwaysStoresObject"
      "block_dedupsByUrlAndMatchMode", "getBlockingEntry_surfacesReasonAndOfficial"
      "urlMatchesPrefix_exactAndCaseInsensitive", "urlMatchesPrefix_hostPrefixBlocksEverythingUnder"
      "urlMatchesPrefix_noMatch", "urlMatchesPrefix_guards"
    }
  }
