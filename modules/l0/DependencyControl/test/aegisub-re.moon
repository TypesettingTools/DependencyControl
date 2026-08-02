-- cspell:ignore Grüße Grüsse München Straße Strasse bbaa grüß
-- Pins the behavior of `aegisub.re`. Every expectation below was captured from a real Aegisub run, and
-- the same corpus asserts them in both environments: inside Aegisub it re-checks the live Boost.Regex
-- + ICU module, while under the CLI the preload in l0.AegisubShims swaps in the PCRE2-backed stand-in,
-- so the run doubles as the stand-in's conformance test.
-- Called from test.moon as: (controls\requireTest "aegisub-re")!
--
-- A case the engine rejects asserts only that it raised; the error text is engine-specific and is
-- deliberately not compared.
->
  haveRe, re = pcall require, "aegisub.re"

  -- The preload only fires outside Aegisub, so this distinguishes the stand-in from the real module
  -- without either of them having to advertise which it is.
  isStandIn = package.loaded["l0.AegisubShims.re"] == re
  haveEngine = not isStandIn or (pcall require, "rex_pcre2")

  -- Boost's own regbase bits, so a script that stored a flag compares equal against either module
  EXPECTED_FLAG_VALUES = {
    NO_MOD_M: 0x400
    MOD_X: 0x800
    MOD_S: 0x1000
    NO_MOD_S: 0x2000
    NEWLINE_ALT: 0x20000
    ICASE: 0x100000
    COLLATE: 0x200000
    NOSUB: 0x400000
    NO_EMPTY_SUBEXPRESSIONS: 0x1000000
  }

  STRING_SAMPLE_ASCII = "The quick brown fox jumps over the lazy dog"
  STRING_SAMPLE_MULTIPLE_LINES = "first line\nsecond line\nthird line"
  STRING_SAMPLE_UTF8 = "grüße aus münchen — 日本語もあります"

  -- Each yield is collected as an array of that yield's return values, so an iterator returning the
  -- wrong arity fails rather than quietly comparing equal on its first value.
  drain = (iterator, limit = 100) ->
    yields = {}
    for _ = 1, limit
      returned = {iterator!}
      break if returned[1] == nil
      yields[#yields + 1] = returned
    return yields

  {
    _description: "Conformance of aegisub.re against behavior captured from real Aegisub."
    _condition: ->
      return false, "aegisub.re unavailable (#{tostring re})" unless haveRe
      return haveEngine, "lrexlib-pcre2 isn't installed, so the stand-in has no engine"

    flagValues_matchBoostBits: (ut) ->
      for name, value in pairs EXPECTED_FLAG_VALUES
        flag = re[name]
        ut\assertNotNil flag, "missing flag #{name}"
        ut\assertEquals tonumber(flag.value), value, "flag #{name}"

    -- compile and the RegEx object
    compile_findSimple: (ut) ->
      result = re.compile("qu\\w*")\find STRING_SAMPLE_ASCII
      ut\assertEquals result, {{first: 5, last: 9, str: "quick"}}

    compile_findWord: (ut) ->
      result = re.compile("\\w+")\find "ab cd"
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}, {first: 4, last: 5, str: "cd"}}

    compile_emptyPatternRaises: (ut) ->
      ut\assertError -> re.compile ""

    compile_invalidPatternRaises: (ut) ->
      ut\assertError -> re.compile "(unclosed"

    -- static wrappers, one per exported function
    find_groups: (ut) ->
      result = re.find "2024-01-31", "(\\d+)-(\\d+)-(\\d+)"
      ut\assertEquals result, {{first: 1, last: 10, str: "2024-01-31"}}

    find_noMatch: (ut) ->
      ut\assertNil re.find STRING_SAMPLE_ASCII, "zzz"

    match_groups: (ut) ->
      result = re.match "2024-01-31", "(\\d+)-(\\d+)-(\\d+)"
      ut\assertEquals result, {{first: 1, last: 10, str: "2024-01-31"}, {first: 1, last: 4, str: "2024"}, {first: 6, last: 7, str: "01"}, {first: 9, last: 10, str: "31"}}

    match_noMatch: (ut) ->
      ut\assertNil re.match STRING_SAMPLE_ASCII, "zzz"

    match_wholeOnly: (ut) ->
      result = re.match STRING_SAMPLE_ASCII, "brown"
      ut\assertEquals result, {{first: 11, last: 15, str: "brown"}}

    gmatch_drained: (ut) ->
      result = drain re.gmatch "a1b2", "([a-z])(\\d)"
      ut\assertEquals result, {{{first: 1, last: 2, str: "a1"}}, {{first: 1, last: 1, str: "a"}}, {{first: 2, last: 2, str: "1"}}}

    gfind_drained: (ut) ->
      result = drain re.gfind "a1b2c3", "[a-z]\\d"
      ut\assertEquals result, {{"a1", 1, 2}, {"b2", 3, 4}, {"c3", 5, 6}}

    split_plain: (ut) ->
      result = re.split "a,b,,c", ","
      ut\assertEquals result, {"a", "b", "", "c"}

    split_skipEmpty: (ut) ->
      result = re.split "a,b,,c", ",", true
      ut\assertEquals result, {"a", "b", "c"}

    split_maxSplit: (ut) ->
      result = re.split "a,b,c,d", ",", false, 2
      ut\assertEquals result, {"a", "b", "c,d"}

    gsplit_drained: (ut) ->
      result = drain re.gsplit "a,b,c", ","
      ut\assertEquals result, {{"a"}, {"b"}, {"c"}}

    sub_stringRepl: (ut) ->
      result = re.sub "a1b2", "([a-z])(\\d)", "$2$1"
      ut\assertEquals result, "1a2b"

    sub_wholeMatchRef: (ut) ->
      result = re.sub "abc", "b", "[$&]"
      ut\assertEquals result, "a[b]c"

    sub_maxCount: (ut) ->
      result = re.sub "aaaa", "a", "b", 2
      ut\assertEquals result, "bbaa"

    sub_funcRepl: (ut) ->
      result = re.sub "a1b2", "[a-z]\\d", (str, first, last) -> str\upper! .. first .. last
      ut\assertEquals result, "A112B234"

    sub_funcReplGroups: (ut) ->
      result = re.sub "a1b2", "([a-z])(\\d)", (str) -> "<#{str}>"
      ut\assertEquals result, "<a><1><b><2>"

    sub_funcReplNonString: (ut) ->
      result = re.sub "a1b2", "[a-z]\\d", -> 42
      ut\assertEquals result, "a1b2"

    -- an unmatched optional group reports nothing, which stops the match iteration
    match_unmatchedGroupStops: (ut) ->
      result = re.match "ab", "(a)(x)?(b)"
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}, {first: 1, last: 1, str: "a"}}

    match_trailingOptionalGroup: (ut) ->
      result = re.match "ab", "(a)(b)(c)?"
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}, {first: 1, last: 1, str: "a"}, {first: 2, last: 2, str: "b"}}

    -- start offsets
    match_startOffset: (ut) ->
      result = re.compile("\\w+")\match STRING_SAMPLE_ASCII, 5
      ut\assertEquals result, {{first: 5, last: 9, str: "quick"}}

    match_startPastEnd: (ut) ->
      ut\assertNil re.compile("\\w")\match "ab", 3

    -- the Perl m modifier is on by default, so ^ and $ match at embedded newlines
    anchors_caretDefault: (ut) ->
      result = drain re.gfind STRING_SAMPLE_MULTIPLE_LINES, "^\\w+"
      ut\assertEquals result, {{"first", 1, 5}, {"second", 12, 17}, {"third", 24, 28}}

    anchors_dollarDefault: (ut) ->
      result = drain re.gfind STRING_SAMPLE_MULTIPLE_LINES, "\\w+$"
      ut\assertEquals result, {{"line", 7, 10}, {"line", 19, 22}, {"line", 30, 33}}

    anchors_caretNoModM: (ut) ->
      result = drain re.gfind STRING_SAMPLE_MULTIPLE_LINES, "^\\w+", re.NO_MOD_M
      ut\assertEquals result, {{"first", 1, 5}}

    anchors_dollarNoModM: (ut) ->
      result = drain re.gfind STRING_SAMPLE_MULTIPLE_LINES, "\\w+$", re.NO_MOD_M
      ut\assertEquals result, {{"line", 30, 33}}

    -- match_not_dot_newline is never passed, so a dot spans newlines by default
    dot_spansNewlineDefault: (ut) ->
      result = re.find "a\nb", "a.b"
      ut\assertEquals result, {{first: 1, last: 3, str: "a\nb"}}

    dot_noModS: (ut) ->
      ut\assertNil re.find "a\nb", "a.b", re.NO_MOD_S

    dot_modS: (ut) ->
      result = re.find "a\nb", "a.b", re.MOD_S
      ut\assertEquals result, {{first: 1, last: 3, str: "a\nb"}}

    -- remaining flags
    flag_icase: (ut) ->
      result = re.find "HELLO", "hello", re.ICASE
      ut\assertEquals result, {{first: 1, last: 5, str: "HELLO"}}

    flag_icaseUnicode: (ut) ->
      result = re.find "GRÜSSE", "grüsse", re.ICASE
      ut\assertEquals result, {{first: 1, last: 7, str: "GRÜSSE"}}

    flag_icaseUnicodeSharpS: (ut) ->
      ut\assertNil re.find "STRASSE", "straße", re.ICASE

    flag_modX: (ut) ->
      result = re.find "ab", "a b   # a comment\n", re.MOD_X
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}}

    flag_nosub: (ut) ->
      result = re.match "a1", "([a-z])(\\d)", re.NOSUB
      ut\assertEquals result, {{first: 1, last: 2, str: "a1"}}

    flag_collate: (ut) ->
      result = re.find "abc", "[a-c]+", re.COLLATE
      ut\assertEquals result, {{first: 1, last: 3, str: "abc"}}

    -- NEWLINE_ALT redefines what the pattern means, so the stand-in refuses it rather than matching
    -- something else; every other flag either maps onto PCRE2 or cannot change the result.
    flag_newlineAlt: (ut) ->
      if isStandIn
        ut\assertError -> re.find "b", "a\nb", re.NEWLINE_ALT
      else
        ut\assertEquals (re.find "b", "a\nb", re.NEWLINE_ALT), {{first: 1, last: 1, str: "b"}}

    flag_noEmptySubexpressions: (ut) ->
      result = re.find "ab", "a()b", re.NO_EMPTY_SUBEXPRESSIONS
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}}

    flag_multiple: (ut) ->
      ut\assertNil re.find "A\nB", "a.b", re.ICASE, re.NO_MOD_S

    flag_afterNonFlagArgsRaises: (ut) ->
      ut\assertError -> re.split "a,b", ",", re.ICASE, true

    -- passing an explicit nil for an optional argument leaves a hole in the packed varargs, and the
    -- flag past it still has to be recognized: skipEmpty stays nil while ICASE matches the upper-case B
    flag_afterNilArgument: (ut) ->
      result = re.split "a,B,,c", "b", nil, re.ICASE
      ut\assertEquals result, {"a,", ",,c"}

    -- matching is by code point, offsets are bytes
    unicode_dotCountsCodePoints: (ut) ->
      result = re.find STRING_SAMPLE_UTF8, "^...."
      ut\assertEquals result, {{first: 1, last: 6, str: "grüß"}}

    unicode_wordClass: (ut) ->
      result = drain re.gfind STRING_SAMPLE_UTF8, "\\w+"
      ut\assertEquals result, {{"grüße", 1, 7}, {"aus", 9, 11}, {"münchen", 13, 20}, {"日本語もあります", 26, 49}}

    unicode_byteOffsets: (ut) ->
      result = re.find STRING_SAMPLE_UTF8, "münchen"
      ut\assertEquals result, {{first: 13, last: 20, str: "münchen"}}

    unicode_matchOffsets: (ut) ->
      result = re.match STRING_SAMPLE_UTF8, "(aus) (münchen)"
      ut\assertEquals result, {{first: 9, last: 20, str: "aus münchen"}, {first: 9, last: 11, str: "aus"}, {first: 13, last: 20, str: "münchen"}}

    unicode_charClassRange: (ut) ->
      result = drain re.gfind "aä日", "[[:alpha:]]"
      ut\assertEquals result, {{"a", 1, 1}, {"ä", 2, 3}, {"日", 4, 6}}

    unicode_subReplacement: (ut) ->
      result = re.sub STRING_SAMPLE_UTF8, "münchen", "MÜNCHEN"
      ut\assertEquals result, "grüße aus MÜNCHEN — 日本語もあります"

    unicode_splitOnMultibyte: (ut) ->
      result = re.split "a—b—c", "—"
      ut\assertEquals result, {"a", "b", "c"}

    unicode_startOffsetMidCodePoint: (ut) ->
      ut\assertError -> re.compile(".")\match "äb", 2

    -- empty and zero-width matches
    empty_zeroWidthGfind: (ut) ->
      result = drain re.gfind("abc", "x*"), 12
      ut\assertEquals result, {{"", 1, 0}, {"", 2, 1}, {"", 3, 2}, {"", 4, 3}}

    empty_zeroWidthSub: (ut) ->
      result = re.sub "abc", "x*", "-"
      ut\assertEquals result, "-a-b-c-"

    empty_anchorOnly: (ut) ->
      result = drain re.gfind "ab", "^"
      ut\assertEquals result, {{"", 1, 0}}

    empty_subjectFind: (ut) ->
      result = re.find "", "a*"
      ut\assertEquals result, {{first: 1, last: 0, str: ""}}

    empty_subjectSplit: (ut) ->
      result = re.split "", ","
      ut\assertEquals result, {}

    empty_splitAllSeparators: (ut) ->
      result = re.split ",,,", ","
      ut\assertEquals result, {"", "", "", ""}

    empty_splitSkipEmptyAll: (ut) ->
      result = re.split ",,,", ",", true
      ut\assertEquals result, {}

    -- greediness, alternation, backreferences, lookaround
    syntax_lazyQuantifier: (ut) ->
      result = re.match "<a><b>", "<(.-?)>"
      ut\assertEquals result, {{first: 1, last: 3, str: "<a>"}, {first: 2, last: 2, str: "a"}}

    syntax_greedyQuantifier: (ut) ->
      result = re.match "<a><b>", "<(.*)>"
      ut\assertEquals result, {{first: 1, last: 6, str: "<a><b>"}, {first: 2, last: 5, str: "a><b"}}

    syntax_alternation: (ut) ->
      result = drain re.gfind "cat dog", "cat|dog"
      ut\assertEquals result, {{"cat", 1, 3}, {"dog", 5, 7}}

    syntax_backreference: (ut) ->
      result = re.find "abab", "(ab)\\1"
      ut\assertEquals result, {{first: 1, last: 4, str: "abab"}}

    syntax_lookahead: (ut) ->
      result = drain re.gfind "a1 b2", "[a-z](?=\\d)"
      ut\assertEquals result, {{"a", 1, 1}, {"b", 4, 4}}

    syntax_lookbehind: (ut) ->
      result = drain re.gfind "a1 b2", "(?<=[a-z])\\d"
      ut\assertEquals result, {{"1", 2, 2}, {"2", 5, 5}}

    syntax_namedGroup: (ut) ->
      result = re.match "ab", "(?<first>a)(?<second>b)"
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}, {first: 1, last: 1, str: "a"}, {first: 2, last: 2, str: "b"}}

    syntax_nonCapturing: (ut) ->
      result = re.match "ab", "(?:a)(b)"
      ut\assertEquals result, {{first: 1, last: 2, str: "ab"}, {first: 2, last: 2, str: "b"}}

    syntax_posixClass: (ut) ->
      result = drain re.gfind "a1 b2", "[[:digit:]]"
      ut\assertEquals result, {{"1", 2, 2}, {"2", 5, 5}}

    syntax_escapedLiteral: (ut) ->
      result = re.find "a.b", "a\\.b"
      ut\assertEquals result, {{first: 1, last: 3, str: "a.b"}}

    syntax_wordBoundary: (ut) ->
      result = drain re.gfind "cat cats", "\\bcat\\b"
      ut\assertEquals result, {{"cat", 1, 3}}

    _order: {"flagValues_matchBoostBits", "compile_findSimple", "compile_findWord",
      "compile_emptyPatternRaises", "compile_invalidPatternRaises", "find_groups", "find_noMatch",
      "match_groups", "match_noMatch", "match_wholeOnly", "gmatch_drained", "gfind_drained", "split_plain",
      "split_skipEmpty", "split_maxSplit", "gsplit_drained", "sub_stringRepl", "sub_wholeMatchRef",
      "sub_maxCount", "sub_funcRepl", "sub_funcReplGroups", "sub_funcReplNonString",
      "match_unmatchedGroupStops", "match_trailingOptionalGroup", "match_startOffset", "match_startPastEnd",
      "anchors_caretDefault", "anchors_dollarDefault", "anchors_caretNoModM", "anchors_dollarNoModM",
      "dot_spansNewlineDefault", "dot_noModS", "dot_modS", "flag_icase", "flag_icaseUnicode",
      "flag_icaseUnicodeSharpS", "flag_modX", "flag_nosub", "flag_collate", "flag_newlineAlt",
      "flag_noEmptySubexpressions", "flag_multiple", "flag_afterNonFlagArgsRaises", "flag_afterNilArgument",
      "unicode_dotCountsCodePoints", "unicode_wordClass", "unicode_byteOffsets", "unicode_matchOffsets",
      "unicode_charClassRange", "unicode_subReplacement", "unicode_splitOnMultibyte",
      "unicode_startOffsetMidCodePoint", "empty_zeroWidthGfind", "empty_zeroWidthSub", "empty_anchorOnly",
      "empty_subjectFind", "empty_subjectSplit", "empty_splitAllSeparators", "empty_splitSkipEmptyAll",
      "syntax_lazyQuantifier", "syntax_greedyQuantifier", "syntax_alternation", "syntax_backreference",
      "syntax_lookahead", "syntax_lookbehind", "syntax_namedGroup", "syntax_nonCapturing",
      "syntax_posixClass", "syntax_escapedLiteral", "syntax_wordBoundary"}
  }
