-- Hash tests: SHA-1 against known vectors, the active backend against the pure-Lua reference,
-- and the verify helper. Called from test.moon as: (require "...test.hash")!
->
  Hash = require "l0.DependencyControl.hash"
  ht = Hash.HashType

  {
    _description: "Tests for the Hash utilities (SHA-1 digests and verification) against known vectors."

    sha1_abc: (ut) ->
      ut\assertEquals Hash.getDigest(ht.Sha1, "abc"), "a9993e364706816aba3e25717850c26c9cd0d89d"

    sha1_empty: (ut) ->
      ut\assertEquals Hash.getDigest(ht.Sha1, ""), "da39a3ee5e6b4b0d3255bfef95601890afd80709"

    -- exercises multi-block padding (>55 bytes)
    sha1_quickBrownFox: (ut) ->
      ut\assertEquals Hash.getDigest(ht.Sha1, "The quick brown fox jumps over the lazy dog"),
        "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12"

    -- binary payloads (embedded NUL and high bytes) hash without error
    sha1_binaryData: (ut) ->
      digest = Hash.getDigest ht.Sha1, "\0\1\2\254\255"
      ut\assertMatches digest, "^%x+$"
      ut\assertEquals #digest, 40

    sha1_rejectsNonString: (ut) ->
      result, err = Hash.getDigest ht.Sha1, 42
      ut\assertNil result
      ut\assertString err

    -- whichever backend is active (native or lua) must match the reference impl
    sha1_backendMatchesReference: (ut) ->
      for input in *{"", "abc", "The quick brown fox jumps over the lazy dog", "\0\1\2\254\255"}
        ut\assertEquals Hash.getDigest(ht.Sha1, input), Hash._sha1Lua input

    verify_matchIsCaseInsensitive: (ut) ->
      digest = "a9993e364706816aba3e25717850c26c9cd0d89d"
      ut\assertTrue Hash.verify ht.Sha1, "abc", digest
      ut\assertTrue Hash.verify ht.Sha1, "abc", digest\upper!

    verify_mismatchReturnsFalseAndErr: (ut) ->
      match, err = Hash.verify ht.Sha1, "abc", "0000000000000000000000000000000000000000"
      ut\assertEquals match, false
      ut\assertString err

    verify_rejectsNonStringExpected: (ut) ->
      result, err = Hash.verify ht.Sha1, "abc", 42
      ut\assertNil result
      ut\assertString err

    _order: {
      "sha1_abc", "sha1_empty", "sha1_quickBrownFox",
      "sha1_binaryData", "sha1_rejectsNonString", "sha1_backendMatchesReference",
      "verify_matchIsCaseInsensitive", "verify_mismatchReturnsFalseAndErr", "verify_rejectsNonStringExpected"
    }
  }
