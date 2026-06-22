-- Updater tests.
-- Called from test.moon as: (controls\requireTest "Updater")!
() ->
  Updater = require "l0.DependencyControl.Updater"

  {
    _description: "Tests for Updater: the official feed trust getters."

    -- Updater.getOfficialTrustedFeeds / getOfficialBlockedFeeds return DependencyControl's officially
    -- trusted feed set and blocked-prefix list, loading the feed once and caching it on the instance.
    -- With a pre-seeded cache the getters must short-circuit (loadOfficialFeedTrust returns early)
    -- instead of rebuilding it: assertIs checks the cache is the *same* table after the call (reference
    -- equality), which a rebuild would replace.

    getOfficialTrustedFeeds_usesCacheWhenPresent: (ut) ->
      cached = {trusted: {"feed://a": true}, blocked: {}}
      updater = {officialFeedTrust: cached}
      ut\assertTrue Updater.getOfficialTrustedFeeds(updater)["feed://a"]
      ut\assertIs updater.officialFeedTrust, cached

    getOfficialBlockedFeeds_usesCacheWhenPresent: (ut) ->
      cached = {trusted: {}, blocked: {"https://bad.example/"}}
      updater = {officialFeedTrust: cached}
      ut\assertEquals Updater.getOfficialBlockedFeeds(updater), {"https://bad.example/"}
      ut\assertIs updater.officialFeedTrust, cached

    _order: {
      "getOfficialTrustedFeeds_usesCacheWhenPresent", "getOfficialBlockedFeeds_usesCacheWhenPresent"
    }
  }
