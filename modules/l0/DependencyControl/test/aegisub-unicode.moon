-- cspell:ignore Straße STRASSE strasse grüße GRÜSSE ΟΔΟΣ οδοσ
-- Pins the behavior of `aegisub.unicode`. The same corpus runs in both environments: inside Aegisub it
-- checks the live module, while under the CLI the preload in l0.AegisubShims swaps in the ICU-backed
-- stand-in, so the run doubles as the stand-in's conformance test.
-- Called from test.moon as: (controls\requireTest "aegisub-unicode")!
--
-- The four inspection functions are pure UTF-8 arithmetic and always run. The three case conversions
-- need ICU, which the stand-in reaches through the FFI and may not find on a given box, so each skips
-- individually rather than taking the whole class out.
->
  -- Requiring l0.AegisubShims.unicode directly would resolve only under the CLI: inside Aegisub the
  -- shim package isn't deployed at all, so the require fails and takes the whole suite's setup down.
  haveUnicode, unicode = pcall require, "aegisub.unicode"

  -- The preload only fires outside Aegisub, so this distinguishes the stand-in from the real module
  -- without either of them having to advertise which it is.
  isStandIn = package.loaded["l0.AegisubShims.unicode"] == unicode

  -- The stand-in binds ICU lazily on the first conversion, so this is also what forces the bind.
  local icuError
  if haveUnicode
    bound, err = pcall unicode.to_upper_case, "a"
    icuError = err unless bound

  -- Greek sigma has two lower-case forms, and which one a conversion produces is the sharpest
  -- available check that the real Unicode algorithms are running rather than a byte-wise shortcut:
  -- lower-casing picks the word-final ς (U+03C2) from context, while case folding normalizes to the
  -- ordinary σ (U+03C3) so the two spellings compare equal.
  GREEK_UPPER = "ΟΔΟΣ"
  GREEK_LOWER_FINAL_SIGMA = "οδος"
  GREEK_FOLDED_PLAIN_SIGMA = "οδοσ"

  STRING_SAMPLE_MIXED_WIDTHS = "grüße 日本"

  skipWithoutIcu = (ut) ->
    ut\skip "ICU unavailable (#{tostring icuError})" if icuError

  {
    _description: "Conformance of aegisub.unicode, and of the headless stand-in that replaces it."
    _condition: -> haveUnicode, "aegisub.unicode unavailable (#{tostring unicode})"

    -- the require-id mapping only exists once l0.AegisubShims has installed it, which never happens
    -- inside Aegisub; gate on it so this file stays runnable in both environments
    preload_claimsAegisubUnicodeRequireId: (ut) ->
      ut\skip "l0.AegisubShims isn't loaded" unless isStandIn
      loader = package.preload["aegisub.unicode"]
      ut\assertFunction loader
      ut\assertIs loader!, unicode

    charwidth_leadByteDeterminesWidth: (ut) ->
      ut\assertEquals unicode.charwidth("A"), 1
      ut\assertEquals unicode.charwidth("ü"), 2
      ut\assertEquals unicode.charwidth("日"), 3
      ut\assertEquals unicode.charwidth("😀"), 4

    charwidth_honorsOffset: (ut) ->
      -- "grüße": g at 1, r at 2, ü spanning 3-4, ß spanning 5-6
      ut\assertEquals unicode.charwidth("grüße", 1), 1
      ut\assertEquals unicode.charwidth("grüße", 3), 2
      ut\assertEquals unicode.charwidth("grüße", 5), 2

    charwidth_pastEndIsOne: (ut) ->
      ut\assertEquals unicode.charwidth("abc", 99), 1
      ut\assertEquals unicode.charwidth(""), 1

    chars_yieldsCharacterAndIndex: (ut) ->
      collected = [{char, index} for char, index in unicode.chars "aüb"]
      ut\assertEquals #collected, 3
      ut\assertEquals collected[1][1], "a"
      ut\assertEquals collected[2][1], "ü"
      ut\assertEquals collected[3][1], "b"
      ut\assertEquals collected[i][2], i for i = 1, 3

    chars_emptyStringYieldsNothing: (ut) ->
      count = 0
      count += 1 for _ in unicode.chars ""
      ut\assertEquals count, 0

    len_countsCharactersNotBytes: (ut) ->
      ut\assertEquals unicode.len(STRING_SAMPLE_MIXED_WIDTHS), 8
      ut\assertEquals #STRING_SAMPLE_MIXED_WIDTHS, 14
      ut\assertEquals unicode.len(""), 0
      ut\assertEquals unicode.len("plain ascii"), 11

    codepoint_decodesEveryWidth: (ut) ->
      ut\assertEquals unicode.codepoint("A"), 0x41
      ut\assertEquals unicode.codepoint("ü"), 0xFC
      ut\assertEquals unicode.codepoint("日"), 0x65E5
      ut\assertEquals unicode.codepoint("😀"), 0x1F600

    codepoint_readsOnlyTheFirstCharacter: (ut) ->
      ut\assertEquals unicode.codepoint("日本語"), 0x65E5

    to_upper_case_expandsToFullMapping: (ut) ->
      skipWithoutIcu ut
      ut\assertEquals unicode.to_upper_case("grüße"), "GRÜSSE"
      ut\assertEquals unicode.to_upper_case("Straße"), "STRASSE"
      ut\assertEquals unicode.to_upper_case("already upper"), "ALREADY UPPER"
      ut\assertEquals unicode.to_upper_case(""), ""

    to_lower_case_picksFinalSigmaFromContext: (ut) ->
      skipWithoutIcu ut
      ut\assertEquals unicode.to_lower_case("GRÜSSE"), "grüsse"
      ut\assertEquals unicode.to_lower_case(GREEK_UPPER), GREEK_LOWER_FINAL_SIGMA
      ut\assertEquals unicode.to_lower_case(""), ""

    to_fold_case_normalizesBothSigmaForms: (ut) ->
      skipWithoutIcu ut
      ut\assertEquals unicode.to_fold_case("Straße"), "strasse"
      ut\assertEquals unicode.to_fold_case(GREEK_UPPER), GREEK_FOLDED_PLAIN_SIGMA
      ut\assertEquals unicode.to_fold_case(GREEK_LOWER_FINAL_SIGMA), GREEK_FOLDED_PLAIN_SIGMA
      ut\assertEquals unicode.to_fold_case(""), ""

    to_fold_case_makesVariantSpellingsCompareEqual: (ut) ->
      skipWithoutIcu ut
      fold = unicode.to_fold_case
      ut\assertEquals fold("Straße"), fold("STRASSE")
      ut\assertEquals fold(GREEK_UPPER), fold(GREEK_LOWER_FINAL_SIGMA)

    to_upper_case_growingMappingIsNotTruncated: (ut) ->
      skipWithoutIcu ut
      -- ß maps to two characters, so the result outgrows the source and a destination buffer sized
      -- from the input alone would cut it short
      ut\assertEquals unicode.len(STRING_SAMPLE_MIXED_WIDTHS), 8
      ut\assertEquals unicode.len(unicode.to_upper_case STRING_SAMPLE_MIXED_WIDTHS), 9

    argumentGuards_rejectNonStrings: (ut) ->
      ut\assertError unicode.charwidth, 42
      ut\assertError unicode.chars, nil
      ut\assertError unicode.len, {}
      ut\assertError unicode.codepoint, false
  }
