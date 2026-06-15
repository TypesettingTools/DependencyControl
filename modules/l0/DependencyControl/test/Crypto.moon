-- Crypto tests: pure-Lua SHA-1 against known vectors.
-- Called from Tests.moon as: (require "...test.Crypto")!
->
  Crypto = require "l0.DependencyControl.Crypto"

  {
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
