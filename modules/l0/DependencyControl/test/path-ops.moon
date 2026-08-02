-- path-ops tests: joining and resolving path segments, validating and normalizing full paths against
-- the platform's length/character/reserved-name rules, and decoding Aegisub path tokens with a fallback
-- for a token the running build lacks. Pure computation over a temp base path and a stubbed
-- decode_path; nothing here touches the filesystem.
-- Called from test.moon as: (require "…test.path-ops") basePath, isWindows
(basePath, isWindows) ->
  pathOps = require "l0.DependencyControl.path-ops"
  fileOps = require "l0.DependencyControl.file-ops"
  pathSep = isWindows and "\\" or "/"

  -- Runs fn with the path-length detection results overridden, restoring them afterwards (even if fn
  -- raises) so the platform-derived values don't leak between tests. Lets us exercise every
  -- "path too long" diagnostic branch on any OS.
  withPathLimits = (maxLength, longPathsDisabled, registryEnabled, fn) ->
    saved = {pathOps.pathMaxLength, pathOps.longPathsDisabled, pathOps.windowsRegistryLongPathsEnabled}
    pathOps.pathMaxLength = maxLength
    pathOps.longPathsDisabled = longPathsDisabled
    pathOps.windowsRegistryLongPathsEnabled = registryEnabled
    results = table.pack pcall fn
    pathOps.pathMaxLength, pathOps.longPathsDisabled, pathOps.windowsRegistryLongPathsEnabled = saved[1], saved[2], saved[3]
    error results[2] unless results[1]
    return unpack results, 2, results.n

  -- The token-support probe is memoized for the process, so results carried over from another Aegisub —
  -- the real one the suite runs under, or the previous test's — have to go before each stub.
  clearProbeCache = -> pathOps.__tokenSupport[token] = nil for token in pairs pathOps.__tokenSupport

  -- Stands in for aegisub.decode_path over the given `token -> directory` map: a token in the map
  -- resolves to its directory, one absent from it comes back verbatim, as Aegisub does for a token
  -- it doesn't know.
  stubDecodePath = (ut, resolved) ->
    clearProbeCache!
    (ut\stub aegisub, "decode_path")\calls (path) ->
      for token, dir in pairs resolved
        return dir .. path\sub(#token + 1) if path\sub(1, #token) == token
      return path

  withState = {"?state": "/state", "?user": "/user"}
  withoutState = {"?user": "/user"}

  {
    _description: "path-ops: path composition and validation, plus Aegisub path-token decoding."

    -- joinPath: pure computation, no stubs needed

    joinPath_segmentsArray: (ut) ->
      result = pathOps.joinPath {"path", "to", "file.txt"}
      ut\assertEquals result, "path#{pathSep}to#{pathSep}file.txt"

    joinPath_segmentsVarargs: (ut) ->
      result = pathOps.joinPath "path", "to", "file.txt"
      ut\assertEquals result, "path#{pathSep}to#{pathSep}file.txt"

    joinPath_segmentsMixed: (ut) ->
      result = pathOps.joinPath {"path", "to"}, "file.txt"
      ut\assertEquals result, "path#{pathSep}to#{pathSep}file.txt"

    -- an empty or separator-only segment contributes nothing and must not truncate later segments
    joinPath_skipsEmptySegments: (ut) ->
      ut\assertEquals pathOps.joinPath("path", "", "file.txt"), "path#{pathSep}file.txt"
      ut\assertEquals pathOps.joinPath("path", {}, "file.txt"), "path#{pathSep}file.txt"
      ut\assertEquals pathOps.joinPath("a", "b/c", "d"), "a#{pathSep}b#{pathSep}c#{pathSep}d"

    joinPath_resolvesDotDot: (ut) ->
      result = pathOps.joinPath "a", "b", "..", "c"
      ut\assertEquals result, "a#{pathSep}c"

    joinPath_invalidSegment: (ut) ->
      result, err = pathOps.joinPath 42
      ut\assertNil result
      ut\assertString err

    -- _getPathRoot

    getPathRoot_windowsPath: (ut) ->
      return unless isWindows
      result = pathOps._getPathRoot "C:\\Users\\foo"
      ut\assertEquals result, "C:\\"

    getPathRoot_posixPath: (ut) ->
      return if isWindows
      result = pathOps._getPathRoot "/usr/local"
      ut\assertEquals result, "/usr"

    getPathRoot_relative: (ut) ->
      result = pathOps._getPathRoot "relative/path"
      ut\assertNil result

    -- resolveFullPath: pure computation, no stubs needed

    resolveFullPath_nonString: (ut) ->
      result, err = pathOps.resolveFullPath 42
      ut\assertNil result
      ut\assertString err

    resolveFullPath_parentDir: (ut) ->
      -- ".." is resolved rather than rejected
      result = pathOps.resolveFullPath {basePath, "..", "escape.txt"}
      ut\assertString result -- resolves to parent dir + escape.txt

    resolveFullPath_tooLong: (ut) ->
      -- exceed the full-path limit on every platform/config (well past the ~32k
      -- long-path-enabled Windows limit) while keeping each component within bounds
      segments = [string.rep "a", 200 for _ = 1, 200]
      result = pathOps.resolveFullPath {basePath, segments}
      ut\assertNil result

    resolveFullPath_segmentTooLong: (ut) ->
      -- a single component over the per-segment limit is rejected even when the overall
      -- path fits the length limit (raise the length cap so the segment check is reached)
      result, err = withPathLimits 32767, false, false, ->
        pathOps.resolveFullPath {basePath, "#{string.rep 'a', 300}.txt"}
      ut\assertNil result
      ut\assertContains err, "path component"

    -- detected, platform-specific path limits
    pathLimits_detected: (ut) ->
      ut\assertEquals pathOps.pathMaxSegmentLength, 255
      if isWindows
        -- 260 (capped) or 32767 (long paths available to this process)
        ut\assertTrue pathOps.pathMaxLength == 260 or pathOps.pathMaxLength == 32767
        ut\assertBoolean pathOps.longPathsDisabled
      else
        ut\assertEquals pathOps.pathMaxLength, 4096
        ut\assertFalse pathOps.longPathsDisabled

    -- "path too long" diagnostic selection (field-driven via withPathLimits, runs on any OS)
    resolveFullPath_tooLong_generic: (ut) ->
      -- non-Windows / long paths available: plain limit message, no Windows-specific guidance
      result, err = withPathLimits 260, false, false, ->
        pathOps.resolveFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
      ut\assertNil result
      ut\assertContains err, "maximum length limit"

    resolveFullPath_tooLong_registryDisabled: (ut) ->
      -- Windows, long paths off system-wide: error explains how to enable the registry key
      result, err = withPathLimits 260, true, false, ->
        pathOps.resolveFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
      ut\assertNil result
      ut\assertContains err, "LongPathsEnabled"

    resolveFullPath_tooLong_processUnaware: (ut) ->
      -- Windows, registry on but app not long-path-aware: error explains the manifest cap
      result, err = withPathLimits 260, true, true, ->
        pathOps.resolveFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
      ut\assertNil result
      ut\assertContains err, "long-path-aware"

    resolveFullPath_invalidChars: (ut) ->
      return unless isWindows
      result = pathOps.resolveFullPath {basePath, "with<invalid>.txt"}
      ut\assertNil result

    resolveFullPath_reservedNames: (ut) ->
      return unless isWindows
      result = pathOps.resolveFullPath {basePath, "CON", "file.txt"}
      ut\assertNil result

    resolveFullPath_reservedNameWithExt: (ut) ->
      return unless isWindows
      result = pathOps.resolveFullPath {basePath, "NUL.txt"}
      ut\assertNil result

    resolveFullPath_trailingDotSegment: (ut) ->
      result = pathOps.resolveFullPath {basePath, "trailingDot.", "file.txt"}
      ut\assertNil result

    -- dir is the absolute directory, usable without stitching anything onto it, and err stays nil
    resolveFullPath_valid: (ut) ->
      path, err, dir, file = pathOps.resolveFullPath {basePath, "file.txt"}
      ut\assertEquals path, pathOps.joinPath basePath, "file.txt"
      ut\assertNil err
      ut\assertEquals dir, basePath
      ut\assertEquals file, "file.txt"

    -- a path nested below the base still reports the whole directory, not a fragment of it
    resolveFullPath_dirIsAbsoluteWhenNested: (ut) ->
      _, _, dir, file = pathOps.resolveFullPath {basePath, "sub", "deeper", "file.txt"}
      ut\assertEquals dir, pathOps.joinPath basePath, "sub", "deeper"
      ut\assertEquals file, "file.txt"

    resolveFullPath_noExt_rejected: (ut) ->
      result = pathOps.resolveFullPath {basePath, "no-ext"}, true
      ut\assertFalse result

    resolveFullPath_withExt_accepted: (ut) ->
      result = pathOps.resolveFullPath {basePath, "file.txt"}, true
      ut\assertString result

    resolveFullPath_homeDirExpansion: (ut) ->
      return if isWindows
      home = os.getenv "HOME"
      return unless home
      result = pathOps.resolveFullPath {"~", "subdir", "file.txt"}
      ut\assertString result
      ut\assertContains result, home

    resolveFullPath_reservedNameNonWindows: (ut) ->
      return if isWindows
      result = pathOps.resolveFullPath {basePath, "NUL", "file.txt"}
      ut\assertString result

    resolveFullPath_withBasePath: (ut) ->
      result = pathOps.resolveFullPath "file.txt", false, basePath
      ut\assertString result
      ut\assertContains result, "file.txt"

    -- the probe reports support from whether decode_path resolved the token or handed it back

    isTokenSupported_trueWhenTokenResolves: (ut) ->
      stubDecodePath ut, withState
      ut\assertTrue pathOps.isTokenSupported "?state"

    isTokenSupported_falseWhenTokenComesBackVerbatim: (ut) ->
      stubDecodePath ut, withoutState
      ut\assertFalse pathOps.isTokenSupported "?state"

    -- the probe result is memoized, so repeated decodes don't re-query Aegisub
    isTokenSupported_probesOncePerToken: (ut) ->
      stub = stubDecodePath ut, withState
      pathOps.isTokenSupported "?state"
      pathOps.isTokenSupported "?state"
      stub\assertCalledOnce!

    -- a build that knows ?state decodes it directly, fallback untouched
    decode_resolvesSupportedToken: (ut) ->
      stubDecodePath ut, withState
      ut\assertEquals pathOps.decode("?state/log"), "/state/log"

    -- a build without ?state gets the fallback token, keeping everything after it
    decode_substitutesFallbackForUnsupportedToken: (ut) ->
      stubDecodePath ut, withoutState
      ut\assertEquals pathOps.decode("?state/log"), "/user/log"

    decode_substitutesFallbackForBareToken: (ut) ->
      stubDecodePath ut, withoutState
      ut\assertEquals pathOps.decode("?state"), "/user"

    -- a token with no fallback entry is handed to Aegisub untouched, supported or not
    decode_passesOtherTokensThrough: (ut) ->
      stubDecodePath ut, withoutState
      ut\assertEquals pathOps.decode("?user/config"), "/user/config"

    decode_passesPathWithoutTokenThrough: (ut) ->
      stubDecodePath ut, withoutState
      ut\assertEquals pathOps.decode("/absolute/path"), "/absolute/path"

    -- probe results from the stubbed Aegisub must not outlive this class
    _teardown: -> clearProbeCache!

    _order: {
      "joinPath_segmentsArray", "joinPath_segmentsVarargs", "joinPath_segmentsMixed"
      "joinPath_skipsEmptySegments", "joinPath_resolvesDotDot", "joinPath_invalidSegment"
      "getPathRoot_windowsPath", "getPathRoot_posixPath", "getPathRoot_relative"
      "resolveFullPath_nonString", "resolveFullPath_parentDir", "resolveFullPath_tooLong"
      "resolveFullPath_segmentTooLong", "pathLimits_detected"
      "resolveFullPath_tooLong_generic", "resolveFullPath_tooLong_registryDisabled"
      "resolveFullPath_tooLong_processUnaware"
      "resolveFullPath_invalidChars", "resolveFullPath_reservedNames"
      "resolveFullPath_reservedNameWithExt", "resolveFullPath_trailingDotSegment"
      "resolveFullPath_valid", "resolveFullPath_dirIsAbsoluteWhenNested"
      "resolveFullPath_noExt_rejected", "resolveFullPath_withExt_accepted"
      "resolveFullPath_homeDirExpansion", "resolveFullPath_reservedNameNonWindows"
      "resolveFullPath_withBasePath"
      "isTokenSupported_trueWhenTokenResolves", "isTokenSupported_falseWhenTokenComesBackVerbatim"
      "isTokenSupported_probesOncePerToken"
      "decode_resolvesSupportedToken", "decode_substitutesFallbackForUnsupportedToken"
      "decode_substitutesFallbackForBareToken", "decode_passesOtherTokensThrough"
      "decode_passesPathWithoutTokenThrough"
    }
  }
