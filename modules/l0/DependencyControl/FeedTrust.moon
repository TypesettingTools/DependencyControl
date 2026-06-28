constants = require "l0.DependencyControl.Constants"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
Common =     require "l0.DependencyControl.Common"

msgs = {
    trustedFeedAdded: "Added '%s' to your trusted feeds."
    blockedFeedAdded: "Added '%s' to your blocked feeds."
}

---Owns DependencyControl's feed-trust model: the official trust lists (loaded from DepCtrl's own feed),
---the merged trusted/blocked sets (official plus the user's config), the trust queries the resolver asks
---per candidate, and the user-config mutations. Built and exposed by `Updater` as `updater.feedTrust`.
---@class FeedTrust
class FeedTrust
    ---@param config ConfigView The updater's config view; its `c` holds `extraFeeds`/`trustedFeeds`/`blockedFeeds`.
    ---@param logger? Logger Logger for the trust/block confirmations.
    new: (@config, @logger) =>

    -- Lazily loads and caches DependencyControl's official trust lists from its own feed. Best-effort: if
    -- the feed can't be loaded, only DepCtrl's own feed URL is trusted and nothing is blocked.
    ---@private
    __loadOfficial: =>
        return @__official if @__official
        trusted, blocked = {[constants.DEPCTRL_FEED_URL]: true}, {}
        feed = UpdateFeed constants.DEPCTRL_FEED_URL, false, nil, nil, @logger
        if feed\ensureLoaded!
            Common.makeSet feed\getKnownFeeds!, trusted
            blocked = feed.data.blockedFeeds or {}
        @__official = {:trusted, :blocked}
        return @__official

    ---Returns the feed URLs DependencyControl officially trusts (its own feed URL plus the feeds it advertises).
    ---@return table<string,boolean> trustedFeeds
    getOfficialTrustedFeeds: => @__loadOfficial!.trusted

    ---Returns the feed URL prefixes DependencyControl officially block-lists.
    ---@return string[] blockedFeeds
    getOfficialBlockedFeeds: => @__loadOfficial!.blocked

    ---Returns the merged trusted feed-URL set: the official feeds plus the user's `extraFeeds` and
    ---`trustedFeeds`. Cached; invalidated when `trust` adds a feed.
    ---@return table<string,boolean> trustedFeeds
    getTrustedFeeds: =>
        unless @__trusted
            c = @config.c
            @__trusted = {url, true for url in pairs @getOfficialTrustedFeeds!}
            Common.makeSet c.extraFeeds or {}, @__trusted
            Common.makeSet c.trustedFeeds or {}, @__trusted
        return @__trusted

    ---Returns the merged blocked feed-URL prefix list: the official block list plus the user's `blockedFeeds`.
    ---Cached; invalidated when `block` adds a feed. A matching prefix overrides any trust.
    ---@return string[] blockedFeeds
    getBlockedFeeds: =>
        unless @__blocked
            c = @config.c
            @__blocked = [prefix for prefix in *@getOfficialBlockedFeeds!]
            @__blocked[#@__blocked + 1] = prefix for prefix in *(c.blockedFeeds or {})
        return @__blocked

    ---Reports whether a feed URL is in the merged trusted set (exact match).
    ---@param url? string
    ---@return boolean trusted
    isTrusted: (url) => url and @getTrustedFeeds![url] and true or false

    ---Reports whether a feed URL is matched by any blocked prefix.
    ---@param url? string
    ---@return boolean blocked
    isBlocked: (url) => @@urlMatchesPrefix url, @getBlockedFeeds!

    ---Adds a feed URL to the user's `trustedFeeds` config and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to trust.
    trust: (feedUrl) =>
        trustedFeeds = [url for url in *(@config.c.trustedFeeds or {})]
        trustedFeeds[#trustedFeeds + 1] = feedUrl
        @config.c.trustedFeeds = trustedFeeds
        @__trusted = nil
        @config\save!
        @logger\log msgs.trustedFeedAdded, feedUrl if @logger

    ---Adds a feed URL to the user's `blockedFeeds` config and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to block.
    block: (feedUrl) =>
        blockedFeeds = [url for url in *(@config.c.blockedFeeds or {})]
        blockedFeeds[#blockedFeeds + 1] = feedUrl
        @config.c.blockedFeeds = blockedFeeds
        @__blocked = nil
        @config\save!
        @logger\log msgs.blockedFeedAdded, feedUrl if @logger

    ---Reports whether a URL is matched (case-insensitively) by any of the given prefixes. Case-insensitive
    ---to align with domain-name casing; used for evasion-resistant block-list matching.
    ---@param url? string
    ---@param prefixes? string[]
    ---@return boolean matches
    @urlMatchesPrefix = (url, prefixes = {}) =>
        return false unless url
        url = url\lower!
        for prefix in *prefixes
            prefix = prefix\lower!
            return true if #prefix > 0 and url\sub(1, #prefix) == prefix
        return false

return FeedTrust
