-- FeedLoader tests: builds the shared feed cache from config and hands out UpdateFeed instances wired to
-- it. Network-free — feeds are constructed with autoLoad off, so nothing is fetched.
-- Called from test.moon as: (require "…test.FeedLoader") basePath, DepCtrl
(basePath, DepCtrl) ->
  FeedLoader = require "l0.DependencyControl.FeedLoader"
  fileOps = require "l0.DependencyControl.file-ops"
  constants = require "l0.DependencyControl.Constants"

  url = "https://example.com/feed.json"

  -- a FeedLoader over a temp cache base; opts override the config's feed settings
  make = (opts = {}) ->
    config = {c: {
      paths: {cache: fileOps.joinPath basePath, "feedLoader"}
      feeds: {cacheMaxAge: opts.cacheMaxAge or 4242}
      updates: {blockPrivateHosts: opts.blockPrivateHosts}
    }}
    FeedLoader config, DepCtrl.logger

  {
    _description: "FeedLoader: shared feed cache construction and UpdateFeed wiring."

    -- the cache lives under DepCtrl's namespace in a `feeds` subdir of the configured cache base
    new_opensFeedCacheUnderNamespace: (ut) ->
      loader = make!
      ut\assertNotNil loader.cache
      ut\assertContains loader.cache.cacheDir, constants.DEPCTRL_NAMESPACE
      ut\assertMatches loader.cache.cacheDir, "feeds$"

    -- load injects the shared cache and the configured fetch policy
    load_wiresSharedCacheAndPolicy: (ut) ->
      loader = make {blockPrivateHosts: true}
      feed = loader\load url, {autoLoad: false}
      ut\assertIs feed.config.cache, loader.cache
      ut\assertTrue feed.config.blockPrivateHosts
      ut\assertNil feed.data -- autoLoad off: constructed but not fetched

    _order: {
      "new_opensFeedCacheUnderNamespace", "load_wiresSharedCacheAndPolicy"
    }
  }
