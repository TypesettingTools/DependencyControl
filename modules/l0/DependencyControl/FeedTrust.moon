constants = require "l0.DependencyControl.Constants"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
Common =     require "l0.DependencyControl.Common"
Enum =       require "l0.DependencyControl.Enum"

msgs = {
    trustedFeedAdded:   "Added '%s' to your trusted feeds."
    trustedFeedRemoved: "Removed '%s' from your trusted feeds."
    blockedFeedAdded:   "Added '%s' to your blocked feeds."
    blockedFeedRemoved: "Removed '%s' from your blocked feeds."
    extraFeedAdded:     "Added '%s' to your extra feeds."
    extraFeedRemoved:   "Removed '%s' from your extra feeds."
}

---A normalized feed block entry: the URL/prefix to match, how to match it, and why.
---@class BlockedFeedEntry
---@field url string The feed URL or URL prefix to match.
---@field matchMode BlockedFeedMatchMode How `url` is matched against a candidate feed URL.
---@field reason? string Human-readable explanation of why the feed is blocked.
---@field isOfficial? boolean True for an entry from the official block list (read-only); false for a user block.

---Owns DependencyControl's feed-trust model: the official trust lists (loaded from DepCtrl's own feed),
---the merged trusted/blocked sets (official plus the user's config), the trust queries the resolver asks
---per candidate, and the user-config mutations. Built and exposed by `Updater` as `updater.feedTrust`.
---@class FeedTrust
class FeedTrust
    ---@alias BlockedFeedMatchMode
    ---| "prefix" # Prefix: matches any feed URL starting with this value (case-insensitive)
    ---| "exact" # Exact: matches only this exact feed URL (case-insensitive)
    @BlockMatchMode = Enum "BlockedFeedMatchMode", {
        Prefix: "prefix"
        Exact:  "exact"
    }

    ---@alias FeedTrustStatus
    ---| "trusted-official" # TrustedOfficial: trusted only through DependencyControl's official set
    ---| "trusted-user" # TrustedUser: trusted only through one of the user's own lists (extraFeeds or trustedFeeds)
    ---| "trusted-both" # TrustedBoth: trusted through both the official set and one of the user's own lists
    ---| "untrusted" # Untrusted: neither trusted nor blocked (the default)
    ---| "blocked" # Blocked: matched by the block list, which overrides trust
    @TrustStatus = Enum "FeedTrustStatus", {
        TrustedOfficial: "trusted-official"
        TrustedUser:     "trusted-user"
        TrustedBoth:     "trusted-both"
        Untrusted:       "untrusted"
        Blocked:         "blocked"
    }

    ---@param config ConfigView The updater's config view; its `c` holds `extraFeeds`/`trustedFeeds`/`blockedFeeds`.
    ---@param logger? Logger Logger for the trust/block confirmations.
    new: (@config, @logger) =>

    ---Lazily loads and caches DependencyControl's official trust lists from its own feed. Best-effort: if the
    ---feed can't be loaded, only DepCtrl's own feed URL is trusted and nothing is blocked.
    ---@private
    ---@return { trusted: table<string,boolean>, blocked: table[] } official Cached official trusted-feed set and raw block-list entries.
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

    ---Returns DependencyControl's official block list as raw `{url, matchMode?, reason?}` entries, exactly as
    ---declared in its own feed.
    ---@return BlockedFeedEntry[] blockedFeeds
    getOfficialBlockedFeeds: => @__loadOfficial!.blocked

    ---Returns the user's own trusted feeds: the union of `extraFeeds` (discovery roots) and `trustedFeeds`
    ---(trust-only). Cached; invalidated when the user's lists change.
    ---@return table<string,boolean> userTrustedFeeds
    getUserTrustedFeeds: =>
        unless @__userTrusted
            c = @config.c
            set = {}
            Common.makeSet c.extraFeeds or {}, set
            Common.makeSet c.trustedFeeds or {}, set
            @__userTrusted = set
        return @__userTrusted

    ---Returns the merged trusted feed-URL set: the official feeds plus the user's own trusted feeds
    ---(`extraFeeds` and `trustedFeeds`). Cached; invalidated when the user's lists change.
    ---@return table<string,boolean> trustedFeeds
    getTrustedFeeds: =>
        unless @__trusted
            merged = {url, true for url in pairs @getOfficialTrustedFeeds!}
            merged[url] = true for url in pairs @getUserTrustedFeeds!
            @__trusted = merged
        return @__trusted

    ---Returns a merged, normalized list of the "officially" blocked feeds (as per DependencyControls own feed),
    ---followed by the user's blocked feeds. Block overrides trust.
    ---@return BlockedFeedEntry[] blockedFeeds The merged list of normalized block entries, each tagged `isOfficial` when it comes from the official feed.
    getBlockedFeeds: =>
        unless @__blocked
            entries = {}
            for raw in *@getOfficialBlockedFeeds!
                entry = @@__normalizeBlockEntry raw
                if entry
                    entry.isOfficial = true
                    entries[#entries + 1] = entry
            for raw in *(@config.c.blockedFeeds or {})
                entry = @@__normalizeBlockEntry raw
                if entry
                    entry.isOfficial = false
                    entries[#entries + 1] = entry
            @__blocked = entries
        return @__blocked

    ---Reports whether a feed URL is in the merged trusted set (exact match).
    ---@param url? string The feed URL to check.
    ---@return boolean trusted True when the feed URL is trusted, false otherwise.
    isTrusted: (url) => url and @getTrustedFeeds![url] and true or false

    ---Reports whether a feed URL is trusted through one of the user's own lists (`extraFeeds` or `trustedFeeds`),
    ---as opposed to DependencyControl's official set. A block does not factor into this.
    ---@param url? string The feed URL to check.
    ---@return boolean userTrusted True when the feed URL is in one of the user's trust lists.
    isUserTrusted: (url) => url and @getUserTrustedFeeds![url] and true or false

    ---Reports whether a feed URL is in DependencyControl's official trusted set (its own feed plus the feeds it
    ---advertises), as opposed to the user's own lists. A block does not factor into this.
    ---@param url? string The feed URL to check.
    ---@return boolean officiallyTrusted True when the feed URL is officially trusted.
    isOfficiallyTrusted: (url) => url and @getOfficialTrustedFeeds![url] and true or false

    ---Reports whether a feed URL is matched by any block entry (official or user).
    ---@param url? string The feed URL to check.
    ---@return boolean blocked True when the feed URL is blocked, false otherwise.
    isBlocked: (url) => @getBlockingEntry(url) != nil

    ---Returns the block entry that matches a feed URL or nil if none does.
    ---Useful to get the reason for a block.
    ---@param url? string The feed URL to check.
    ---@return BlockedFeedEntry? entry The first matching block entry, or nil.
    getBlockingEntry: (url) =>
        return nil unless url
        for entry in *@getBlockedFeeds!
            return entry if @@matchesBlockEntry url, entry
        return nil

    ---Classifies a feed URL's trust: a block overrides any trust, and official vs user trust are reported
    ---independently (a feed in both is `TrustedBoth`).
    ---@param url? string The feed URL to classify.
    ---@return FeedTrustStatus status
    ---@return BlockedFeedEntry? blockingEntry The block entry that matched when the feed is blocked, else nil.
    getTrustStatus: (url) =>
        blockingEntry = @getBlockingEntry url
        return @@TrustStatus.Blocked, blockingEntry if blockingEntry
        official = @isOfficiallyTrusted url
        user =     @isUserTrusted url
        return @@TrustStatus.TrustedBoth if official and user
        return @@TrustStatus.TrustedUser if user
        return @@TrustStatus.TrustedOfficial if official
        @@TrustStatus.Untrusted

    ---Appends a feed URL to one of the user's config lists (skipping an exact duplicate), invalidates the
    ---cached trusted set, and persists.
    ---@private
    ---@param configKey string The user config array field ("trustedFeeds" or "extraFeeds").
    ---@param feedUrl string The exact feed URL to add.
    ---@return boolean added True when the URL was added, false when it was already present.
    __addUserFeed: (configKey, feedUrl) =>
        list = [url for url in *(@config.c[configKey] or {})]
        return false if Common.listIncludes list, feedUrl
        list[#list + 1] = feedUrl
        @config.c[configKey] = list
        @__trusted, @__userTrusted = nil, nil
        @config\save!
        return true

    ---Removes every exact match of a feed URL from one of the user's config lists, invalidates the cached
    ---trusted set, and persists when something changed.
    ---@private
    ---@param configKey string The user config array field ("trustedFeeds" or "extraFeeds").
    ---@param feedUrl string The exact feed URL to remove.
    ---@return boolean removed True when a feed was removed from the user's config, false when no entry matched.
    __removeUserFeed: (configKey, feedUrl) =>
        list = @config.c[configKey] or {}
        kept = [url for url in *list when url != feedUrl]
        return false if #kept == #list
        @config.c[configKey] = kept
        @__trusted, @__userTrusted = nil, nil
        @config\save!
        return true

    ---Adds a feed URL to the user's `trustedFeeds` list in the DependencyControl config file (ignoring an exact duplicate).
    ---@param feedUrl string The exact (case-sensitive) feed URL to trust.
    ---@return boolean added True when the feed was added to the user's `trustedFeeds`, false when it was already present.
    trust: (feedUrl) =>
        added = @__addUserFeed "trustedFeeds", feedUrl
        @logger\log msgs.trustedFeedAdded, feedUrl if added and @logger
        return added

    ---Removes a feed URL from the user's `trustedFeeds` list in the DependencyControl config file. 
    ---Feeds trusted through the official list or `extraFeeds` are unaffected; block the feed to override those.
    ---@param feedUrl string The exact (case-sensitive) feed URL to untrust.
    ---@return boolean removed True, when the feed was removed from the user's `trustedFeeds`, false when it wasn't present.
    untrust: (feedUrl) =>
        removed = @__removeUserFeed "trustedFeeds", feedUrl
        @logger\log msgs.trustedFeedRemoved, feedUrl if removed and @logger
        return removed

    ---Adds a new entry to the user's `blockedFeeds` in the DependencyControl config file,
    ---unless a block with the same url and match mode is already present.
    ---@param feedUrl string The feed URL or URL prefix to block.
    ---@param opts? { matchMode?: BlockedFeedMatchMode, reason?: string } The match mode (default prefix) and an optional reason.
    ---@return boolean added False when an equivalent block (same url and match mode) was already present.
    block: (feedUrl, opts = {}) =>
        matchMode = opts.matchMode or @@BlockMatchMode.Prefix
        entries = [e for e in *(@config.c.blockedFeeds or {})]
        for raw in *entries
            norm = @@__normalizeBlockEntry raw
            return false if norm and norm.url == feedUrl and norm.matchMode == matchMode
        entries[#entries + 1] = {url: feedUrl, :matchMode, reason: opts.reason}
        @config.c.blockedFeeds = entries
        @__blocked = nil
        @config\save!
        @logger\log msgs.blockedFeedAdded, feedUrl if @logger
        return true

    ---Removes every entry from the user's `blockedFeeds` list in the DependencyControl config file, 
    ---whose url matches `feedUrl`. Does not affect the official block list.
    ---@param feedUrl string The blocked url/prefix to remove.
    ---@return boolean removed True when a user block was removed, false when no user block matched.
    unblock: (feedUrl) =>
        list = @config.c.blockedFeeds or {}
        kept = [raw for raw in *list when (@@__normalizeBlockEntry(raw) or {}).url != feedUrl]
        return false if #kept == #list
        @config.c.blockedFeeds = kept
        @__blocked = nil
        @config\save!
        @logger\log msgs.blockedFeedRemoved, feedUrl if @logger
        return true

    ---Adds a feed URL to the user's `extraFeeds` config (ignoring an exact duplicate) and persists it. Extra
    ---feeds are trusted and act as discovery roots.
    ---@param feedUrl string The exact (case-sensitive) feed URL to add.
    ---@return boolean added False when the feed was already in the user's `extraFeeds`.
    addExtraFeed: (feedUrl) =>
        added = @__addUserFeed "extraFeeds", feedUrl
        @logger\log msgs.extraFeedAdded, feedUrl if added and @logger
        return added

    ---Removes a feed URL from the user's `extraFeeds` config and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to remove.
    ---@return boolean removed False when the feed was not in the user's `extraFeeds`.
    removeExtraFeed: (feedUrl) =>
        removed = @__removeUserFeed "extraFeeds", feedUrl
        @logger\log msgs.extraFeedRemoved, feedUrl if removed and @logger
        return removed

    ---Reports whether a URL is matched by any of the given prefixes.
    ---Case-insensitive to resist evasion attempts.
    ---@param url? string The feed URL to check.
    ---@param prefixes? string[] The list of prefixes to match against.
    ---@return boolean matches True when the feed URL matches any of the prefixes, false otherwise.
    @urlMatchesPrefix = (url, prefixes = {}) =>
        return false unless url
        url = url\lower!
        for prefix in *prefixes
            prefix = prefix\lower!
            return true if #prefix > 0 and url\sub(1, #prefix) == prefix
        return false

    ---Normalizes a raw block table into a `BlockedFeedEntry`, applying defaults as per the schema.
    ---@private
    ---@param entry { url, matchMode?, reason? } A raw entry from a feed's or the user's `blockedFeeds`.
    ---@return BlockedFeedEntry? normalized The normalized entry, or nil when it carries no url.
    @__normalizeBlockEntry = (entry) =>
        return nil unless type(entry) == "table" and type(entry.url) == "string"
        matchMode = @BlockMatchMode\validate(entry.matchMode) and entry.matchMode or @BlockMatchMode.Prefix
        return {url: entry.url, :matchMode, reason: entry.reason}

    ---Reports whether a URL is matched by a single block entry, per its match mode.
    ---All matches are case-insensitive to combat evasion attempts.
    ---@param url? string The feed URL to check.
    ---@param entry BlockedFeedEntry A normalized block entry.
    ---@return boolean matches True when the feed URL is blocked, false otherwise.
    @matchesBlockEntry = (url, entry) =>
        return false unless url and entry and entry.url
        return url\lower! == entry.url\lower! if entry.matchMode == @BlockMatchMode.Exact
        return @urlMatchesPrefix url, {entry.url}

return FeedTrust
