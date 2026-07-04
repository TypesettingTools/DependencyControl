constants = require "l0.DependencyControl.Constants"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
Common =     require "l0.DependencyControl.Common"

msgs = {
    trustedFeedAdded:   "Added '%s' to your trusted feeds."
    trustedFeedRemoved: "Removed '%s' from your trusted feeds."
    blockedFeedAdded:   "Added '%s' to your blocked feeds."
    blockedFeedRemoved: "Removed '%s' from your blocked feeds."
    extraFeedAdded:     "Added '%s' to your extra feeds."
    extraFeedRemoved:   "Removed '%s' from your extra feeds."
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

    ---Appends a feed URL to one of the user's config lists (skipping an exact duplicate), invalidates the
    ---given cached set, and persists.
    ---@private
    ---@param configKey string The user config array field ("trustedFeeds"/"blockedFeeds"/"extraFeeds").
    ---@param cacheField string The cached field to invalidate ("__trusted"/"__blocked").
    ---@param feedUrl string The exact feed URL to add.
    ---@return boolean added False when the URL was already present.
    __addUserFeed: (configKey, cacheField, feedUrl) =>
        list = [url for url in *(@config.c[configKey] or {})]
        return false if Common.listIncludes list, feedUrl
        list[#list + 1] = feedUrl
        @config.c[configKey] = list
        self[cacheField] = nil
        @config\save!
        return true

    ---Removes every exact match of a feed URL from one of the user's config lists, invalidates the given
    ---cached set, and persists when something changed.
    ---@private
    ---@param configKey string The user config array field ("trustedFeeds"/"blockedFeeds"/"extraFeeds").
    ---@param cacheField string The cached field to invalidate ("__trusted"/"__blocked").
    ---@param feedUrl string The exact feed URL to remove.
    ---@return boolean removed False when no entry matched.
    __removeUserFeed: (configKey, cacheField, feedUrl) =>
        list = @config.c[configKey] or {}
        kept = [url for url in *list when url != feedUrl]
        return false if #kept == #list
        @config.c[configKey] = kept
        self[cacheField] = nil
        @config\save!
        return true

    ---Adds a feed URL to the user's `trustedFeeds` config (ignoring an exact duplicate) and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to trust.
    ---@return boolean added False when the feed was already in the user's `trustedFeeds`.
    trust: (feedUrl) =>
        added = @__addUserFeed "trustedFeeds", "__trusted", feedUrl
        @logger\log msgs.trustedFeedAdded, feedUrl if added and @logger
        return added

    ---Removes a feed URL from the user's `trustedFeeds` config and persists it. Feeds trusted through the
    ---official list or `extraFeeds` are unaffected; block the feed to override those.
    ---@param feedUrl string The exact (case-sensitive) feed URL to untrust.
    ---@return boolean removed False when the feed was not in the user's `trustedFeeds`.
    untrust: (feedUrl) =>
        removed = @__removeUserFeed "trustedFeeds", "__trusted", feedUrl
        @logger\log msgs.trustedFeedRemoved, feedUrl if removed and @logger
        return removed

    ---Adds a feed URL prefix to the user's `blockedFeeds` config (ignoring an exact duplicate) and persists it.
    ---@param feedUrl string The feed URL prefix to block (stored verbatim; matched case-insensitively as a prefix).
    ---@return boolean added False when the prefix was already in the user's `blockedFeeds`.
    block: (feedUrl) =>
        added = @__addUserFeed "blockedFeeds", "__blocked", feedUrl
        @logger\log msgs.blockedFeedAdded, feedUrl if added and @logger
        return added

    ---Removes a blocked prefix from the user's `blockedFeeds` config and persists it. The official block list is unaffected.
    ---@param feedUrl string The exact blocked-prefix string to remove (as stored).
    ---@return boolean removed False when the prefix was not in the user's `blockedFeeds`.
    unblock: (feedUrl) =>
        removed = @__removeUserFeed "blockedFeeds", "__blocked", feedUrl
        @logger\log msgs.blockedFeedRemoved, feedUrl if removed and @logger
        return removed

    ---Adds a feed URL to the user's `extraFeeds` config (ignoring an exact duplicate) and persists it. Extra
    ---feeds are trusted and act as discovery roots.
    ---@param feedUrl string The exact (case-sensitive) feed URL to add.
    ---@return boolean added False when the feed was already in the user's `extraFeeds`.
    addExtraFeed: (feedUrl) =>
        added = @__addUserFeed "extraFeeds", "__trusted", feedUrl
        @logger\log msgs.extraFeedAdded, feedUrl if added and @logger
        return added

    ---Removes a feed URL from the user's `extraFeeds` config and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to remove.
    ---@return boolean removed False when the feed was not in the user's `extraFeeds`.
    removeExtraFeed: (feedUrl) =>
        removed = @__removeUserFeed "extraFeeds", "__trusted", feedUrl
        @logger\log msgs.extraFeedRemoved, feedUrl if removed and @logger
        return removed

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
