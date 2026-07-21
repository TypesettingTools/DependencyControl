FileCache = require "l0.DependencyControl.FileCache"
constants = require "l0.DependencyControl.Constants"
Logger = require "l0.DependencyControl.Logger"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"

defaultLogger = Logger fileBaseName: "#{constants.DEPCTRL_SHORT_NAME}.FeedLoader"

---Owns DependencyControl's single on-disk feed cache and hands out `UpdateFeed` instances wired to it,
---so no consumer assembles feed-fetch settings or names the cache. One instance is built per config (the
---updater keeps the shared one) and injected into every feed consumer; its cache is reachable as `.cache`.
---@class FeedLoader
---@field cache FileCache The shared feed cache, for metadata reads such as a feed's last-fetch time.
class FeedLoader
  -- Feed-fetch caps applied when the config leaves them unset. A feed is small JSON, so cap tightly.
  @defaultMaxFeedSize = 5 * 10^6
  @defaultFeedFetchTimeout = 15

  ---Reads the feed-fetch settings once and opens the shared feed cache under DepCtrl's namespace, wiring its
  ---L1 layer to `UpdateFeed`'s decoder so a cache hit serves a ready-parsed feed base.
  ---@param config ConfigView The global config view; reads `paths.cache`, `feeds.cacheMaxAge`/`feeds.maxFeedSize`/`feeds.feedFetchTimeout` and `updates.blockPrivateHosts`.
  ---@param logger? Logger Logger for the cache and the feeds it loads.
  new: (config, @logger = defaultLogger) =>
    c = config.c
    @cache = FileCache.get c.paths.cache, constants.DEPCTRL_NAMESPACE, "feeds",
      {maxAge: c.feeds.cacheMaxAge, logger: @logger, deserialize: UpdateFeed.deserialize}
    @blockPrivateHosts = c.updates.blockPrivateHosts
    @maxFeedSize = c.feeds.maxFeedSize or @@defaultMaxFeedSize
    @feedFetchTimeout = c.feeds.feedFetchTimeout or @@defaultFeedFetchTimeout

  ---Builds an `UpdateFeed` for the given URL, injecting the shared cache and the configured fetch policy.
  ---@param url string The feed URL to load.
  ---@param opts? { autoLoad?: boolean } `autoLoad` fetches immediately (default true). To refresh an entire update pass, expire the cache with `FileCache.expireAll`.
  ---@return UpdateFeed feed
  load: (url, opts = {}) =>
    autoLoad = opts.autoLoad
    autoLoad = true if autoLoad == nil
    feedConfig = {cache: @cache, blockPrivateHosts: @blockPrivateHosts, maxFeedSize: @maxFeedSize, feedFetchTimeout: @feedFetchTimeout}
    UpdateFeed url, autoLoad, nil, feedConfig, @logger
