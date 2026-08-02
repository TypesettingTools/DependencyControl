lfs = require "lfs"
constants = require "l0.DependencyControl.Constants"
FileCache = require "l0.DependencyControl.FileCache"
fileOps = require "l0.DependencyControl.file-ops"
Logger = require "l0.DependencyControl.Logger"
pathOps = require "l0.DependencyControl.path-ops"

msgs = {
  cleanLogs: {
    removed: "Removed %d log file(s) left in '%s' by a pre-0.9.0 release."
  }
  cleanCaches: {
    removed: "Removed %d cache file(s) left in '%s' by a pre-0.9.0 release."
  }
}

-- forward-declared so the members below close over the local rather than a global of the same name
local LegacyCleanup

---Removes what DependencyControl left behind in the locations it used before 0.9.0.
---Only files it can identify as its own go, and only a directory it empties is dropped, so anything
---else sharing those locations stays.
---@class LegacyCleanup
LegacyCleanup = {
  ---Path setting name mapped to the location that setting defaulted to before 0.9.0.
  ---@private
  __legacyPaths: {
    log: "?user/log"
    cache: "?user/cache"
  }

  ---Removes DependencyControl's own log files from the pre-0.9.0 log directory.
  ---A no-op once that directory resolves to the configured one, as it does wherever Aegisub maps
  ---`?state` onto `?user`.
  ---@param currentLogDir string The configured log directory, as a path or Aegisub path token.
  ---@param logger Logger Receives a trace line reporting what was removed.
  ---@return integer removed Log files deleted.
  cleanLogs: (currentLogDir, logger) ->
    dir = pathOps.decode LegacyCleanup.__legacyPaths.log
    return 0 if dir == pathOps.decode currentLogDir
    return 0 unless lfs.attributes dir, "mode"

    -- the trimmer matches only DepCtrl's own log file names, so Aegisub's own logs in this directory
    -- survive, as does any other script's
    removed = Logger(fileBaseName: constants.DEPCTRL_SHORT_NAME, logDir: dir)\trimFiles true
    if removed > 0
      fileOps.rmdir dir, false
      logger\trace msgs.cleanLogs.removed, removed, dir
    return removed

  ---Removes DependencyControl's cached files from the pre-0.9.0 cache directory.
  ---A no-op once that directory resolves to the configured one.
  ---@param currentCacheDir string The configured cache root, as a path or Aegisub path token.
  ---@param logger Logger Receives a trace line reporting what was removed.
  ---@return integer removed Cache files deleted.
  cleanCaches: (currentCacheDir, logger) ->
    dir = pathOps.decode LegacyCleanup.__legacyPaths.cache
    return 0 if dir == pathOps.decode currentCacheDir
    return 0 unless lfs.attributes dir, "mode"

    -- FileCache names these files, so it is what recognizes them again. Its sweep is the subsystem's
    -- internal contract (PV3), shared with this module rather than offered to library users.
    removed = FileCache._removeArtifactsIn dir
    if removed > 0
      fileOps.rmdir dir, false
      logger\trace msgs.cleanCaches.removed, removed, dir
    return removed

  ---Sweeps both pre-0.9.0 locations.
  ---A location that is already gone costs one directory probe, and a file that cannot be deleted is
  ---retried on the next call.
  ---@param paths table The `paths` config section, read for the configured `log` and `cache` locations.
  ---@param logger Logger Receives a trace line per location cleaned.
  ---@return integer removed Files deleted across both locations.
  run: (paths, logger) ->
    LegacyCleanup.cleanLogs(paths.log, logger) + LegacyCleanup.cleanCaches(paths.cache, logger)
}

return LegacyCleanup
