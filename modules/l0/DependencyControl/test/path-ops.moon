-- path-ops tests: a path token the running Aegisub resolves is decoded as-is, one it doesn't know
-- is swapped for its fallback token first, and the support probe runs once per token. Uses a stubbed
-- decode_path standing in for Aegisub builds with and without ?state; no filesystem access.
-- Called from test.moon as: (require "…test.path-ops")!
() ->
  pathOps = require "l0.DependencyControl.path-ops"

  -- The support probe is memoized for the process, so results carried over from another Aegisub —
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
    _description: "path-ops: decoding Aegisub path tokens with a fallback for tokens older builds lack."

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
      "isTokenSupported_trueWhenTokenResolves", "isTokenSupported_falseWhenTokenComesBackVerbatim"
      "isTokenSupported_probesOncePerToken"
      "decode_resolvesSupportedToken", "decode_substitutesFallbackForUnsupportedToken"
      "decode_substitutesFallbackForBareToken", "decode_passesOtherTokensThrough"
      "decode_passesPathWithoutTokenThrough"
    }
  }
