-- legacy-cleanup tests: the sweep of the locations DepCtrl wrote to before 0.9.0 removes only files it
-- can identify as its own, skips a location that resolves to the configured one, and totals what each
-- half removed. Recognizing a cache's own files belongs to FileCache and is tested with it; the log
-- half's matching belongs to Logger's trimmer.
-- Runs against real files under a temp base, with the legacy locations pointed at it.
-- Called from test.moon as: (require "…test.legacy-cleanup") basePath, stubHelpers
(basePath, stubHelpers) ->
  fileOps = require "l0.DependencyControl.file-ops"
  legacyCleanup = require "l0.DependencyControl.legacy-cleanup"
  constants = require "l0.DependencyControl.Constants"
  dkjson = require "l0.dkjson"

  logger = stubHelpers.makeNullLogger!
  originalLegacyPaths = legacyCleanup.__legacyPaths

  -- A fresh legacy/current directory pair per test, with the module's legacy locations pointed at the
  -- legacy one. `current` stands in for the configured location and is never written to.
  makeDirs = (name) ->
    legacy = fileOps.joinPath basePath, "legacyCleanup", name, "legacy"
    current = fileOps.joinPath basePath, "legacyCleanup", name, "current"
    fileOps.mkdir legacy, false, true
    legacyCleanup.__legacyPaths = {log: legacy, cache: legacy}
    return legacy, current

  -- A cache entry as FileCache writes it: an index naming its snapshot, plus that snapshot.
  writeCacheEntry = (dir, slug, label) ->
    snapshot = "#{slug}-#{label}-20260801T101010Z-ABCD.json"
    fileOps.writeFile fileOps.joinPath(dir, snapshot), '{"cached": true}', true
    meta = {key: "https://example.test/#{label}", cachedAt: 1, expiresAt: 2, latestFile: snapshot}
    fileOps.writeFile fileOps.joinPath(dir, "#{slug}.meta.json"), (dkjson.encode meta), true
    return snapshot

  -- A log file named the way Logger names DepCtrl's own.
  writeLogFile = (dir) ->
    path = fileOps.joinPath dir, "2026-08-01-10-10-10-ABCD_#{constants.DEPCTRL_SHORT_NAME}_l0.Test.log"
    fileOps.writeFile path, "log line", true
    return path

  exists = (path) ->
    info = fileOps.getAttributes path, "mode"
    return not not (info and info.attr != false)

  {
    _description: "legacy-cleanup: removing DepCtrl's own files from its pre-0.9.0 locations."

    -- a cache directory whose index decodes is one DepCtrl wrote, so its entries go
    cleanCaches_removesRecognizedEntries: (ut) ->
      legacy, current = makeDirs "cacheEntries"
      cacheDir = fileOps.joinPath legacy, constants.DEPCTRL_NAMESPACE, "feeds"
      fileOps.mkdir cacheDir, false, true
      snapshot = writeCacheEntry cacheDir, "0a1b2c3", "someFeed"

      ut\assertEquals legacyCleanup.cleanCaches(current, logger), 2
      ut\assertFalse exists fileOps.joinPath cacheDir, snapshot
      ut\assertFalse exists fileOps.joinPath cacheDir, "0a1b2c3.meta.json"
      -- the emptied tree goes with its contents
      ut\assertFalse exists legacy

    -- wherever Aegisub maps ?state onto ?user the legacy location is the live one; it must be left alone
    cleanCaches_skipsWhenLegacyIsCurrent: (ut) ->
      legacy = makeDirs "cacheSameDir"
      cacheDir = fileOps.joinPath legacy, constants.DEPCTRL_NAMESPACE, "feeds"
      fileOps.mkdir cacheDir, false, true
      snapshot = writeCacheEntry cacheDir, "0a1b2c3", "someFeed"

      ut\assertEquals legacyCleanup.cleanCaches(legacy, logger), 0
      ut\assertTrue exists fileOps.joinPath cacheDir, snapshot

    -- a location DepCtrl never wrote to costs one probe and reports nothing
    cleanCaches_skipsMissingDirectory: (ut) ->
      missing = fileOps.joinPath basePath, "legacyCleanup", "neverWritten"
      legacyCleanup.__legacyPaths = {log: missing, cache: missing}
      ut\assertEquals legacyCleanup.cleanCaches(fileOps.joinPath(basePath, "elsewhere"), logger), 0

    -- DepCtrl's own log files match its naming; Aegisub's logs shared this directory and must survive
    cleanLogs_removesOwnLogFilesOnly: (ut) ->
      legacy, current = makeDirs "logs"
      ours = writeLogFile legacy
      aegisubLog = fileOps.joinPath legacy, "aegisub.json"
      fileOps.writeFile aegisubLog, "{}", true

      ut\assertEquals legacyCleanup.cleanLogs(current, logger), 1
      ut\assertFalse exists ours
      ut\assertTrue exists aegisubLog
      -- a directory still holding someone else's files is not ours to remove
      ut\assertTrue exists legacy

    cleanLogs_skipsWhenLegacyIsCurrent: (ut) ->
      legacy = makeDirs "logsSameDir"
      ours = writeLogFile legacy

      ut\assertEquals legacyCleanup.cleanLogs(legacy, logger), 0
      ut\assertTrue exists ours

    -- run sweeps both locations and totals what each removed
    run_totalsBothLocations: (ut) ->
      legacy, current = makeDirs "run"
      cacheDir = fileOps.joinPath legacy, constants.DEPCTRL_NAMESPACE, "feeds"
      fileOps.mkdir cacheDir, false, true
      writeCacheEntry cacheDir, "0a1b2c3", "someFeed"
      writeLogFile legacy

      ut\assertEquals legacyCleanup.run({log: current, cache: current}, logger), 3

    -- the legacy locations are module state, so they must not stay pointed at the temp base
    _teardown: -> legacyCleanup.__legacyPaths = originalLegacyPaths

    _order: {
      "cleanCaches_removesRecognizedEntries"
      "cleanCaches_skipsWhenLegacyIsCurrent", "cleanCaches_skipsMissingDirectory"
      "cleanLogs_removesOwnLogFilesOnly", "cleanLogs_skipsWhenLegacyIsCurrent"
      "run_totalsBothLocations"
    }
  }
