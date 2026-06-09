constants = require "l0.DependencyControl.Constants"
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"

UnitTestSuite constants.DEPCTRL_NAMESPACE, (DepCtrl, ...) ->
  -- The suite controls object is appended by UnitTestSuite\import as the final argument.
  -- Its index varies by loader (CLI vs Aegisub pass different arg counts), so grab the last one.
  nArgs    = select "#", ...
  controls = select nArgs, ...
  lfs       = require "lfs"
  ffi       = require "ffi"
  Logger             = require "l0.DependencyControl.Logger"
  Common             = require "l0.DependencyControl.Common"
  Enum               = require "l0.DependencyControl.Enum"
  FileOps            = require "l0.DependencyControl.FileOps"
  SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
  Lock               = require "l0.DependencyControl.Lock"
  ConfigHandler      = require "l0.DependencyControl.ConfigHandler"
  ConfigView         = require "l0.DependencyControl.ConfigView"
  ModuleLoader       = require "l0.DependencyControl.ModuleLoader"
  Record             = require "l0.DependencyControl.Record"
  UpdateFeed         = require "l0.DependencyControl.UpdateFeed"
  ScriptUpdateRecord = require "l0.DependencyControl.ScriptUpdateRecord"
  GitRepository      = require "l0.DependencyControl.GitRepository"
  Timer              = require "l0.DependencyControl.Timer"
  TerribleMutex      = require "l0.DependencyControl.TerribleMutex"
  Downloader         = require "l0.DependencyControl.Downloader"
  Crypto             = require "l0.DependencyControl.Crypto"
  ModuleProvider     = require "l0.DependencyControl.ModuleProvider"
  Stub               = require "l0.DependencyControl.Stub"

  BADMUTEX_MODULE_NAME = "BM.BadMutex"
  TIMER_MODULE_NAME = "l0.DependencyControl.Timer"
  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"
  JSON_MODULE_NAME = "json"
  DEPCTRL_DUMMY_MODULE_MARKER = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Dummy"
  DEPCTRL_RECORDS_GLOBAL_KEY = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}Records"

  isWindows  = ffi.os == "Windows"
  pathSep = isWindows and "\\" or "/"
  basePath = aegisub.decode_path "?temp/l0.#{DepCtrl.__name}.#{UnitTestSuite.__name}_#{'%04X'\format math.random 0, 16^4-1}"

  -- Fake transfer driver for Downloader.multiplex: each download completes after
  -- `steps` step() calls (1 byte each), recording the order step() is called so
  -- tests can assert round-robin fairness without any real network I/O.
  makeFakeDriver = (steps, order) ->
    {
      start: (dl) ->
        dl.totalBytes = steps
        dl.bytesReceived = 0
        true
      step: (dl) ->
        order[#order + 1] = dl.id
        dl.bytesReceived += 1
        return "done" if dl.bytesReceived >= steps
        "more"
      finish: (dl) -> nil
    }

  -- builds a downloader whose runner drives multiplex with the given fake driver
  fakeManager = (driver) ->
    Downloader (mgr) -> Downloader.multiplex mgr, driver

  Status = Downloader.Download.Status

  -- generates a process-unique module-alias name (the ModuleProvider registry is global)
  uniqueName = (prefix) -> "#{prefix}_#{'%08X'\format math.random 0, 16^8-1}"

  -- Runs fn with FileOps' path-length detection results overridden, restoring them
  -- afterwards (even if fn raises) so the platform-derived values don't leak between
  -- tests. Lets us exercise every "path too long" diagnostic branch on any OS.
  withPathLimits = (maxLength, longPathsDisabled, registryEnabled, fn) ->
    saved = {FileOps.pathMaxLength, FileOps.longPathsDisabled, FileOps.windowsRegistryLongPathsEnabled}
    FileOps.pathMaxLength = maxLength
    FileOps.longPathsDisabled = longPathsDisabled
    FileOps.windowsRegistryLongPathsEnabled = registryEnabled
    results = table.pack pcall fn
    FileOps.pathMaxLength, FileOps.longPathsDisabled, FileOps.windowsRegistryLongPathsEnabled = saved[1], saved[2], saved[3]
    error results[2] unless results[1]
    return unpack results, 2, results.n

  {
    Timer: {
      _description: "Tests for the FFI-based Timer: monotonic timing and millisecond sleep."

      -- timeElapsed

      timeElapsed_nonNegative: (ut) ->
        t = Timer!
        ut\assertGreaterThanOrEquals t\timeElapsed!, 0

      timeElapsed_monotonic: (ut) ->
        t = Timer!
        a = t\timeElapsed!
        b = t\timeElapsed!
        ut\assertGreaterThanOrEquals b, a

      timeElapsed_advancesAfterSleep: (ut) ->
        t = Timer!
        Timer.sleep 20          -- 20 ms
        -- Require at least 10 ms to pass; allows 50% margin for CI jitter.
        ut\assertGreaterThan t\timeElapsed!, 0.010

      -- sleep

      sleep_isCallable: (ut) ->
        -- Smoke test: sleep(0) must not error and must return.
        Timer.sleep 0
        ut\assertTrue true

      sleep_onClass: (ut) ->
        -- sleep is a static method accessible directly on the class.
        ut\assertFunction Timer.sleep

      sleep_onInstance: (ut) ->
        -- sleep is also accessible through an instance (class method inheritance).
        t = Timer!
        ut\assertFunction t.sleep

      _order: {
        "timeElapsed_nonNegative", "timeElapsed_monotonic",
        "timeElapsed_advancesAfterSleep",
        "sleep_isCallable", "sleep_onClass", "sleep_onInstance"
      }
    }

    TerribleMutex: {
      _description: "Tests for TerribleMutex: FFI-based process-scoped mutex that fills in for BM.BadMutex."

      -- API surface

      api_hasTryLock: (ut) ->
        ut\assertFunction TerribleMutex.tryLock

      api_hasLock: (ut) ->
        ut\assertFunction TerribleMutex.lock

      api_hasUnlock: (ut) ->
        ut\assertFunction TerribleMutex.unlock

      -- tryLock / unlock round-trip

      tryLock_acquires: (ut) ->
        result = TerribleMutex.tryLock!
        ut\assertTrue result
        TerribleMutex.unlock!  -- release so subsequent tests start clean

      tryLock_failsWhenHeld: (ut) ->
        ut\assertTrue TerribleMutex.tryLock!          -- acquire
        result = TerribleMutex.tryLock!               -- second attempt must fail
        TerribleMutex.unlock!
        ut\assertFalse result

      unlock_releasesLock: (ut) ->
        ut\assertTrue TerribleMutex.tryLock!
        TerribleMutex.unlock!
        result = TerribleMutex.tryLock!               -- must succeed again after release
        TerribleMutex.unlock!
        ut\assertTrue result

      -- BM.BadMutex alias

      registered_asBadMutex: (ut) ->
        -- DepCtrl provides "BM.BadMutex" (native if installed, else this FFI mutex),
        -- so the bare name resolves once DepCtrl is loaded
        ut\assertNotNil package.loaded["BM.BadMutex"]

      _order: {
        "api_hasTryLock", "api_hasLock", "api_hasUnlock",
        "tryLock_acquires", "tryLock_failsWhenHeld", "unlock_releasesLock",
        "registered_asBadMutex"
      }
    }

    Crypto: {
      _description: "Tests for the pure-Lua Crypto utilities (SHA-1) against known vectors."

      sha1_abc: (ut) ->
        ut\assertEquals Crypto.sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d"

      sha1_empty: (ut) ->
        ut\assertEquals Crypto.sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709"

      -- exercises multi-block padding (>55 bytes)
      sha1_quickBrownFox: (ut) ->
        ut\assertEquals Crypto.sha1("The quick brown fox jumps over the lazy dog"),
                        "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"

      -- binary payloads (embedded NUL and high bytes) hash without error
      sha1_binaryData: (ut) ->
        digest = Crypto.sha1 "\0\1\2\254\255"
        ut\assertMatches digest, "^%x+$"
        ut\assertEquals #digest, 40

      sha1_rejectsNonString: (ut) ->
        result, err = Crypto.sha1 42
        ut\assertNil result
        ut\assertString err

      -- whichever backend is active (native or lua) must match the reference impl
      sha1_backendMatchesReference: (ut) ->
        for input in *{"", "abc", "The quick brown fox jumps over the lazy dog", "\0\1\2\254\255"}
          ut\assertEquals Crypto.sha1(input), Crypto._sha1Lua(input)

      _order: {
        "sha1_abc", "sha1_empty", "sha1_quickBrownFox",
        "sha1_binaryData", "sha1_rejectsNonString", "sha1_backendMatchesReference"
      }
    }

    ModuleProvider: (controls\requireTest "ModuleProvider") basePath, DepCtrl

    Downloader: {
      _description: "Tests for the Downloader engine: round-robin scheduling and per-download callbacks (via a fake driver). (Offline — no network.)"

      -- round-robin scheduling: the scheduler must step every active transfer once
      -- per pass, so two downloads interleave rather than running one to completion first

      roundRobin_interleaves: (ut) ->
        order = {}
        dm = fakeManager makeFakeDriver 3, order
        dm\addDownload "http://x/1", "#{basePath}_rr1"
        dm\addDownload "http://x/2", "#{basePath}_rr2"
        dm\await!
        -- 2 downloads × 3 steps; each pass touches both before re-stepping either
        ut\assertEquals #order, 6
        ut\assertNotEquals order[1], order[2]   -- first pass touched both
        ut\assertNotEquals order[3], order[4]   -- second pass too
        ut\assertEquals dl.status, Status.Finished for dl in *dm.downloads

      -- the user-described scenario: start two slow downloads, detect (via the
      -- progress callback) that both are in flight simultaneously, then abort early

      roundRobin_detectsConcurrencyThenCancels: (ut) ->
        order = {}
        dm = fakeManager makeFakeDriver 1000, order   -- "slow": many steps to finish
        dm\addDownload "http://x/1", "#{basePath}_c1"
        dm\addDownload "http://x/2", "#{basePath}_c2"

        maxConcurrent = 0
        dm\on Downloader.Event.Progress, (downloader, percent) ->
          inFlight = 0
          for dl in *dm.downloads
            inFlight += 1 if dl.status == Status.Active and (dl.bytesReceived or 0) > 0
          maxConcurrent = math.max maxConcurrent, inFlight
          dm\cancel! if maxConcurrent >= 2   -- proven concurrent → abort
        dm\await!

        ut\assertGreaterThanOrEquals maxConcurrent, 2
        -- aborted after the first pass: neither 1000-step download finished
        ut\assertEquals dl.status, Status.Cancelled for dl in *dm.downloads

      -- Finish event listeners fire on completion and may mark the download failed
      -- (the mechanism SHA-1 verification rides on)

      finishEvent_canMarkFailed: (ut) ->
        dm = fakeManager makeFakeDriver 1, {}
        dl = dm\addDownload "http://x/1", "#{basePath}_fin"
        fired = false
        dl\on Downloader.Download.Event.Finish, (d) ->
          fired = true
          d\markFailed "verification failed"
        dm\await!
        ut\assertTrue fired
        ut\assertEquals dl.error, "verification failed"
        ut\assertEquals dl.status, Status.Failed

      -- on/off: a removed listener no longer fires

      on_off: (ut) ->
        dl = Downloader.Download "http://x/1", "#{basePath}_o", 1
        count = 0
        cb = (d) -> count += 1
        dl\on Downloader.Download.Event.Progress, cb
        dl\_notifyProgress!
        dl\off Downloader.Download.Event.Progress, cb
        dl\_notifyProgress!
        ut\assertEquals count, 1

      on_rejectsUnknownEvent: (ut) ->
        dl = Downloader.Download "http://x/1", "#{basePath}_u", 1
        ut\assertError -> dl\on "notAnEvent", ->

      -- addDownload sha1: a matching hash leaves no error; a mismatch records one

      addDownload_sha1Verifies: (ut) ->
        path = "#{basePath}_sha1ok.txt"
        handle = io.open path, "wb"
        handle\write "abc"
        handle\close!
        dm = fakeManager makeFakeDriver 1, {}
        dl = dm\addDownload "http://x/1", path, "a9993e364706816aba3e25717850c26c9cd0d89d"
        dm\await!
        os.remove path
        ut\assertNil dl.error
        ut\assertEquals dl.status, Status.Finished

      addDownload_sha1Mismatch: (ut) ->
        path = "#{basePath}_sha1bad.txt"
        handle = io.open path, "wb"
        handle\write "abc"
        handle\close!
        dm = fakeManager makeFakeDriver 1, {}
        dl = dm\addDownload "http://x/1", path, ("0")\rep 40
        dm\await!
        os.remove path
        ut\assertString dl.error
        ut\assertEquals dl.status, Status.Failed

      -- Downloader-level events: Progress fires during, Finished fires after await

      downloaderEvents: (ut) ->
        dm = fakeManager makeFakeDriver 2, {}
        dm\addDownload "http://x/1", "#{basePath}_de"
        progressCount, finished = 0, false
        dm\on Downloader.Event.Progress, (d, percent) -> progressCount += 1
        dm\on Downloader.Event.Finished, (d) -> finished = true
        dm\await!
        ut\assertGreaterThan progressCount, 0
        ut\assertTrue finished

      -- a failed start marks the download Failed with the start error

      runner_recordsStartFailure: (ut) ->
        failingDriver = {
          start: (dl) -> false, "boom"
          step: (dl) -> "done"
          finish: (dl) -> nil
        }
        dm = Downloader (mgr) -> Downloader.multiplex mgr, failingDriver
        dm\addDownload "http://x/1", "#{basePath}_f1"
        dm\await!
        ut\assertEquals dm.downloads[1].error, "boom"
        ut\assertEquals dm.downloads[1].status, Status.Failed

      -- a single download can be cancelled mid-flight without affecting the others

      individualCancel: (ut) ->
        order = {}
        dm = fakeManager makeFakeDriver 3, order
        dl1 = dm\addDownload "http://x/1", "#{basePath}_ic1"
        dl2 = dm\addDownload "http://x/2", "#{basePath}_ic2"
        dm\on Downloader.Event.Progress, -> dl1\cancel!   -- cancel dl1 once it's underway
        dm\await!
        ut\assertEquals dl1.status, Status.Cancelled
        ut\assertEquals dl2.status, Status.Finished

      -- addDownload queueing and validation

      addDownload_queues: (ut) ->
        dm = Downloader!
        dl = dm\addDownload "https://example.com/x", "#{basePath}_dl.txt"
        ut\assertEquals dl.url, "https://example.com/x"
        ut\assertEquals #dm.downloads, 1

      addDownload_badArgs: (ut) ->
        dl, err = Downloader!\addDownload nil, nil
        ut\assertNil dl
        ut\assertString err

      -- clear empties the arrays in place (external references stay valid)

      clear_emptiesInPlace: (ut) ->
        dm = Downloader!
        downloadsRef = dm.downloads
        dm\addDownload "http://x/1", "#{basePath}_cl"
        dm\clear!
        ut\assertEquals #dm.downloads, 0
        ut\assertIs dm.downloads, downloadsRef   -- same table, emptied in place

      _order: {
        "roundRobin_interleaves", "roundRobin_detectsConcurrencyThenCancels",
        "finishEvent_canMarkFailed", "on_off", "on_rejectsUnknownEvent",
        "addDownload_sha1Verifies", "addDownload_sha1Mismatch",
        "downloaderEvents",
        "runner_recordsStartFailure", "individualCancel",
        "addDownload_queues", "addDownload_badArgs",
        "clear_emptiesInPlace"
      }
    }

    Common: {
      _description: "Tests for the Common base class providing shared utilities and enums across DependencyControl components."

      capitalizeTerms: (ut) ->
        ut\assertEquals DepCtrl.terms.capitalize("hello world"), "Hello world"

      -- validateNamespace: pure computation, no stubs needed

      validateNamespace_valid: (ut) ->
        result, err = Common.validateNamespace "l0.DependencyControl"
        ut\assertTrue result
        ut\assertNil err

      validateNamespace_multiPart: (ut) ->
        result, err = Common.validateNamespace "a.b.c"
        ut\assertTrue result
        ut\assertNil err

      validateNamespace_noDot: (ut) ->
        result, err = Common.validateNamespace "no-dot"
        ut\assertFalse result
        ut\assertString err

      validateNamespace_leadingDot: (ut) ->
        result, err = Common.validateNamespace ".foo.bar"
        ut\assertFalse result
        ut\assertString err

      validateNamespace_trailingDot: (ut) ->
        result, err = Common.validateNamespace "foo.bar."
        ut\assertFalse result
        ut\assertString err

      validateNamespace_invalidChars: (ut) ->
        result, err = Common.validateNamespace "foo bar.baz"
        ut\assertFalse result
        ut\assertString err

      validateNamespace_consecutiveDots: (ut) ->
        result, err = Common.validateNamespace "foo..bar"
        ut\assertFalse result
        ut\assertString err

      _order: {
        "capitalizeTerms",
        "validateNamespace_valid", "validateNamespace_multiPart",
        "validateNamespace_noDot", "validateNamespace_leadingDot",
        "validateNamespace_trailingDot", "validateNamespace_invalidChars",
        "validateNamespace_consecutiveDots"
      }
    }

    CommonExtra: (controls\requireTest "Common") basePath

    FileOps: {
      _description: "Tests for FileOps path validation and filesystem utilities."

      -- validateFullPath: pure computation, no stubs needed

      validateFullPath_nonString: (ut) ->
        result, err = FileOps.validateFullPath 42
        ut\assertNil result
        ut\assertString err

      validateFullPath_parentDir: (ut) ->
        -- ".." is now resolved rather than rejected
        result = FileOps.validateFullPath {basePath, "..", "escape.txt"}
        ut\assertString result  -- resolves to parent dir + escape.txt

      validateFullPath_tooLong: (ut) ->
        -- exceed the full-path limit on every platform/config (well past the ~32k
        -- long-path-enabled Windows limit) while keeping each component within bounds
        segments = [string.rep "a", 200 for _ = 1, 200]
        result = FileOps.validateFullPath {basePath, segments}
        ut\assertNil result

      validateFullPath_segmentTooLong: (ut) ->
        -- a single component over the per-segment limit is rejected even when the overall
        -- path fits the length limit (raise the length cap so the segment check is reached)
        result, err = withPathLimits 32767, false, false, ->
          FileOps.validateFullPath {basePath, "#{string.rep 'a', 300}.txt"}
        ut\assertNil result
        ut\assertContains err, "path component"

      -- detected, platform-specific path limits
      pathLimits_detected: (ut) ->
        ut\assertEquals FileOps.pathMaxSegmentLength, 255
        if isWindows
          -- 260 (capped) or 32767 (long paths available to this process)
          ut\assertTrue FileOps.pathMaxLength == 260 or FileOps.pathMaxLength == 32767
          ut\assertBoolean FileOps.longPathsDisabled
        else
          ut\assertEquals FileOps.pathMaxLength, 4096
          ut\assertFalse FileOps.longPathsDisabled

      -- "path too long" diagnostic selection (field-driven via withPathLimits, runs on any OS)
      validateFullPath_tooLong_generic: (ut) ->
        -- non-Windows / long paths available: plain limit message, no Windows-specific guidance
        result, err = withPathLimits 260, false, false, ->
          FileOps.validateFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
        ut\assertNil result
        ut\assertContains err, "maximum length limit"

      validateFullPath_tooLong_registryDisabled: (ut) ->
        -- Windows, long paths off system-wide: error explains how to enable the registry key
        result, err = withPathLimits 260, true, false, ->
          FileOps.validateFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
        ut\assertNil result
        ut\assertContains err, "LongPathsEnabled"

      validateFullPath_tooLong_processUnaware: (ut) ->
        -- Windows, registry on but app not long-path-aware: error explains the manifest cap
        result, err = withPathLimits 260, true, true, ->
          FileOps.validateFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
        ut\assertNil result
        ut\assertContains err, "long-path-aware"

      validateFullPath_invalidChars: (ut) ->
        return unless isWindows
        result = FileOps.validateFullPath {basePath, "with<invalid>.txt"}
        ut\assertNil result

      validateFullPath_reservedNames: (ut) ->
        return unless isWindows
        result = FileOps.validateFullPath {basePath, "CON", "file.txt"}
        ut\assertNil result

      validateFullPath_reservedNameWithExt: (ut) ->
        return unless isWindows
        result = FileOps.validateFullPath {basePath, "NUL.txt"}
        ut\assertNil result

      validateFullPath_trailingDotSegment: (ut) ->
        result = FileOps.validateFullPath {basePath, "trailingdot.", "file.txt"}
        ut\assertNil result

      validateFullPath_valid: (ut) ->
        path, dev, dir, file = FileOps.validateFullPath {basePath, "file.txt"}
        ut\assertString path
        ut\assertString dev
        ut\assertEquals file, "file.txt"

      validateFullPath_noExt_rejected: (ut) ->
        result = FileOps.validateFullPath {basePath, "no-ext"}, true
        ut\assertFalse result

      validateFullPath_withExt_accepted: (ut) ->
        result = FileOps.validateFullPath {basePath, "file.txt"}, true
        ut\assertString result

      validateFullPath_homeDirExpansion: (ut) ->
        return if isWindows
        home = os.getenv "HOME"
        return unless home
        result = FileOps.validateFullPath {"~", "subdir", "file.txt"}
        ut\assertString result
        ut\assertContains result, home

      validateFullPath_reservedNameNonWindows: (ut) ->
        return if isWindows
        result = FileOps.validateFullPath {basePath, "NUL", "file.txt"}
        ut\assertString result

      -- getNamespacedPath: pure computation, no stubs needed

      getNamespacedPath_nested: (ut) ->
        path, err = FileOps.getNamespacedPath basePath, "l0.DependencyControl.Test", ".lua"
        ut\assertNil err
        ut\assertString path
        ut\assertContains path, FileOps.joinPath "l0", "DependencyControl", "Test.lua"

      getNamespacedPath_flat: (ut) ->
        path, err = FileOps.getNamespacedPath basePath, "l0.DependencyControl", ".lua", false
        ut\assertNil err
        ut\assertString path
        ut\assertContains path, "l0.DependencyControl.lua"

      getNamespacedPath_badNamespace: (ut) ->
        path, err = FileOps.getNamespacedPath basePath, "not-a-namespace", ".lua"
        ut\assertNil path
        ut\assertString err

      getNamespacedPath_badBasePath: (ut) ->
        path, err = FileOps.getNamespacedPath {"relative", "path"}, "l0.DependencyControl", ".lua"
        ut\assertNil path
        ut\assertString err

      -- attributes: stubs lfs.attributes
      -- lfs.attributes(path, key) returns (value) on success, (nil) when not found,
      -- or (nil, errmsg) on error. FileOps.attributes maps these to value/false/nil.

      attributes_file: (ut) ->
        attrStub = (ut\stub lfs, "attributes")\calls (path, key) -> "file"
        mode, fullPath = FileOps.attributes {basePath, "file.txt"}, "mode"
        ut\assertEquals mode, "file"
        ut\assertString fullPath
        attrStub\assertCalledOnceWith FileOps.joinPath(basePath, "file.txt"), "mode"

      attributes_notFound: (ut) ->
        attrStub = (ut\stub lfs, "attributes")\calls (path, key) -> nil
        mode, fullPath = FileOps.attributes {basePath, "missing.txt"}, "mode"
        ut\assertFalse mode
        ut\assertString fullPath
        attrStub\assertCalledOnceWith FileOps.joinPath(basePath, "missing.txt"), "mode"

      -- joinPath: pure computation, no stubs needed

      joinPath_segmentsArray: (ut) ->
        result = FileOps.joinPath {"path", "to", "file.txt"}
        ut\assertEquals result, "path#{pathSep}to#{pathSep}file.txt"

      joinPath_segmentsVarargs: (ut) ->
        result = FileOps.joinPath "path", "to", "file.txt"
        ut\assertEquals result, "path#{pathSep}to#{pathSep}file.txt"

      joinPath_segmentsMixed: (ut) ->
        result = FileOps.joinPath {"path", "to"}, "file.txt"
        ut\assertEquals result, "path#{pathSep}to#{pathSep}file.txt"

      -- mkdir: stubs lfs.attributes + lfs.mkdir

      mkdir_new: (ut) ->
        (ut\stub lfs, "attributes")\calls (path, key) -> nil
        mkdirStub = (ut\stub lfs, "mkdir")\calls (path) -> true
        result, path = FileOps.mkdir {basePath, "newdir"}
        ut\assertTrue result
        ut\assertString path
        mkdirStub\assertCalledOnce!

      mkdir_exists: (ut) ->
        (ut\stub lfs, "attributes")\calls (path, key) -> "directory"
        result, dir = FileOps.mkdir {basePath, "existing"}
        ut\assertFalse result
        ut\assertString dir

      -- readFile: stubs lfs.attributes + io.open

      readFile_success: (ut) ->
        filePath = FileOps.joinPath basePath, "file.txt"
        content  = "hello, DependencyControl"
        mockHandle = {
          read: (handle, fmt) -> content
          close: (handle) ->
        }
        (ut\stub lfs, "attributes")\calls (path, key) -> "file"
        openStub = (ut\stub io, "open")\calls (path, mode) -> mockHandle
        data, err = FileOps.readFile filePath
        ut\assertEquals data, content
        ut\assertNil err
        openStub\assertCalledOnceWith filePath, "rb"

      readFile_isDirectory: (ut) ->
        (ut\stub lfs, "attributes")\calls (path, key) -> "directory"
        data, err = FileOps.readFile {basePath, "dir"}
        ut\assertNil data
        ut\assertString err

      -- getHash / verifyHash: stub readFile so the hash is computed over known content

      getHash_sha1: (ut) ->
        (ut\stub FILEOPS_MODULE_NAME, "readFile")\returns "abc"
        ut\assertEquals FileOps.getHash("/path/file", "sha1"),
                        "a9993e364706816aba3e25717850c26c9cd0d89d"

      getHash_defaultsToSha1: (ut) ->
        (ut\stub FILEOPS_MODULE_NAME, "readFile")\returns "abc"
        ut\assertEquals FileOps.getHash("/path/file"),
                        "a9993e364706816aba3e25717850c26c9cd0d89d"

      getHash_unsupportedType: (ut) ->
        hash, err = FileOps.getHash "/path/file", "md5"
        ut\assertNil hash
        ut\assertString err

      verifyHash_match: (ut) ->
        (ut\stub FILEOPS_MODULE_NAME, "readFile")\returns "abc"
        ut\assertTrue FileOps.verifyHash "/path/file", "A9993E364706816ABA3E25717850C26C9CD0D89D", "sha1"

      verifyHash_mismatch: (ut) ->
        (ut\stub FILEOPS_MODULE_NAME, "readFile")\returns "abc"
        ok, err = FileOps.verifyHash "/path/file", ("0")\rep(40), "sha1"
        ut\assertFalse ok
        ut\assertString err

      verifyHash_badArg: (ut) ->
        ok, err = FileOps.verifyHash "/path/file", nil
        ut\assertNil ok
        ut\assertString err

      -- copy: stubs lfs.attributes + io.open

      copy_success: (ut) ->
        srcPath = FileOps.joinPath basePath, "src.txt"
        dstPath = FileOps.joinPath basePath, "dst.txt"
        mockIn  = {
          read:  (handle, fmt)  -> "content"
          close: (handle)       ->
        }
        mockOut = {
          write: (handle, data) -> true
          close: (handle)       ->
        }
        (ut\stub lfs, "attributes")\calls (path, key) ->
          if path == srcPath then "file" else nil
        ioStub = (ut\stub io, "open")\calls (path, mode) ->
          if mode == "rb" then mockIn else mockOut
        result, err = FileOps.copy srcPath, dstPath
        ioStub\assertCalledTimes 2
        ioStub\assertNthCalledWith 1, srcPath, "rb"
        ioStub\assertNthCalledWith 2, dstPath, "wb"
        ut\assertTrue result
        ut\assertNil err

      copy_targetExists: (ut) ->
        (ut\stub lfs, "attributes")\calls (path, key) -> "file"
        result, err = FileOps.copy {basePath, "src.txt"}, {basePath, "dst.txt"}
        ut\assertFalse result
        ut\assertString err

      -- move: stubs lfs.attributes + os.remove + os.rename

      move_overwrite: (ut) ->
        srcPath = FileOps.joinPath basePath, "src.txt"
        dstPath = FileOps.joinPath basePath, "dst.txt"
        (ut\stub lfs, "attributes")\calls (path, key) -> "file"
        removeStub = (ut\stub os, "remove")\returns true
        renameStub = (ut\stub os, "rename")\returns true
        result, err = FileOps.move srcPath, dstPath, true
        ut\assertTrue result
        ut\assertNil err
        removeStub\assertCalledOnceWith dstPath
        renameStub\assertCalledOnceWith srcPath, dstPath

      -- remove: stubs lfs.attributes + os.remove

      remove_success: (ut) ->
        filePath = FileOps.joinPath basePath, "file.txt"
        (ut\stub lfs, "attributes")\calls (path, key) -> "file"
        removeStub = (ut\stub os, "remove")\returns true
        result, details = FileOps.remove filePath
        ut\assertTrue result
        removeStub\assertCalledOnceWith filePath

      remove_notFound: (ut) ->
        (ut\stub lfs, "attributes")\calls (path, key) -> nil
        result, details = FileOps.remove FileOps.joinPath basePath, "missing.txt"
        ut\assertTrue result
        ut\assertTable details

      _order: {
        "validateFullPath_nonString", "validateFullPath_parentDir", "validateFullPath_tooLong",
        "validateFullPath_segmentTooLong", "pathLimits_detected",
        "validateFullPath_tooLong_generic", "validateFullPath_tooLong_registryDisabled",
        "validateFullPath_tooLong_processUnaware",
        "validateFullPath_invalidChars", "validateFullPath_reservedNames",
        "validateFullPath_reservedNameWithExt", "validateFullPath_trailingDotSegment",
        "validateFullPath_valid", "validateFullPath_noExt_rejected", "validateFullPath_withExt_accepted",
        "validateFullPath_homeDirExpansion", "validateFullPath_reservedNameNonWindows",
        "getNamespacedPath_nested", "getNamespacedPath_flat",
        "getNamespacedPath_badNamespace", "getNamespacedPath_badBasePath",
        "attributes_file", "attributes_notFound",
        "mkdir_new", "mkdir_exists",
        "readFile_success", "readFile_isDirectory",
        "getHash_sha1", "getHash_defaultsToSha1", "getHash_unsupportedType",
        "verifyHash_match", "verifyHash_mismatch", "verifyHash_badArg",
        "copy_success", "copy_targetExists",
        "move_overwrite",
        "remove_success", "remove_notFound"
      }
    }

    FileOpsExtra: (controls\requireTest "FileOps") basePath, isWindows


    Logger: {
      _description: "Tests for the Logger class covering message formatting, dump serialization, and log dispatch."

      -- format: pure computation, no stubs needed

      format_string: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\format "hello world", 0
        ut\assertEquals result, "hello world"

      format_printf: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\format "value: %d", 0, 42
        ut\assertEquals result, "value: 42"

      format_table: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\format {"line1", "line2"}, 0
        ut\assertEquals result, "line1\nline2"

      format_indent: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\format "line1\nline2", 1
        ut\assertContains result, "— line2"

      -- dumpToString: pure computation, no stubs needed

      dumpToString_scalar: (ut) ->
        logger = Logger toFile: false, toWindow: false
        ut\assertEquals logger\dumpToString("hello"), "hello"
        ut\assertEquals logger\dumpToString(42), "42"
        ut\assertEquals logger\dumpToString(true), "true"

      dumpToString_flatTable: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\dumpToString {key: "val"}
        ut\assertContains result, "key:"
        ut\assertContains result, "val"

      dumpToString_ignoreKey: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\dumpToString {keep: "yes", skip: "no"}, "skip"
        ut\assertContains result, "keep:"
        ut\assertNil result\find "skip:", 1, true

      dumpToString_maxDepth: (ut) ->
        logger = Logger toFile: false, toWindow: false
        nested = {inner: {deep: "value"}}
        result = logger\dumpToString nested, nil, 0
        ut\assertContains result, "<...>"

      dumpToString_circular: (ut) ->
        logger = Logger toFile: false, toWindow: false
        t = {}
        t.self = t
        result = logger\dumpToString t
        ut\assertContains result, "self: @1"

      -- log/dispatch: stubs aegisub.log

      log_dispatches: (ut) ->
        logger = Logger toFile: false, toWindow: true
        logStub = ut\stub aegisub, "log"
        result = logger\log 2, "hello"
        ut\assertTrue result
        logStub\assertCalledOnce!

      log_emptyMsg: (ut) ->
        logger = Logger toFile: false, toWindow: true
        logStub = ut\stub aegisub, "log"
        result = logger\log 2, ""
        ut\assertFalse result
        logStub\assertNotCalled!

      log_nonNumberLevel: (ut) ->
        logger = Logger toFile: false, toWindow: true
        logStub = ut\stub aegisub, "log"
        result = logger\log "hello"
        ut\assertTrue result
        logStub\assertCalledOnce!

      -- assert/assertNotNil: success path returns values, failure path throws

      assert_truthy: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result, extra = logger\assert true, "should not log"
        ut\assertTrue result
        ut\assertEquals extra, "should not log"

      assert_falsy: (ut) ->
        logger = Logger toFile: false, toWindow: false
        ok, err = pcall -> logger\assert false, "boom"
        ut\assertFalse ok
        ut\assertString err

      assertNotNil_value: (ut) ->
        logger = Logger toFile: false, toWindow: false
        result = logger\assertNotNil 0, "should not log"
        ut\assertEquals result, 0

      assertNotNil_nil: (ut) ->
        logger = Logger toFile: false, toWindow: false
        ok, err = pcall -> logger\assertNotNil nil, "boom"
        ut\assertFalse ok
        ut\assertString err

      _order: {
        "format_string", "format_printf", "format_table", "format_indent",
        "dumpToString_scalar", "dumpToString_flatTable", "dumpToString_ignoreKey",
        "dumpToString_maxDepth", "dumpToString_circular",
        "log_dispatches", "log_emptyMsg", "log_nonNumberLevel",
        "assert_truthy", "assert_falsy",
        "assertNotNil_value", "assertNotNil_nil"
      }
    }

    Enum: {
      _description: "Tests for the Enum class providing immutable enumeration types with reverse lookup."

      -- construction

      new_table: (ut) ->
        e = Enum "MyEnum", {Foo: 1, Bar: 2}
        ut\assertEquals e.Foo, 1
        ut\assertEquals e.Bar, 2

      new_list: (ut) ->
        e = Enum "MyEnum", {"Foo", "Bar"}
        found = e\test "Foo"
        ut\assertTrue found

      new_badName: (ut) ->
        ok, err = pcall -> Enum 42, {Foo: 1}
        ut\assertFalse ok
        ut\assertString err

      new_reservedKey: (ut) ->
        ok, err = pcall -> Enum "MyEnum", {keys: 1}
        ut\assertFalse ok
        ut\assertString err

      new_duplicateValue: (ut) ->
        ok, err = pcall -> Enum "MyEnum", {Foo: 1, Bar: 1}
        ut\assertFalse ok
        ut\assertString err

      -- test

      test_found: (ut) ->
        e = Enum "MyEnum", {Foo: 1, Bar: 2}
        found, val = e\test "Foo"
        ut\assertTrue found
        ut\assertEquals val, 1

      test_notFound: (ut) ->
        e = Enum "MyEnum", {Foo: 1}
        found, val = e\test "Baz"
        ut\assertFalse found
        ut\assertNil val

      -- describe

      describe_single: (ut) ->
        e = Enum "MyEnum", {Foo: 1, Bar: 2}
        result = e\describe 1
        ut\assertEquals result, "Foo"

      describe_list: (ut) ->
        e = Enum "MyEnum", {Foo: 1, Bar: 2}
        result = e\describe {1, 2}
        ut\assertTable result
        ut\assertEquals #result, 2

      describe_join: (ut) ->
        e = Enum "MyEnum", {Foo: 1, Bar: 2}
        result = e\describe {1, 2}, true
        ut\assertString result
        ut\assertContains result, "Foo"
        ut\assertContains result, "Bar"

      describe_unknown: (ut) ->
        e = Enum "MyEnum", {Foo: 1}
        result, err = e\describe 99
        ut\assertNil result
        ut\assertContains err, "MyEnum"
        ut\assertContains err, "99"

      -- validate

      validate_valid: (ut) ->
        e = Enum "MyEnum", {Foo: 1, Bar: 2}
        result, err = e\validate 1
        ut\assertTrue result
        ut\assertNil err

      validate_invalid: (ut) ->
        e = Enum "MyEnum", {Foo: 1}
        result, err = e\validate 99
        ut\assertNil result
        ut\assertString err

      validate_withArgName: (ut) ->
        e = Enum "MyEnum", {Foo: 1}
        result, err = e\validate 99, "myArg"
        ut\assertNil result
        ut\assertContains err, "myArg"

      -- immutability

      immutable_read: (ut) ->
        e = Enum "MyEnum", {Foo: 1}
        ok, err = pcall -> e.Bar
        ut\assertFalse ok
        ut\assertString err

      immutable_write: (ut) ->
        e = Enum "MyEnum", {Foo: 1}
        ok, err = pcall -> e.Foo = 99
        ut\assertFalse ok
        ut\assertString err

      _order: {
        "new_table", "new_list", "new_badName", "new_reservedKey", "new_duplicateValue",
        "test_found", "test_notFound",
        "describe_single", "describe_list", "describe_join", "describe_unknown",
        "validate_valid", "validate_invalid", "validate_withArgName",
        "immutable_read", "immutable_write"
      }
    }

    SemanticVersioning: {
      _description: "Tests for SemanticVersioning covering toNumber, toString, and check."

      -- toNumber

      toNumber_string: (ut) ->
        result, err = SemanticVersioning\toNumber "1.2.3"
        ut\assertEquals result, 66051
        ut\assertNil err

      toNumber_zero: (ut) ->
        result, err = SemanticVersioning\toNumber "0.0.0"
        ut\assertEquals result, 0
        ut\assertNil err

      toNumber_number: (ut) ->
        result = SemanticVersioning\toNumber 66051
        ut\assertEquals result, 66051

      toNumber_nil: (ut) ->
        result = SemanticVersioning\toNumber nil
        ut\assertEquals result, 0

      toNumber_badString: (ut) ->
        result, err = SemanticVersioning\toNumber "1.2"
        ut\assertFalse result
        ut\assertString err

      toNumber_overflow: (ut) ->
        result, err = SemanticVersioning\toNumber "1.256.0"
        ut\assertFalse result
        ut\assertString err

      toNumber_badType: (ut) ->
        result, err = SemanticVersioning\toNumber {}
        ut\assertFalse result
        ut\assertString err

      -- toString

      toString_fromNumber: (ut) ->
        result, err = SemanticVersioning\toString 66051
        ut\assertEquals result, "1.2.3"
        ut\assertNil err

      toString_roundtrip: (ut) ->
        result, err = SemanticVersioning\toString "1.2.3"
        ut\assertEquals result, "1.2.3"
        ut\assertNil err

      toString_majorPrecision: (ut) ->
        result = SemanticVersioning\toString 66051, "major"
        ut\assertEquals result, "1.0.0"

      -- check

      check_equal: (ut) ->
        result, b = SemanticVersioning\check "1.2.3", "1.2.3"
        ut\assertTrue result

      check_greater: (ut) ->
        result = SemanticVersioning\check "2.0.0", "1.0.0"
        ut\assertTrue result

      check_less: (ut) ->
        result = SemanticVersioning\check "1.0.0", "2.0.0"
        ut\assertFalse result

      check_majorPrecision: (ut) ->
        result = SemanticVersioning\check "2.0.0", "1.9.9", "major"
        ut\assertTrue result

      check_badArg: (ut) ->
        result, err = SemanticVersioning\check "bad", "1.0.0"
        ut\assertNil result
        ut\assertString err

      _order: {
        "toNumber_string", "toNumber_zero", "toNumber_number", "toNumber_nil",
        "toNumber_badString", "toNumber_overflow", "toNumber_badType",
        "toString_fromNumber", "toString_roundtrip", "toString_majorPrecision",
        "check_equal", "check_greater", "check_less", "check_majorPrecision", "check_badArg"
      }
    }

    Lock: {
      _description: "Tests for the Lock cooperative mutex class."

      -- LockState enum: verifies Enum was called with "LockState" and the correct value mapping

      lockState_values: (ut) ->
        ut\assertEquals Lock.LockState.Unknown, -1
        ut\assertEquals Lock.LockState.Unavailable, 0
        ut\assertEquals Lock.LockState.Available, 1
        ut\assertEquals Lock.LockState.Held, 2

      lockState_name: (ut) ->
        found, val = Lock.LockState\test "Held"
        ut\assertTrue found
        ut\assertEquals val, 2

      -- class-level Logger: verifies Logger was constructed with the correct fileBaseName

      classLogger_fileBaseName: (ut) ->
        ut\assertEquals Lock.logger.fileBaseName, "DependencyControl.Lock"

      -- constructor

      new_defaults: (ut) ->
        lock = Lock namespace: "ns", resource: "res"
        ut\assertEquals lock.namespace, "ns"
        ut\assertEquals lock.resource, "res"
        ut\assertEquals lock.holderName, "unknown"
        ut\assertEquals lock.expiresAfter, 300
        ut\assertString lock.instanceId

      new_customLogger: (ut) ->
        customLogger = Logger toFile: false, toWindow: false
        lock = Lock namespace: "ns", resource: "res", logger: customLogger
        ut\assertEquals lock.logger, customLogger

      -- getState

      getState_initial: (ut) ->
        lock = Lock namespace: "ns", resource: "res"
        ut\assertEquals lock\getState!, Lock.LockState.Unknown

      getState_held: (ut) ->
        (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns true
        ut\stub BADMUTEX_MODULE_NAME, "unlock"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        lock\lock!
        ut\assertEquals lock\getState!, Lock.LockState.Held
        lock\release!

      -- lock

      lock_success: (ut) ->
        tryLockStub = (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns true
        ut\stub BADMUTEX_MODULE_NAME, "unlock"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        state, timePassed = lock\lock!
        ut\assertEquals state, Lock.LockState.Held
        ut\assertEquals timePassed, 0
        tryLockStub\assertCalledOnce!
        lock\release!

      lock_alreadyHeld: (ut) ->
        tryLockStub = (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns true
        ut\stub BADMUTEX_MODULE_NAME, "unlock"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        lock\lock!                          -- acquire
        state, timePassed = lock\lock!      -- re-enter: already held path
        ut\assertEquals state, Lock.LockState.Held
        tryLockStub\assertCalledOnce!       -- mutex not re-acquired on second call
        lock\release!

      lock_timeout: (ut) ->
        tryLockStub = (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns false
        sleepStub   = ut\stub TIMER_MODULE_NAME, "sleep"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        state, timePassed = lock\lock 0
        ut\assertEquals state, Lock.LockState.Unavailable
        tryLockStub\assertCalledOnce!
        sleepStub\assertNotCalled!          -- timeout=0 suppresses sleep

      lock_retry: (ut) ->
        callCount   = 0
        tryLockStub = (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\calls ->
          callCount += 1
          callCount >= 2                    -- fails first, succeeds second
        sleepStub = ut\stub TIMER_MODULE_NAME, "sleep"
        ut\stub BADMUTEX_MODULE_NAME, "unlock"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        state, timePassed = lock\lock!
        ut\assertEquals state, Lock.LockState.Held
        tryLockStub\assertCalledTimes 2
        sleepStub\assertCalledOnceWith 250  -- default lockWaitInterval
        lock\release!

      -- tryLock

      tryLock_success: (ut) ->
        tryLockStub = (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns true
        ut\stub BADMUTEX_MODULE_NAME, "unlock"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        state, timePassed = lock\tryLock!
        ut\assertEquals state, Lock.LockState.Held
        tryLockStub\assertCalledOnce!
        lock\release!

      tryLock_fail: (ut) ->
        tryLockStub = (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns false
        ut\stub TIMER_MODULE_NAME, "sleep"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        state, timePassed = lock\tryLock!
        ut\assertEquals state, Lock.LockState.Unavailable
        tryLockStub\assertCalledOnce!

      -- release

      release_held: (ut) ->
        (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns true
        unlockStub = ut\stub BADMUTEX_MODULE_NAME, "unlock"
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        lock\lock!
        result, extra = lock\release!
        ut\assertTrue result
        ut\assertEquals extra, Lock.LockState.Available
        unlockStub\assertCalledOnce!

      release_notHeld: (ut) ->
        ut\stub Lock.logger, "trace"
        lock = Lock namespace: "ns", resource: "res"
        result, err = lock\release!
        ut\assertNil result
        ut\assertString err
        ut\assertContains err, "not currently held"

      -- GC canary: unreleased lock is cleaned up and warns on collection

      gc_canary: (ut) ->
        (ut\stub BADMUTEX_MODULE_NAME, "tryLock")\returns true
        unlockStub = ut\stub BADMUTEX_MODULE_NAME, "unlock"
        warnStub   = ut\stub Lock.logger, "warn"
        ut\stub Lock.logger, "trace"
        do
          lock = Lock namespace: "ns", resource: "res"
          lock\lock!
        collectgarbage "collect"
        collectgarbage "collect"  -- second pass needed for __gc finalizers
        warnStub\assertCalledOnce!
        unlockStub\assertCalledOnce!

      _order: {
        "lockState_values", "lockState_name",
        "classLogger_fileBaseName",
        "new_defaults", "new_customLogger",
        "getState_initial", "getState_held",
        "lock_success", "lock_alreadyHeld", "lock_timeout", "lock_retry",
        "tryLock_success", "tryLock_fail",
        "release_held", "release_notHeld",
        "gc_canary"
      }
    }

    ConfigHandler: {
      _description: "Tests for the ConfigHandler JSON-backed config manager."

      -- getSerializableCopy: pure static method, no stubs needed

      getSerializableCopy_simple: (ut) ->
        result = ConfigHandler\getSerializableCopy {a: 1, b: "hello"}
        ut\assertEquals result.a, 1
        ut\assertEquals result.b, "hello"

      getSerializableCopy_privateKeys: (ut) ->
        result = ConfigHandler\getSerializableCopy {pub: 1, _priv: 2}
        ut\assertEquals result.pub, 1
        ut\assertNil result._priv

      getSerializableCopy_nested: (ut) ->
        result = ConfigHandler\getSerializableCopy {outer: {inner: 1, _skip: 2}}
        ut\assertEquals result.outer.inner, 1
        ut\assertNil result.outer._skip

      getSerializableCopy_circular: (ut) ->
        t = {a: 1}
        t.self = t
        result = ConfigHandler\getSerializableCopy t
        ut\assertEquals result.a, 1
        ut\assertEquals type(result.self), "table"
        ut\assertNil result.self.a  -- circular ref becomes empty table

      -- new

      new_noPath: (ut) ->
        handler = ConfigHandler nil
        ut\assertNil handler.filePath
        ut\assertNil handler.lock
        ut\assertEquals type(handler.config), "table"

      new_withPath: (ut) ->
        validateStub = (ut\stub FILEOPS_MODULE_NAME, "validateFullPath")\calls (path) -> path, nil
        handler = ConfigHandler "/config/test.json"
        ut\assertEquals handler.filePath, "/config/test.json"
        ut\assertNotNil handler.lock
        validateStub\assertCalledOnceWith "/config/test.json", true

      new_badPath: (ut) ->
        (ut\stub FILEOPS_MODULE_NAME, "validateFullPath")\returns nil, "invalid path"
        ok, err = pcall -> ConfigHandler "/bad/path.json"
        ut\assertFalse ok

      -- getHive: exercises traverseHive + mergeHive internally

      getHive_exists: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {key: "value"}}
        hive, err = handler\getHive {"section"}
        ut\assertNil err
        ut\assertEquals hive.key, "value"

      getHive_missing: (ut) ->
        handler = ConfigHandler nil
        hive, err = handler\getHive {"section"}
        ut\assertNil err
        ut\assertEquals type(hive), "table"
        ut\assertEquals type(handler.config.section), "table"  -- path created in config

      getHive_badParent: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: "not_a_table"}
        hive, err = handler\getHive {"section", "child"}
        ut\assertNil hive
        ut\assertString err

      -- getView

      getView_success: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {key: "value"}}
        view, err = handler\getView {"section"}
        ut\assertNil err
        ut\assertNotNil view
        ut\assertEquals view.__hivePath[1], "section"
        ut\assertEquals #view.__hivePath, 1
        ut\assertTrue handler.views[view]

      getView_failure: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: "not_a_table"}
        view, err = handler\getView {"section", "child"}
        ut\assertNil view
        ut\assertString err

      -- getOverlappingViews

      getOverlappingViews_wrongHandler: (ut) ->
        handler1 = ConfigHandler nil
        handler2 = ConfigHandler nil
        view2 = ConfigView handler2, {"section"}
        overlaps, err = handler1\getOverlappingViews view2
        ut\assertNil overlaps
        ut\assertString err

      getOverlappingViews_found: (ut) ->
        handler = ConfigHandler nil
        view1 = ConfigView handler, {"section"}
        view2 = ConfigView handler, {"section", "child"}
        handler.views[view1] = true
        handler.views[view2] = true
        overlaps, err = handler\getOverlappingViews view1
        ut\assertNil err
        ut\assertEquals #overlaps, 1
        ut\assertEquals overlaps[1], view2

      getOverlappingViews_notFound: (ut) ->
        handler = ConfigHandler nil
        view1 = ConfigView handler, {"sectionA"}
        view2 = ConfigView handler, {"sectionB"}
        handler.views[view1] = true
        handler.views[view2] = true
        overlaps, err = handler\getOverlappingViews view1
        ut\assertNil err
        ut\assertEquals #overlaps, 0

      -- load: stubs fileOps.attributes, lock, io.open, json.decode

      load_noFilePath: (ut) ->
        handler = ConfigHandler nil
        result, err = handler\load!
        ut\assertNil result
        ut\assertString err

      load_fileNotFound: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/config/test.json"
        (ut\stub FILEOPS_MODULE_NAME, "attributes")\returns false, "/config/test.json"
        result = handler\load!
        ut\assertTrue result
        ut\assertEquals handler.config, {}

      load_success: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/config/test.json"
        handler.lock = {}
        (ut\stub handler.lock, "lock")\returns Lock.LockState.Held, 0
        ut\stub handler.lock, "release"
        (ut\stub FILEOPS_MODULE_NAME, "attributes")\returns "file", "/config/test.json"
        openStub = (ut\stub io, "open")\calls -> {
          read: (handle, fmt) -> '{"key":"value"}'
          close: (handle) ->
        }
        (ut\stub JSON_MODULE_NAME, "decode")\returns {key: "value"}
        result = handler\load!
        ut\assertTrue result
        ut\assertEquals handler.config.key, "value"
        openStub\assertCalledOnceWith "/config/test.json", "r"

      -- save: stubs fileOps.attributes, lock, io.open, json.encode

      save_noFilePath: (ut) ->
        handler = ConfigHandler nil
        result, err = handler\save!
        ut\assertNil result
        ut\assertString err

      save_lockFailed: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/config/test.json"
        handler.lock = {}
        (ut\stub handler.lock, "lock")\returns Lock.LockState.Unavailable, 0
        result, err = handler\save!
        ut\assertNil result
        ut\assertString err

      save_success: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/config/test.json"
        handler.config = {key: "value"}
        handler.lock = {}
        (ut\stub handler.lock, "lock")\returns Lock.LockState.Held, 0
        ut\stub handler.lock, "release"
        -- readFile sees no existing file, save writes fresh
        (ut\stub FILEOPS_MODULE_NAME, "attributes")\returns false, "/config/test.json"
        writeHandle = {setvbuf: ->, write: ->, flush: ->, close: ->}
        openStub = (ut\stub io, "open")\returns writeHandle
        (ut\stub JSON_MODULE_NAME, "encode")\returns '{"key":"value"}'
        result = handler\save!
        ut\assertTrue result
        openStub\assertCalledOnceWith "/config/test.json", "w"

      -- save with views: exercises mergeHive + cleanHive

      save_withViewMissingHive: (ut) ->
        -- Regression: mirrors the Updater scenario where a virtual module
        -- is installed and its config view is switched from an in-memory
        -- handler (Handler A) to the real file handler (Handler B). Handler B's
        -- @config doesn't yet have this namespace, so mergeHive nils out the
        -- view's path in the freshly-read file config, and cleanHive must
        -- treat that absence as "nothing to purge" instead of crashing.

        -- Handler A: in-memory only, no file backing (virtual module state)
        view = ConfigView\get false, {"section", "key"}
        view.userConfig.someField = "data"

        -- Handler B: real file handler — its in-memory @config knows about
        -- the section (e.g. other modules) but not this view's specific key
        handlerB = ConfigHandler nil
        handlerB.filePath = "/config/test.json"
        handlerB.config = {section: {}}
        handlerB.lock = {}
        (ut\stub handlerB.lock, "lock")\returns Lock.LockState.Held, 0
        ut\stub handlerB.lock, "release"
        (ut\stub FILEOPS_MODULE_NAME, "attributes")\returns false, "/config/test.json"
        (ut\stub io, "open")\returns {setvbuf: ->, write: ->, flush: ->, close: ->}
        (ut\stub JSON_MODULE_NAME, "encode")\returns '{}'

        -- Switch the view from Handler A to Handler B (what setFile does
        -- under the hood after a virtual module has been installed)
        view.__configHandler = handlerB

        result = handlerB\save view
        ut\assertTrue result

      save_withViewPopulatedHive: (ut) ->
        -- Normal path: cleanHive keeps a hive that has data and save succeeds.
        handler = ConfigHandler nil
        handler.filePath = "/config/test.json"
        handler.config = {section: {key: {value: 42}}}
        handler.lock = {}
        (ut\stub handler.lock, "lock")\returns Lock.LockState.Held, 0
        ut\stub handler.lock, "release"
        (ut\stub FILEOPS_MODULE_NAME, "attributes")\returns false, "/config/test.json"
        (ut\stub io, "open")\returns {setvbuf: ->, write: ->, flush: ->, close: ->}
        (ut\stub JSON_MODULE_NAME, "encode")\returns '{}'
        fakeView = {__hivePath: {"section", "key"}, __class: ConfigView}
        result = handler\save fakeView
        ut\assertTrue result

      -- purgeHive

      purgeHive_removesPath: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {key: "value"}, other: {x: 1}}
        view = ConfigView handler, {"section"}
        newHive = handler\purgeHive view
        ut\assertEquals type(newHive), "table"
        ut\assertNil newHive.key            -- original content cleared
        ut\assertEquals handler.config.other.x, 1  -- sibling section untouched

      _order: {
        "getSerializableCopy_simple", "getSerializableCopy_privateKeys",
        "getSerializableCopy_nested", "getSerializableCopy_circular",
        "new_noPath", "new_withPath", "new_badPath",
        "getHive_exists", "getHive_missing", "getHive_badParent",
        "getView_success", "getView_failure",
        "getOverlappingViews_wrongHandler", "getOverlappingViews_found", "getOverlappingViews_notFound",
        "load_noFilePath", "load_fileNotFound", "load_success",
        "save_noFilePath", "save_lockFailed", "save_success",
        "save_withViewMissingHive", "save_withViewPopulatedHive",
        "purgeHive_removesPath"
      }
    }

    ConfigView: {
      _description: "Tests for the ConfigView hive accessor and defaults proxy."

      -- new

      new_orphan: (ut) ->
        view = ConfigView nil, "section"
        ut\assertEquals view.__hivePath[1], "section"
        ut\assertEquals #view.__hivePath, 1
        ut\assertNil view.__configHandler
        ut\assertEquals view.userConfig, {}
        ut\assertNil view.file

      new_withHandler: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/test/config.json"
        handler.config = {section: {key: "value"}}
        view = ConfigView handler, {"section"}
        ut\assertEquals view.__configHandler, handler
        ut\assertEquals view.userConfig.key, "value"
        ut\assertEquals view.file, "/test/config.json"

      new_stringHivePath: (ut) ->
        view = ConfigView nil, "mySection"
        ut\assertEquals view.__hivePath[1], "mySection"
        ut\assertEquals #view.__hivePath, 1

      new_tableHivePath: (ut) ->
        view = ConfigView nil, {"a", "b"}
        ut\assertEquals view.__hivePath[1], "a"
        ut\assertEquals view.__hivePath[2], "b"

      -- isOverlappingView

      isOverlappingView_differentHandler: (ut) ->
        handler1 = ConfigHandler nil
        handler2 = ConfigHandler nil
        view1 = ConfigView handler1, {"section"}
        view2 = ConfigView handler2, {"section"}
        result, err = view1\isOverlappingView view2
        ut\assertNil result
        ut\assertString err

      isOverlappingView_root: (ut) ->
        handler = ConfigHandler nil
        root  = ConfigView handler, {}
        child = ConfigView handler, {"section"}
        ut\assertTrue root\isOverlappingView child

      isOverlappingView_overlap: (ut) ->
        handler = ConfigHandler nil
        parent = ConfigView handler, {"a", "b"}
        child  = ConfigView handler, {"a", "b", "c"}
        ut\assertTrue parent\isOverlappingView child

      isOverlappingView_disjoint: (ut) ->
        handler = ConfigHandler nil
        viewA = ConfigView handler, {"a"}
        viewB = ConfigView handler, {"b"}
        ut\assertFalse viewA\isOverlappingView viewB

      -- config proxy: read/write behavior

      config_readUser: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {key: "userValue"}}
        view = ConfigView handler, {"section"}, {key: "defaultValue"}
        ut\assertEquals view.config.key, "userValue"

      config_readDefault: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {}}
        view = ConfigView handler, {"section"}, {key: "defaultValue"}
        ut\assertEquals view.config.key, "defaultValue"

      config_write: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {}}
        view = ConfigView handler, {"section"}
        view.config.newKey = "written"
        ut\assertEquals view.userConfig.newKey, "written"

      -- refresh: re-links userConfig to handler's current hive table

      refresh_success: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {key: "initial"}}
        view = ConfigView handler, {"section"}
        ut\assertEquals view.userConfig.key, "initial"
        handler.config.section = {key: "updated"}  -- replace table, not just value
        view\refresh!
        ut\assertEquals view.userConfig.key, "updated"

      -- import

      import_simple: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {}}
        view = ConfigView handler, {"section"}
        changesMade = view\import {key: "value", num: 42}
        ut\assertTrue changesMade
        ut\assertEquals view.userConfig.key, "value"
        ut\assertEquals view.userConfig.num, 42

      import_updateOnly: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {existing: "old"}}
        view = ConfigView handler, {"section"}, {existing: "default"}
        view\import {existing: "new", notExisting: "skip"}, nil, true
        ut\assertEquals view.userConfig.existing, "new"
        ut\assertNil view.userConfig.notExisting

      import_skipPrivate: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {}}
        view = ConfigView handler, {"section"}
        view\import {pub: "ok", _priv: "hidden"}
        ut\assertEquals view.userConfig.pub, "ok"
        ut\assertNil view.userConfig._priv

      -- load / save / delete: stub handler methods, verify delegation

      load_noFilePath: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {}}
        view = ConfigView handler, {"section"}
        ut\assertFalse view\load!

      load_delegatesToHandler: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/test/config.json"
        handler.config = {section: {}}
        loadStub = (ut\stub handler, "load")\returns true
        view = ConfigView handler, {"section"}
        result = view\load 500
        ut\assertTrue result
        loadStub\assertCalledOnce!

      save_noFilePath: (ut) ->
        handler = ConfigHandler nil
        handler.config = {section: {}}
        view = ConfigView handler, {"section"}
        ut\assertFalse view\save!

      save_delegatesToHandler: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/test/config.json"
        handler.config = {section: {}}
        saveStub = (ut\stub handler, "save")\returns true
        view = ConfigView handler, {"section"}
        result = view\save 250
        ut\assertTrue result
        saveStub\assertCalledOnce!

      delete_purgesAndSaves: (ut) ->
        handler = ConfigHandler nil
        handler.filePath = "/test/config.json"
        handler.config = {section: {key: "value"}}
        newHive = {}
        purgeStub = (ut\stub handler, "purgeHive")\returns newHive
        saveStub  = (ut\stub handler, "save")\returns true
        view = ConfigView handler, {"section"}
        result = view\delete!
        ut\assertTrue result
        purgeStub\assertCalledOnce!
        saveStub\assertCalledOnce!
        ut\assertEquals view.userConfig, newHive

      _order: {
        "new_orphan", "new_withHandler", "new_stringHivePath", "new_tableHivePath",
        "isOverlappingView_differentHandler", "isOverlappingView_root",
        "isOverlappingView_overlap", "isOverlappingView_disjoint",
        "config_readUser", "config_readDefault", "config_write",
        "refresh_success",
        "import_simple", "import_updateOnly", "import_skipPrivate",
        "load_noFilePath", "load_delegatesToHandler",
        "save_noFilePath", "save_delegatesToHandler",
        "delete_purgesAndSaves"
      }
    }

    ModuleLoader: {
      _description: "Tests for ModuleLoader internal module loading helpers."

      -- formatVersionErrorTemplate: pure computation, uses SemanticVersioning.toString

      formatVersionErrorTemplate_missing_bare: (ut) ->
        result = ModuleLoader.formatVersionErrorTemplate nil, "MyModule", nil, nil, "not found"
        ut\assertString result
        ut\assertContains result, "MyModule"
        ut\assertContains result, "not found"

      formatVersionErrorTemplate_missing_withVersion: (ut) ->
        result = ModuleLoader.formatVersionErrorTemplate nil, "MyModule", "1.0.0", nil, "not found"
        ut\assertContains result, "(v1.0.0)"

      formatVersionErrorTemplate_missing_withUrl: (ut) ->
        result = ModuleLoader.formatVersionErrorTemplate nil, "MyModule", nil, "http://example.com", "not found"
        ut\assertContains result, ": http://example.com"

      formatVersionErrorTemplate_outdated_scalarRef: (ut) ->
        ref = {version: 65793}  -- 1*65536 + 1*256 + 1 = "1.1.1" in base-256 encoding
        result = ModuleLoader.formatVersionErrorTemplate nil, "MyModule", "2.0.0", nil, "too old", ref
        ut\assertContains result, "Installed:"
        ut\assertContains result, "Required: v2.0.0"
        ut\assertContains result, "1.1.1"

      formatVersionErrorTemplate_outdated_tableRef: (ut) ->
        ref = {version: {version: 65793}}  -- 1*65536 + 1*256 + 1 = "1.1.1" in base-256 encoding
        result = ModuleLoader.formatVersionErrorTemplate nil, "MyModule", "2.0.0", nil, "too old", ref
        ut\assertContains result, "Installed:"
        ut\assertContains result, "1.1.1"

      -- createDummyRef: tests LOADED_MODULES manipulation

      createDummyRef_nonModule: (ut) ->
        rec = {scriptType: Common.ScriptType.Automation, __class: {ScriptType: Common.ScriptType}}
        result = ModuleLoader.createDummyRef rec
        ut\assertNil result

      createDummyRef_newRef: (ut) ->
        ns = "test.ModuleLoader.createNew"
        rec = {scriptType: Common.ScriptType.Module, namespace: ns, __class: {ScriptType: Common.ScriptType}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = nil
        result = ModuleLoader.createDummyRef rec
        ut\assertTrue result
        ut\assertNotNil LOADED_MODULES[ns]
        ut\assertTrue LOADED_MODULES[ns][DEPCTRL_DUMMY_MODULE_MARKER]
        LOADED_MODULES[ns] = nil

      createDummyRef_existingRef: (ut) ->
        ns = "test.ModuleLoader.createExisting"
        rec = {scriptType: Common.ScriptType.Module, namespace: ns, __class: {ScriptType: Common.ScriptType}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = {existing: true}
        result = ModuleLoader.createDummyRef rec
        ut\assertFalse result
        LOADED_MODULES[ns] = nil

      -- removeDummyRef: tests LOADED_MODULES manipulation

      removeDummyRef_nonModule: (ut) ->
        rec = {scriptType: Common.ScriptType.Automation, __class: {ScriptType: Common.ScriptType}}
        result = ModuleLoader.removeDummyRef rec
        ut\assertNil result

      removeDummyRef_dummy: (ut) ->
        ns = "test.ModuleLoader.removeDummy"
        rec = {scriptType: Common.ScriptType.Module, namespace: ns, __class: {ScriptType: Common.ScriptType}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = {[DEPCTRL_DUMMY_MODULE_MARKER]: true}
        result = ModuleLoader.removeDummyRef rec
        ut\assertTrue result
        ut\assertNil LOADED_MODULES[ns]

      removeDummyRef_nonDummy: (ut) ->
        ns = "test.ModuleLoader.removeNonDummy"
        rec = {scriptType: Common.ScriptType.Module, namespace: ns, __class: {ScriptType: Common.ScriptType}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = {[DEPCTRL_DUMMY_MODULE_MARKER]: false}
        result = ModuleLoader.removeDummyRef rec
        ut\assertFalse result
        LOADED_MODULES[ns] = nil

      -- loadModule: stubs require, controls LOADED_MODULES

      loadModule_cached: (ut) ->
        ns = "test.ModuleLoader.cached"
        mockRef = {loaded: true}
        mdl = {moduleName: ns}
        rec = {namespace: "host.Module", __class: {ScriptType: Common.ScriptType, __name: "DependencyControl"}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = mockRef
        result = ModuleLoader.loadModule rec, mdl, false, false
        ut\assertEquals result, mockRef
        LOADED_MODULES[ns] = nil

      loadModule_success: (ut) ->
        ns = "test.ModuleLoader.success"
        mockRef = {loaded: true}
        mdl = {moduleName: ns}
        rec = {namespace: "host.Module", __class: {ScriptType: Common.ScriptType, __name: "DependencyControl"}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = nil
        (ut\stub _G, "require")\calls (name) -> mockRef
        result = ModuleLoader.loadModule rec, mdl, false, false
        ut\assertEquals result, mockRef
        ut\assertEquals mdl._ref, mockRef
        LOADED_MODULES[ns] = nil

      loadModule_missing: (ut) ->
        ns = "test.ModuleLoader.missing"
        mdl = {moduleName: ns}
        rec = {namespace: "host.Module", __class: {ScriptType: Common.ScriptType, __name: "DependencyControl"}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = nil
        (ut\stub _G, "require")\calls (name) -> error "module '#{name}' not found: no such file"
        result = ModuleLoader.loadModule rec, mdl, false, false
        ut\assertNil result
        ut\assertTrue mdl._missing
        ut\assertNil mdl._error

      loadModule_error: (ut) ->
        ns = "test.ModuleLoader.error"
        mdl = {moduleName: ns}
        rec = {namespace: "host.Module", __class: {ScriptType: Common.ScriptType, __name: "DependencyControl"}}
        LOADED_MODULES = LOADED_MODULES or {}
        LOADED_MODULES[ns] = nil
        (ut\stub _G, "require")\calls (name) -> error "syntax error in module"
        result = ModuleLoader.loadModule rec, mdl, false, false
        ut\assertNil result
        ut\assertFalse mdl._missing
        ut\assertString mdl._error

      -- loadModules: stubs loadModule to control loading behavior

      loadModules_skipsModule: (ut) ->
        ns = "test.ModuleLoader.skip"
        mdl = {moduleName: ns}
        loadModuleStub = ut\stub ModuleLoader, "loadModule"
        rec = {moduleName: "host.Module", feed: nil, name: "host",
               __class: {ScriptType: Common.ScriptType, __name: "DependencyControl", updater: nil}}
        success, err = ModuleLoader.loadModules rec, {mdl}, nil, {[ns]: true}
        ut\assertTrue success
        ut\assertEquals err, ""
        loadModuleStub\assertNotCalled!

      loadModules_allLoaded: (ut) ->
        ns = "test.ModuleLoader.allLoaded"
        mockRef = {loaded: true}
        mdl = {moduleName: ns, version: nil, name: ns}
        rec = {namespace: "host.Module", moduleName: "host.Module", feed: nil, name: "host",
               __class: {ScriptType: Common.ScriptType, __name: "DependencyControl", updater: nil}}
        (ut\stub ModuleLoader, "loadModule")\calls (self, m, usePrivate) ->
          m._ref = mockRef unless usePrivate
        success, err = ModuleLoader.loadModules rec, {mdl}
        ut\assertTrue success
        ut\assertEquals err, ""

      -- checkOptionalModules: mock self with requiredModules

      checkOptionalModules_noneOptional: (ut) ->
        rec = {
          name: "test"
          requiredModules: {{moduleName: "SomeModule", name: "SomeModule", optional: false}}
          __class: {ScriptType: Common.ScriptType, automationDir: {modules: "include"}}
        }
        result, err = ModuleLoader.checkOptionalModules rec, {"SomeModule"}
        ut\assertTrue result
        ut\assertNil err

      checkOptionalModules_missingOptional: (ut) ->
        rec = {
          name: "test"
          requiredModules: {
            {moduleName: "MissingMod", name: "MissingMod", optional: true, _missing: true,
             _reason: "not found", version: nil, url: nil}
          }
          __class: {ScriptType: Common.ScriptType, automationDir: {modules: "include"}}
        }
        result, err = ModuleLoader.checkOptionalModules rec, {"MissingMod"}
        ut\assertFalse result
        ut\assertString err
        ut\assertContains err, "MissingMod"

      _order: {
        "formatVersionErrorTemplate_missing_bare", "formatVersionErrorTemplate_missing_withVersion",
        "formatVersionErrorTemplate_missing_withUrl",
        "formatVersionErrorTemplate_outdated_scalarRef", "formatVersionErrorTemplate_outdated_tableRef",
        "createDummyRef_nonModule", "createDummyRef_newRef", "createDummyRef_existingRef",
        "removeDummyRef_nonModule", "removeDummyRef_dummy", "removeDummyRef_nonDummy",
        "loadModule_cached", "loadModule_success", "loadModule_missing", "loadModule_error",
        "loadModules_skipsModule", "loadModules_allLoaded",
        "checkOptionalModules_noneOptional", "checkOptionalModules_missingOptional"
      }
    }

    Record: (controls\requireTest "Record")!

    ScriptUpdateRecord: {
      _description: "Tests for ScriptUpdateRecord channel management and update record accessors."

      getChannels_basic: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}}, nightly: {version: "2.0.0", files: {}}}, name: "TestScript"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
        channels, default = sur\getChannels!
        ut\assertEquals #channels, 2
        ut\assertEquals default, "release"

      getChannels_noDefault: (ut) ->
        data = {channels: {alpha: {version: "1.0.0", files: {}}, beta: {version: "2.0.0", files: {}}}, name: "TestScript"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
        _, default = sur\getChannels!
        ut\assertNil default

      setChannel_valid: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}}, nightly: {version: "2.0.0", files: {}}}, name: "TestScript"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
        success, channel = sur\setChannel "nightly"
        ut\assertTrue success
        ut\assertEquals channel, "nightly"
        ut\assertEquals sur.version, "2.0.0"

      setChannel_invalid: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "TestScript"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
        success, channel = sur\setChannel "nonexistent"
        ut\assertFalse success
        ut\assertEquals channel, "nonexistent"

      checkPlatform_noConstraint: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "T"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
        result, platform = sur\checkPlatform!
        ut\assertTrue result
        ut\assertString platform

      checkPlatform_currentPlatform: (ut) ->
        -- platforms in channel data is copied to the instance via setChannel
        data = {channels: {release: {default: true, version: "1.0.0", files: {}, platforms: {Common.platform}}}, name: "T"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
        result, _ = sur\checkPlatform!
        ut\assertTrue result

      checkPlatform_notMatching: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}, platforms: {"nonexistent-arch"}}}, name: "T"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
        result, _ = sur\checkPlatform!
        ut\assertFalsy result

      getChangelog_noTable: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "T", changelog: "not a table"}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
        ut\assertEquals sur\getChangelog(nil), ""

      getChangelog_inRange: (ut) ->
        data = {
          channels: {release: {default: true, version: "1.0.0", files: {}}},
          name: "TestScript",
          changelog: {["1.0.0"]: {"Initial release"}, ["0.5.0"]: {"Beta"}}
        }
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
        result = sur\getChangelog nil
        ut\assertString result
        ut\assertContains result, "TestScript"
        ut\assertContains result, "Initial release"

      getChangelog_allOutOfRange: (ut) ->
        data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "T", changelog: {["1.0.0"]: {"Initial release"}}}
        sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
        ut\assertEquals sur\getChangelog(nil, "2.0.0"), ""

      _order: {
        "getChannels_basic", "getChannels_noDefault",
        "setChannel_valid", "setChannel_invalid",
        "checkPlatform_noConstraint", "checkPlatform_currentPlatform", "checkPlatform_notMatching",
        "getChangelog_noTable", "getChangelog_inRange", "getChangelog_allOutOfRange"
      }
    }

    UpdateFeed: {
      _description: "Tests for UpdateFeed feed data access and script record retrieval."

      getKnownFeeds_noData: (ut) ->
        feed = {data: nil, __class: UpdateFeed}
        result = UpdateFeed.getKnownFeeds feed
        ut\assertTable result
        ut\assertEquals #result, 0

      getKnownFeeds_withData: (ut) ->
        feed = {
          data: {knownFeeds: {a: "https://example.com/a.json", b: "https://example.com/b.json"}},
          __class: UpdateFeed
        }
        result = UpdateFeed.getKnownFeeds feed
        ut\assertEquals #result, 2

      getScript_invalidType: (ut) ->
        feed = {data: {macros: {}, modules: {}, knownFeeds: {}}, logger: DepCtrl.logger, __class: UpdateFeed}
        result, err = UpdateFeed.getScript feed, "test.NS", 99
        ut\assertNil result
        ut\assertString err

      getScript_missing: (ut) ->
        feed = {data: {macros: {}, modules: {}, knownFeeds: {}}, logger: DepCtrl.logger, __class: UpdateFeed}
        result = UpdateFeed.getScript feed, "test.NS", Common.ScriptType.Module
        ut\assertFalse result

      getScript_found: (ut) ->
        feed = {
          data: {modules: {"test.NS": {
            channels: {release: {default: true, version: "1.0.0", files: {}}},
            name: "T"
          }}, macros: {}, knownFeeds: {}},
          logger: DepCtrl.logger, __class: UpdateFeed
        }
        sur = UpdateFeed.getScript feed, "test.NS", Common.ScriptType.Module
        ut\assertTable sur
        ut\assertEquals sur.namespace, "test.NS"
        ut\assertEquals sur.activeChannel, "release"

      getMacro_usesAutomationType: (ut) ->
        -- getMacro calls @getScript, which requires self.getScript to resolve via colon call.
        -- Adding getScript directly to the mock avoids needing a full class metatable.
        feed = {
          data: {macros: {"test.NS": {
            channels: {release: {default: true, version: "1.0.0", files: {}}},
            name: "T"
          }}, modules: {}, knownFeeds: {}},
          logger: DepCtrl.logger, __class: UpdateFeed,
          getScript: UpdateFeed.getScript
        }
        sur = UpdateFeed.getMacro feed, "test.NS"
        ut\assertTable sur
        ut\assertFalse sur.moduleName  -- false for Automation (not a module)

      getModule_usesModuleType: (ut) ->
        feed = {
          data: {modules: {"test.NS": {
            channels: {release: {default: true, version: "1.0.0", files: {}}},
            name: "T"
          }}, macros: {}, knownFeeds: {}},
          logger: DepCtrl.logger, __class: UpdateFeed,
          getScript: UpdateFeed.getScript
        }
        sur = UpdateFeed.getModule feed, "test.NS"
        ut\assertTable sur
        ut\assertEquals sur.moduleName, "test.NS"  -- set for Module type

      _order: {
        "getKnownFeeds_noData", "getKnownFeeds_withData",
        "getScript_invalidType", "getScript_missing", "getScript_found",
        "getMacro_usesAutomationType", "getModule_usesModuleType"
      }
    }

    -- Real-HTTP exercise of the Downloader backends against a local pegasus/copas server
    -- (test/helpers/mock-http-server). Self-gating via _condition: skipped unless the server's
    -- Lua deps are installed, so the default offline run never needs luasocket/copas/pegasus.
    UpdateFeedExtra: (controls\requireTest "UpdateFeed") basePath, DepCtrl

    GitRepository: (controls\requireTest "GitRepository")!

    ScriptTargetFilter: (controls\requireTest "ScriptTargetFilter")!

    JsonSchema: (controls\requireTest "JsonSchema") basePath

    DownloaderIntegration: {
      _description: "Real-HTTP Downloader tests against a local test server (runs when launchable)."

      -- The controller is required lazily and pcall-guarded, so this is harmless where the test
      -- helpers aren't reachable (e.g. a stripped-down install) — it just skips.
      _condition: ->
        ok, MockServerController = pcall require, "l0.DependencyControl.test.helpers.MockHttpServerController"
        return false, "mock server helper unavailable (#{MockServerController})" unless ok
        isReady, err = MockServerController\isReady!
        return false, "mock server is not ready to start: #{err}" unless isReady
        return true

      _setup: (ut) ->
        MockServerController = require "l0.DependencyControl.test.helpers.MockHttpServerController"
        base = "#{basePath}_downloader"
        serveDir, downloadDir = "#{base}/fixtures", "#{base}/out"
        FileOps.mkdir d, false, true for d in *{base, serveDir, downloadDir}

        -- deterministic pseudo-random bytes (reproducible, no rng seeding dependency)
        makeBytes = (n) ->
          t, x = {}, 0x1234567
          for i = 1, n
            x = (x * 1103515245 + 12345) % 0x80000000
            t[i] = string.char x % 256
          table.concat t

        fixtures = {}
        for spec in *{ {"small.bin", 2048}, {"medium.bin", 64 * 1024}, {"large.bin", 256 * 1024} }
          name, size = spec[1], spec[2]
          path = "#{serveDir}/#{name}"
          f = assert io.open path, "wb"
          f\write makeBytes size
          f\close!
          sha1 = assert FileOps.getHash path, FileOps.HashType.SHA1
          fixtures[#fixtures + 1] = {:name, :sha1}

        server = MockServerController :serveDir
        server\start!
        {:server, :fixtures, :downloadDir}

      _teardown: (ut, ctx) ->
        ctx.server\stop! if ctx and ctx.server

      -- all transfers at full speed, fired together: every file must arrive and verify (sha1)
      concurrentFast: (ut, ctx) ->
        dm, dls = Downloader!, {}
        for f in *ctx.fixtures
          dls[f.name] = dm\addDownload "#{ctx.server.baseUrl}/fast/#{f.name}", "#{ctx.downloadDir}/#{f.name}", f.sha1
        dm\await!
        ut\assertEquals dls[f.name].status, Downloader.Download.Status.Finished for f in *ctx.fixtures

      -- chunked, throttled transfers kept in flight at once: the real concurrency stress
      concurrentSlow: (ut, ctx) ->
        dm, dls = Downloader!, {}
        for f in *ctx.fixtures
          dls[f.name] = dm\addDownload "#{ctx.server.baseUrl}/slow/#{f.name}?delay=20&chunk=4096", "#{ctx.downloadDir}/slow_#{f.name}", f.sha1
        dm\await!
        ut\assertEquals dls[f.name].status, Downloader.Download.Status.Finished for f in *ctx.fixtures

      -- more downloads than connection slots: all must still complete (windowed scheduler)
      queuedBeyondLimit: (ut, ctx) ->
        f = ctx.fixtures[1]
        dm, dls = Downloader(nil, {maxConnectionsPerServer: 2}), {}
        for i = 1, 5
          dls[i] = dm\addDownload "#{ctx.server.baseUrl}/slow/#{f.name}?delay=20&chunk=1024", "#{ctx.downloadDir}/q#{i}.bin", f.sha1
        dm\await!
        ut\assertEquals dls[i].status, Downloader.Download.Status.Finished for i = 1, 5

      -- a non-2xx response must fail the transfer, not hang or report success
      httpError: (ut, ctx) ->
        dm = Downloader!
        dl = dm\addDownload "#{ctx.server.baseUrl}/status/404", "#{ctx.downloadDir}/missing.bin"
        dm\await!
        ut\assertEquals dl.status, Downloader.Download.Status.Failed

      _order: { "concurrentFast", "concurrentSlow", "queuedBeyondLimit", "httpError" }
    }
  }
