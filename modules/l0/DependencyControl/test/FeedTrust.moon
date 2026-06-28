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
      cached = {trusted: {}, blocked: {"https://bad.example/"}}
      ft = setmetatable {__official: cached}, __index: FeedTrust.__base
      ut\assertEquals FeedTrust.getOfficialBlockedFeeds(ft), {"https://bad.example/"}
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

    -- getBlockedFeeds: official block list first, then the user's blockedFeeds appended.
    getBlockedFeeds_mergesOfficialThenUser: (ut) ->
      ft = make officialBlocked: {"https://bad.example/"}, blockedFeeds: {"https://evil.example/"}
      blocked = FeedTrust.getBlockedFeeds ft
      ut\assertEquals #blocked, 2
      ut\assertEquals blocked[1], "https://bad.example/"
      ut\assertEquals blocked[2], "https://evil.example/"

    getBlockedFeeds_officialOnlyWhenNoUserFeeds: (ut) ->
      ft = make officialBlocked: {"https://bad.example/"}
      blocked = FeedTrust.getBlockedFeeds ft
      ut\assertEquals #blocked, 1
      ut\assertEquals blocked[1], "https://bad.example/"

    -- isTrusted checks the merged set (exact match), guarding nil; isBlocked uses prefix matching.
    isTrusted_checksMergedSet: (ut) ->
      ft = make officialTrusted: {"feed://o": true}, trustedFeeds: {"feed://t"}
      ut\assertTrue FeedTrust.isTrusted ft, "feed://o"
      ut\assertTrue FeedTrust.isTrusted ft, "feed://t"
      ut\assertFalse FeedTrust.isTrusted ft, "feed://x"
      ut\assertFalse FeedTrust.isTrusted ft, nil

    isBlocked_prefixMatch: (ut) ->
      ft = make officialBlocked: {"https://bad.example/"}
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
      ut\assertEquals ft.config.c.blockedFeeds[1], "https://bad/"
      ut\assertTrue saved[1]
      ut\assertTrue FeedTrust.isBlocked ft, "https://bad/x"

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
      "urlMatchesPrefix_exactAndCaseInsensitive", "urlMatchesPrefix_hostPrefixBlocksEverythingUnder"
      "urlMatchesPrefix_noMatch", "urlMatchesPrefix_guards"
    }
  }
