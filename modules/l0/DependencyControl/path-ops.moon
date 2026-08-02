---Stand-in token for each token only newer Aegisub builds resolve, keyed by the newer token.
fallbacks = {
  "?state": "?user"
}

-- forward-declared so the members below close over the local rather than a global of the same name
local PathOps

---Decodes Aegisub path tokens, substituting a fallback for a token the running build can't resolve.
---`?state` falls back to `?user`, so a path naming it works on an Aegisub that predates the token.
---@class PathOps
PathOps = {
  ---Memoized `token -> isSupported` probe results; a test stubbing decode_path clears it directly.
  ---Requiring UnitTestSuite for hidden test exports here would cycle back into this module via Logger.
  ---@private
  __tokenSupport: {}

  ---Reports whether the running Aegisub resolves the given path token to a directory.
  ---@param token string The token to probe, leading "?" included.
  ---@return boolean isSupported False when Aegisub doesn't know the token or leaves it unset.
  isTokenSupported: (token) ->
    supported = PathOps.__tokenSupport[token]
    unless supported == nil
      return supported
    -- a token Aegisub can't resolve comes back verbatim, a resolved one as its directory
    supported = aegisub.decode_path(token) != token
    PathOps.__tokenSupport[token] = supported
    return supported

  ---Resolves every Aegisub path token in a path against the running build.
  ---Token matching is prefix-based, as in Aegisub itself, so a separator after the token is optional.
  ---@param path string A path that may start with an Aegisub path token.
  ---@return string decodedPath The path with all tokens resolved to absolute directories.
  decode: (path) ->
    for token, fallback in pairs fallbacks
      continue unless path\sub(1, #token) == token
      continue if PathOps.isTokenSupported token
      path = fallback .. path\sub #token + 1
      break
    return aegisub.decode_path path
}

return PathOps
