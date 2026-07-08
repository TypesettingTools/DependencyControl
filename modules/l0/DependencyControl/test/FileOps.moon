-- FileOps tests: path validation and filesystem utilities.
-- Called from Tests.moon as: (require "...test.FileOps") basePath, isWindows
(basePath, isWindows) ->
  ffi     = require "ffi"
  lfs     = require "lfs"
  FileOps = require "l0.DependencyControl.FileOps"
  pathSep = isWindows and "\\" or "/"

  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"

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
    _description: "Tests for FileOps path validation and filesystem utilities."

    -- validateFullPath: pure computation, no stubs needed

    validateFullPath_nonString: (ut) ->
      result, err = FileOps.validateFullPath 42
      ut\assertNil result
      ut\assertString err

    validateFullPath_parentDir: (ut) ->
      -- ".." is resolved rather than rejected
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

    -- an empty or separator-only segment contributes nothing and must not truncate later segments
    joinPath_skipsEmptySegments: (ut) ->
      ut\assertEquals FileOps.joinPath("path", "", "file.txt"), "path#{pathSep}file.txt"
      ut\assertEquals FileOps.joinPath("path", {}, "file.txt"), "path#{pathSep}file.txt"
      ut\assertEquals FileOps.joinPath("a", "b/c", "d"), "a#{pathSep}b#{pathSep}c#{pathSep}d"

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

    -- a directory is removed non-recursively unless recurse is passed, so a stray directory path can't
    -- silently delete a whole tree (the recurse flag forwarded to rmdir must be false by default)
    remove_dirNonRecursiveByDefault: (ut) ->
      recurseArgs = {}
      (ut\stub lfs, "attributes")\calls (path, key) -> "directory"
      (ut\stub FileOps, "rmdir")\calls (path, recurse) -> recurseArgs[#recurseArgs + 1] = recurse; true
      FileOps.remove FileOps.joinPath basePath, "d"
      FileOps.remove FileOps.joinPath(basePath, "d"), true
      ut\assertEquals recurseArgs, {false, true}

    -- validateFullPath with basePath

    validateFullPath_withBasePath: (ut) ->
      result = FileOps.validateFullPath "file.txt", false, basePath
      ut\assertString result
      ut\assertContains result, "file.txt"

    -- __getPathRoot

    getPathRoot_windowsPath: (ut) ->
      return unless isWindows
      result = FileOps.__getPathRoot "C:\\Users\\foo"
      ut\assertEquals result, "C:\\"

    getPathRoot_posixPath: (ut) ->
      return if isWindows
      result = FileOps.__getPathRoot "/usr/local"
      ut\assertEquals result, "/usr"

    getPathRoot_relative: (ut) ->
      result = FileOps.__getPathRoot "relative/path"
      ut\assertNil result

    -- joinPath: dot/dot-dot resolution

    joinPath_resolvesDotDot: (ut) ->
      result = FileOps.joinPath "a", "b", "..", "c"
      ut\assertEquals result, "a#{pathSep}c"

    joinPath_invalidSegment: (ut) ->
      result, err = FileOps.joinPath 42
      ut\assertNil result
      ut\assertString err

    -- exists

    exists_fileFound: (ut) ->
      (ut\stub lfs, "attributes")\calls (path, key) -> "file"
      result = FileOps.exists {basePath, "file.txt"}, "file"
      ut\assertTrue result

    exists_notFound: (ut) ->
      (ut\stub lfs, "attributes")\calls (path, key) -> nil, "No such file or directory", 2
      result, err = FileOps.exists {basePath, "missing.txt"}, "file"
      ut\assertFalse result
      ut\assertString err

    exists_wrongType: (ut) ->
      (ut\stub lfs, "attributes")\calls (path, key) -> "directory"
      result, err = FileOps.exists {basePath, "dir"}, "file"
      ut\assertFalse result
      ut\assertString err

    exists_noTypeCheck: (ut) ->
      (ut\stub lfs, "attributes")\calls (path, key) -> "directory"
      result = FileOps.exists {basePath, "dir"}
      ut\assertTrue result

    -- listDir

    listDir_success: (ut) ->
      (ut\stub lfs, "attributes")\calls (path, key) -> "directory"
      entries = {"a.txt", ".", "b.lua", ".."}
      idx = 0
      makeIter = ->
        i = 0
        ->
          i += 1
          entries[i]
      (ut\stub lfs, "dir")\calls (path) -> makeIter!
      result = FileOps.listDir basePath
      ut\assertTable result
      ut\assertEquals #result, 2

    listDir_notDirectory: (ut) ->
      (ut\stub lfs, "attributes")\calls (path, key) -> "file"
      result, err = FileOps.listDir basePath
      ut\assertNil result
      ut\assertString err

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
      "remove_success", "remove_notFound", "remove_dirNonRecursiveByDefault",
      "validateFullPath_withBasePath",
      "getPathRoot_windowsPath", "getPathRoot_posixPath", "getPathRoot_relative",
      "joinPath_segmentsArray", "joinPath_segmentsVarargs", "joinPath_segmentsMixed",
      "joinPath_skipsEmptySegments", "joinPath_resolvesDotDot", "joinPath_invalidSegment",
      "exists_fileFound", "exists_notFound", "exists_wrongType", "exists_noTypeCheck",
      "listDir_success", "listDir_notDirectory"
    }
  }
