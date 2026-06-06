-- Additional FileOps tests: exists, getPathRoot, listDir, joinPath dot-resolution.
-- Called from Tests.moon as: (require "...test.FileOps") basePath, isWindows
(basePath, isWindows) ->
  ffi     = require "ffi"
  lfs     = require "lfs"
  FileOps = require "l0.DependencyControl.FileOps"
  pathSep = isWindows and "\\" or "/"

  {
    _description: "Additional FileOps tests: exists, getPathRoot, listDir, joinPath."

    -- validateFullPath with basePath

    validateFullPath_withBasePath: (ut) ->
      result = FileOps.validateFullPath "file.txt", false, basePath
      ut\assertString result
      ut\assertContains result, "file.txt"

    -- getPathRoot

    getPathRoot_windowsPath: (ut) ->
      return unless isWindows
      result = FileOps.getPathRoot "C:\\Users\\foo"
      ut\assertEquals result, "C:\\"

    getPathRoot_posixPath: (ut) ->
      return if isWindows
      result = FileOps.getPathRoot "/usr/local"
      ut\assertEquals result, "/usr"

    getPathRoot_relative: (ut) ->
      result = FileOps.getPathRoot "relative/path"
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
      "validateFullPath_withBasePath",
      "getPathRoot_windowsPath", "getPathRoot_posixPath", "getPathRoot_relative",
      "joinPath_resolvesDotDot", "joinPath_invalidSegment",
      "exists_fileFound", "exists_notFound", "exists_wrongType", "exists_noTypeCheck",
      "listDir_success", "listDir_notDirectory"
    }
  }
