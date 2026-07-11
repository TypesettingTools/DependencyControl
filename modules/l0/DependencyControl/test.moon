constants = require "l0.DependencyControl.Constants"
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"

UnitTestSuite constants.DEPCTRL_NAMESPACE, (DepCtrl, ...) ->
  -- The suite controls object is appended by UnitTestSuite\import as the final argument.
  -- Its index varies by loader (CLI vs Aegisub pass different arg counts), so grab the last one.
  nArgs    = select "#", ...
  controls = select nArgs, ...
  ffi      = require "ffi"

  isWindows = ffi.os == "Windows"
  basePath  = aegisub.decode_path "?temp/l0.#{DepCtrl.__name}.#{UnitTestSuite.__name}_#{'%04X'\format math.random 0, 16^4-1}"

  -- Each test class lives in its own sibling module under `test/`, loaded via the suite's
  -- requireTest helper so the same call resolves in both the Aegisub-default and custom (CI)
  -- test locations. Classes needing shared fixtures receive them as arguments (basePath for
  -- temp-file paths, DepCtrl for the live record/logger, isWindows for platform branches).
  {
    Timer:              (controls\requireTest "Timer")!
    BadMutex:           (controls\requireTest "BadMutex")!
    Crypto:             (controls\requireTest "Crypto")!
    ModuleProvider:     (controls\requireTest "ModuleProvider") basePath, DepCtrl
    Downloader:         (controls\requireTest "Downloader") basePath
    Common:             (controls\requireTest "Common") basePath
    FileOps:            (controls\requireTest "FileOps") basePath, isWindows
    Logger:             (controls\requireTest "Logger")!
    UnitTestSuite:      (controls\requireTest "UnitTestSuite")!
    Enum:               (controls\requireTest "Enum")!
    SemanticVersion: (controls\requireTest "SemanticVersion")!
    Lock:               (controls\requireTest "Lock")!
    FileLock:           (controls\requireTest "FileLock")!
    NamedSemaphore:     (controls\requireTest "NamedSemaphore")!
    ConfigHandler:      (controls\requireTest "ConfigHandler")!
    ConfigView:         (controls\requireTest "ConfigView")!
    ConfigSchema:       (controls\requireTest "config-schema")!
    ModuleLoader:       (controls\requireTest "ModuleLoader")!
    Record:             (controls\requireTest "Record")!
    UpdateTask:         (controls\requireTest "UpdateTask")!
    Updater:            (controls\requireTest "Updater")!
    FeedTrust:          (controls\requireTest "FeedTrust")!
    FeedLoader:         (controls\requireTest "FeedLoader") basePath, DepCtrl
    Host:               (controls\requireTest "Host")!
    FeedInventory:      (controls\requireTest "FeedInventory")!
    FeedManager:        (controls\requireTest "FeedManager")!
    FileCache:          (controls\requireTest "FileCache") basePath
    ScriptUpdateRecord: (controls\requireTest "ScriptUpdateRecord")!
    UpdateFeed:         (controls\requireTest "UpdateFeed") basePath, DepCtrl
    GitRepository:      (controls\requireTest "GitRepository")!
    ScriptTargetFilter: (controls\requireTest "ScriptTargetFilter")!
    ZipArchiver:        (controls\requireTest "ZipArchiver") basePath
    JsonSchema:         (controls\requireTest "JsonSchema") basePath
    FfiPosix:           (controls\requireTest "ffi-posix")!
    OpenUrl:            (controls\requireTest "open-url")!
    DownloaderIntegration: (controls\requireTest "integration.Downloader") basePath
    ZipArchiverIntegration: (controls\requireTest "integration.ZipArchiver") basePath
  }
