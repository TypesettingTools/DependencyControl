-- path-ops tests: joining and resolving path segments, validating and normalizing full paths against
-- the platform's length/character/reserved-name rules, and decoding Aegisub path tokens with a fallback
-- for a token the running build lacks. Pure computation over a temp base path and a stubbed
-- decode_path; nothing here touches the filesystem.
-- Called from test.moon as: (require "…test.path-ops") basePath, isWindows
(basePath, isWindows) ->
  pathOps = require "l0.DependencyControl.path-ops"
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

    -- __getPathRoot

    getPathRoot_windowsPath: (ut) ->
      return unless isWindows
      result = pathOps.__getPathRoot "C:\\Users\\foo"
      ut\assertEquals result, "C:\\"

    getPathRoot_posixPath: (ut) ->
      return if isWindows
      result = pathOps.__getPathRoot "/usr/local"
      ut\assertEquals result, "/usr"

    getPathRoot_relative: (ut) ->
      result = pathOps.__getPathRoot "relative/path"
      ut\assertNil result

    -- validateFullPath: pure computation, no stubs needed

    validateFullPath_nonString: (ut) ->
      result, err = pathOps.validateFullPath 42
      ut\assertNil result
      ut\assertString err

    validateFullPath_parentDir: (ut) ->
      -- ".." is resolved rather than rejected
      result = pathOps.validateFullPath {basePath, "..", "escape.txt"}
      ut\assertString result -- resolves to parent dir + escape.txt

    validateFullPath_tooLong: (ut) ->
      -- exceed the full-path limit on every platform/config (well past the ~32k
      -- long-path-enabled Windows limit) while keeping each component within bounds
      segments = [string.rep "a", 200 for _ = 1, 200]
      result = pathOps.validateFullPath {basePath, segments}
      ut\assertNil result

    validateFullPath_segmentTooLong: (ut) ->
      -- a single component over the per-segment limit is rejected even when the overall
      -- path fits the length limit (raise the length cap so the segment check is reached)
      result, err = withPathLimits 32767, false, false, ->
        pathOps.validateFullPath {basePath, "#{string.rep 'a', 300}.txt"}
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
    validateFullPath_tooLong_generic: (ut) ->
      -- non-Windows / long paths available: plain limit message, no Windows-specific guidance
      result, err = withPathLimits 260, false, false, ->
        pathOps.validateFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
      ut\assertNil result
      ut\assertContains err, "maximum length limit"

    validateFullPath_tooLong_registryDisabled: (ut) ->
      -- Windows, long paths off system-wide: error explains how to enable the registry key
      result, err = withPathLimits 260, true, false, ->
        pathOps.validateFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
      ut\assertNil result
      ut\assertContains err, "LongPathsEnabled"

    validateFullPath_tooLong_processUnaware: (ut) ->
      -- Windows, registry on but app not long-path-aware: error explains the manifest cap
      result, err = withPathLimits 260, true, true, ->
        pathOps.validateFullPath {basePath, [string.rep "a", 200 for _ = 1, 3]}
      ut\assertNil result
      ut\assertContains err, "long-path-aware"

    validateFullPath_invalidChars: (ut) ->
      return unless isWindows
      result = pathOps.validateFullPath {basePath, "with<invalid>.txt"}
      ut\assertNil result

    validateFullPath_reservedNames: (ut) ->
      return unless isWindows
      result = pathOps.validateFullPath {basePath, "CON", "file.txt"}
      ut\assertNil result

    validateFullPath_reservedNameWithExt: (ut) ->
      return unless isWindows
      result = pathOps.validateFullPath {basePath, "NUL.txt"}
      ut\assertNil result

    validateFullPath_trailingDotSegment: (ut) ->
      result = pathOps.validateFullPath {basePath, "trailingDot.", "file.txt"}
      ut\assertNil result

    validateFullPath_valid: (ut) ->
      path, dev, dir, file = pathOps.validateFullPath {basePath, "file.txt"}
      ut\assertString path
      ut\assertString dev
      ut\assertEquals file, "file.txt"

    validateFullPath_noExt_rejected: (ut) ->
      result = pathOps.validateFullPath {basePath, "no-ext"}, true
      ut\assertFalse result

    validateFullPath_withExt_accepted: (ut) ->
      result = pathOps.validateFullPath {basePath, "file.txt"}, true
      ut\assertString result

    validateFullPath_homeDirExpansion: (ut) ->
      return if isWindows
      home = os.getenv "HOME"
      return unless home
      result = pathOps.validateFullPath {"~", "subdir", "file.txt"}
      ut\assertString result
      ut\assertContains result, home

    validateFullPath_reservedNameNonWindows: (ut) ->
      return if isWindows
      result = pathOps.validateFullPath {basePath, "NUL", "file.txt"}
      ut\assertString result

    validateFullPath_withBasePath: (ut) ->
      result = pathOps.validateFullPath "file.txt", false, basePath
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
      "validateFullPath_nonString", "validateFullPath_parentDir", "validateFullPath_tooLong"
      "validateFullPath_segmentTooLong", "pathLimits_detected"
      "validateFullPath_tooLong_generic", "validateFullPath_tooLong_registryDisabled"
      "validateFullPath_tooLong_processUnaware"
      "validateFullPath_invalidChars", "validateFullPath_reservedNames"
      "validateFullPath_reservedNameWithExt", "validateFullPath_trailingDotSegment"
      "validateFullPath_valid", "validateFullPath_noExt_rejected", "validateFullPath_withExt_accepted"
      "validateFullPath_homeDirExpansion", "validateFullPath_reservedNameNonWindows"
      "validateFullPath_withBasePath"
      "isTokenSupported_trueWhenTokenResolves", "isTokenSupported_falseWhenTokenComesBackVerbatim"
      "isTokenSupported_probesOncePerToken"
      "decode_resolvesSupportedToken", "decode_substitutesFallbackForUnsupportedToken"
      "decode_substitutesFallbackForBareToken", "decode_passesOtherTokensThrough"
      "decode_passesPathWithoutTokenThrough"
    }
  }
