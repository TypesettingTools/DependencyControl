-- Pins the behavior of `aegisub.util`. The same corpus runs in both environments: inside Aegisub it
-- checks the live module, while under the CLI the preload in l0.AegisubShims swaps in the stand-in, so
-- the run doubles as the stand-in's conformance test. The stand-in isn't a feed package of its own, so
-- these tests ride along with DependencyControl's suite.
-- Called from test.moon as: (controls\requireTest "aegisub-util")!
->
  -- Requiring l0.AegisubShims.util directly would resolve only under the CLI: inside Aegisub the shim
  -- package isn't deployed at all, so the require fails and takes the whole suite's setup down with it.
  haveUtil, util = pcall require, "aegisub.util"

  -- The preload only fires outside Aegisub, so this distinguishes the stand-in from the real module
  -- without either of them having to advertise which it is.
  isStandIn = package.loaded["l0.AegisubShims.util"] == util

  -- HSV components come back as unrounded floats, so a conversion that lands on a whole number can
  -- still sit an ulp away from it; compare those with a tolerance
  assertRgbAlmostEquals = (ut, actual, expected) ->
    ut\assertAlmostEquals actual[i], expected[i] for i = 1, 3

  {
    _description: "Conformance of aegisub.util, and of the headless stand-in that replaces it."
    _condition: -> haveUtil, "aegisub.util unavailable (#{tostring util})"

    -- the require-id mapping only exists once l0.AegisubShims has installed it, which never happens
    -- inside Aegisub; gate on it so this file stays runnable in both environments
    preload_claimsAegisubUtilRequireId: (ut) ->
      ut\skip "l0.AegisubShims isn't loaded" unless isStandIn
      loader = package.preload["aegisub.util"]
      ut\assertFunction loader
      ut\assertIs loader!, util

    -- tables

    copy_detachesTopLevelOnly: (ut) ->
      nested = {"deep"}
      source = {a: 1, nested: nested}
      copied = util.copy source
      ut\assertIsNot copied, source
      ut\assertEquals copied.a, 1
      ut\assertIs copied.nested, nested

    deep_copy_detachesNestedTables: (ut) ->
      source = {nested: {deep: {"x"}}}
      copied = util.deep_copy source
      ut\assertIsNot copied.nested, source.nested
      ut\assertIsNot copied.nested.deep, source.nested.deep
      source.nested.deep[1] = "mutated"
      ut\assertEquals copied.nested.deep[1], "x"

    -- Aegisub builds before its upstream fix register a source table against itself instead of against
    -- its copy, so a repeated or cyclic reference resolves back to the original and the copy ends up
    -- aliasing what it was meant to detach from. The stand-in registers the copy, so only it can be
    -- held to this; on such a build the live module fails all three of these.
    deep_copy_preservesCyclesAndSharedIdentity: (ut) ->
      ut\skip "Aegisub's deep_copy aliases the source on a repeated reference" unless isStandIn
      shared = {"x"}
      source = {first: shared, second: shared}
      source.self = source
      copied = util.deep_copy source
      ut\assertIsNot copied.first, shared
      ut\assertIs copied.first, copied.second
      ut\assertIs copied.self, copied

    copy_rejectsNonTable: (ut) ->
      ut\assertError util.copy, 5
      ut\assertError util.deep_copy, "not a table"

    -- color formatting

    ass_color_ordersComponentsAsBGR: (ut) ->
      ut\assertEquals util.ass_color(255, 128, 0), "&H0080FF&"
      ut\assertEquals util.ass_color(0, 0, 0), "&H000000&"

    ass_alpha_formatsSingleComponent: (ut) ->
      ut\assertEquals util.ass_alpha(128), "&H80&"
      ut\assertEquals util.ass_alpha(255), "&HFF&"

    ass_style_color_ordersComponentsAsABGR: (ut) ->
      ut\assertEquals util.ass_style_color(255, 128, 0, 64), "&H400080FF"

    -- color extraction

    extract_color_readsEveryNotation: (ut) ->
      ut\assertItemsEqual {util.extract_color "&H12345678"}, {120, 86, 52, 18} -- style definition
      ut\assertItemsEqual {util.extract_color "&H123456&"}, {86, 52, 18, 0} -- color override
      ut\assertItemsEqual {util.extract_color "&H80&"}, {0, 0, 0, 128} -- alpha override
      ut\assertItemsEqual {util.extract_color "#AABBCC"}, {170, 187, 204, 0} -- HTML

    -- an unrecognized string yields no values at all, which reads as nil at the call site
    extract_color_returnsNothingForUnrecognized: (ut) ->
      ut\assertNil util.extract_color "garbage"
      ut\assertEquals select("#", util.extract_color "garbage"), 0

    extract_color_rejectsNonString: (ut) ->
      ut\assertError util.extract_color, 42

    alpha_from_style_takesAlphaComponent: (ut) ->
      ut\assertEquals util.alpha_from_style("&H12345678"), "&H12&"

    color_from_style_dropsAlpha: (ut) ->
      ut\assertEquals util.color_from_style("&H12345678"), "&H345678&"

    -- color space conversion

    HSV_to_RGB_convertsKnownColors: (ut) ->
      assertRgbAlmostEquals ut, {util.HSV_to_RGB(0, 1, 1)}, {255, 0, 0}
      assertRgbAlmostEquals ut, {util.HSV_to_RGB(120, 1, 1)}, {0, 255, 0}
      assertRgbAlmostEquals ut, {util.HSV_to_RGB(210, 0.5, 0.8)}, {102, 153, 204}

    -- HSV keeps the raw floats where HSL rounds to whole bytes
    HSV_to_RGB_greyIsUnroundedAtZeroSaturation: (ut) ->
      assertRgbAlmostEquals ut, {util.HSV_to_RGB(0, 0, 0.5)}, {127.5, 127.5, 127.5}
      ut\assertItemsEqual {util.HSL_to_RGB(0, 0, 0.5)}, {128, 128, 128}

    HSL_to_RGB_convertsKnownColors: (ut) ->
      ut\assertItemsEqual {util.HSL_to_RGB(0, 1, 0.5)}, {255, 0, 0}
      ut\assertItemsEqual {util.HSL_to_RGB(210, 0.5, 0.8)}, {179, 204, 230}

    -- the hue is folded by absolute value before the modulo, so a negative angle mirrors onto the
    -- positive half of the circle instead of completing it: -150° lands on 150°, not 210°
    HSL_to_RGB_foldsNegativeHueAndClampsSaturation: (ut) ->
      ut\assertItemsEqual {util.HSL_to_RGB(-150, 1.5, 0.5)}, {util.HSL_to_RGB(150, 1, 0.5)}
      ut\assertItemsEqual {util.HSL_to_RGB(-150, 1.5, 0.5)}, {0, 255, 128}

    -- strings

    -- the second return value is gsub's replacement count, which Aegisub's module passes on as well
    trim_stripsAndReportsReplacementCount: (ut) ->
      trimmed, replacements = util.trim "  padded  "
      ut\assertEquals trimmed, "padded"
      ut\assertEquals replacements, 1
      ut\assertEquals util.trim("nothing to strip"), "nothing to strip"

    headtail_splitsAtFirstWhitespaceRun: (ut) ->
      head, tail = util.headtail "hello  world  again"
      ut\assertEquals head, "hello"
      ut\assertEquals tail, "world  again"

    headtail_wholeStringWhenNoWhitespace: (ut) ->
      head, tail = util.headtail "single"
      ut\assertEquals head, "single"
      ut\assertEquals tail, ""

    words_iteratesWhitespaceSeparated: (ut) ->
      collected = [word for word in util.words "hello  world again"]
      ut\assertItemsEqual collected, {"hello", "world", "again"}
      ut\assertEquals #[word for word in util.words ""], 0

    -- numbers

    clamp_boundsValue: (ut) ->
      ut\assertEquals util.clamp(-1, 0, 1), 0
      ut\assertEquals util.clamp(2, 0, 1), 1
      ut\assertEquals util.clamp(0.5, 0, 1), 0.5

    interpolate_snapsOutsideUnitRange: (ut) ->
      ut\assertEquals util.interpolate(-1, 10, 20), 10
      ut\assertEquals util.interpolate(2, 10, 20), 20
      ut\assertEquals util.interpolate(0.25, 10, 20), 12.5

    interpolate_color_blendsComponents: (ut) ->
      ut\assertEquals util.interpolate_color(0.5, "&H000000&", "&HFFFFFF&"), "&H7F7F7F&"
      ut\assertEquals util.interpolate_color(0, "&H000000&", "&HFFFFFF&"), "&H000000&"

    interpolate_alpha_blendsAlphaComponents: (ut) ->
      ut\assertEquals util.interpolate_alpha(0.5, "&H00&", "&HFF&"), "&H7F&"
      ut\assertEquals util.interpolate_alpha(1, "&H00&", "&HFF&"), "&HFF&"

    _order: {
      "preload_claimsAegisubUtilRequireId",
      "copy_detachesTopLevelOnly", "deep_copy_detachesNestedTables",
      "deep_copy_preservesCyclesAndSharedIdentity", "copy_rejectsNonTable",
      "ass_color_ordersComponentsAsBGR", "ass_alpha_formatsSingleComponent",
      "ass_style_color_ordersComponentsAsABGR",
      "extract_color_readsEveryNotation", "extract_color_returnsNothingForUnrecognized",
      "extract_color_rejectsNonString", "alpha_from_style_takesAlphaComponent",
      "color_from_style_dropsAlpha",
      "HSV_to_RGB_convertsKnownColors", "HSV_to_RGB_greyIsUnroundedAtZeroSaturation",
      "HSL_to_RGB_convertsKnownColors", "HSL_to_RGB_foldsNegativeHueAndClampsSaturation",
      "trim_stripsAndReportsReplacementCount", "headtail_splitsAtFirstWhitespaceRun",
      "headtail_wholeStringWhenNoWhitespace", "words_iteratesWhitespaceSeparated",
      "clamp_boundsValue", "interpolate_snapsOutsideUnitRange",
      "interpolate_color_blendsComponents", "interpolate_alpha_blendsAlphaComponents"
    }
  }
