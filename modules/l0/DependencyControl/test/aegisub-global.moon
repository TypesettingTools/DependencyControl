-- Pins the parts of the faux `aegisub` global that carry a contract of their own, rather than standing
-- in for something Aegisub computes. Inside Aegisub the global is the real API, so these run only
-- against the stand-in.
-- Called from test.moon as: (controls\requireTest "aegisub-global")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"

  STYLE_SAMPLE = haveShims and shims.Ass.createStyle {fontname: "Arial", fontsize: 40}

  {
    _description: "The faux aegisub global's own contracts, chiefly its text-extents backend hook."
    _condition: -> haveShims, "l0.AegisubShims isn't loaded (#{tostring shims})"

    ---@param ut UnitTest
    _setup: (ut) -> {restore: shims.getTextExtentsBackend!}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      shims.setTextExtentsBackend ctx.restore if ctx

    -- font metrics need a font engine, so measuring raises until a harness supplies one; inventing
    -- numbers would let a layout script produce plausible, wrong coordinates
    textExtents_raisesWhileNoBackendIsInstalled: (ut) ->
      shims.setTextExtentsBackend nil
      ut\assertNil shims.getTextExtentsBackend!
      ut\assertError aegisub.text_extents, STYLE_SAMPLE, "measure me"

    textExtents_handsTheStyleAndTextToTheBackend: (ut) ->
      seen = nil
      shims.setTextExtentsBackend (style, text) ->
        seen = {:style, :text}
        return 12, 34, 5, 6

      width, height, descent, extlead = aegisub.text_extents STYLE_SAMPLE, "measure me"
      ut\assertEquals {width, height, descent, extlead}, {12, 34, 5, 6}
      ut\assertIs seen.style, STYLE_SAMPLE
      ut\assertEquals seen.text, "measure me"

    -- Aegisub takes these through get_bool_field, which raises on a non-boolean, so a numeric weight
    -- never reaches its measurement. Zero is truthy in Lua, so silently accepting one here would
    -- measure a style that asked for no weight at all as bold.
    textExtents_rejectsANonBooleanWhereAegisubWouldRaise: (ut) ->
      shims.setTextExtentsBackend -> 1, 1, 1, 1
      for field in *{"bold", "italic", "underline", "strikeout"}
        for value in *{0, 700, "yes"}
          _, err = pcall aegisub.text_extents, shims.Ass.createStyle({[field]: value}), "measure me"
          ut\assertMatches err, "Invalid or missing field '#{field}'"
          ut\assertMatches err, "expected boolean"

    -- Aegisub converts the whole style before measuring, so it refuses one missing a field its own
    -- measurement never reads. A partial style passing here would fail the moment it ran in Aegisub.
    textExtents_rejectsAStyleAegisubWouldRefuse: (ut) ->
      shims.setTextExtentsBackend -> 7, 7, 7, 7
      _, noClass = pcall aegisub.text_extents, {fontname: "Arial", fontsize: 40}, "measure me"
      ut\assertMatches noClass, "Not a style entry"

      partial = shims.Ass.createStyle!
      partial.margin_r = nil
      _, missing = pcall aegisub.text_extents, partial, "measure me"
      ut\assertMatches missing, "Invalid or missing field 'margin_r'"
      -- the type the field actually wants, which Aegisub's own message gets wrong for a number
      ut\assertMatches missing, "expected number"

    setTextExtentsBackend_returnsThePreviousOne: (ut) ->
      first = -> 1, 1, 1, 1
      shims.setTextExtentsBackend first
      ut\assertIs shims.setTextExtentsBackend(-> 2, 2, 2, 2), first
      ut\assertIsNot shims.getTextExtentsBackend!, first

    setTextExtentsBackend_nilLeavesMeasuringUnavailable: (ut) ->
      shims.setTextExtentsBackend -> 1, 1, 1, 1
      shims.setTextExtentsBackend nil
      ut\assertNil shims.getTextExtentsBackend!
      ut\assertError aegisub.text_extents, STYLE_SAMPLE, "measure me"

    setTextExtentsBackend_rejectsANonFunction: (ut) ->
      ut\assertError shims.setTextExtentsBackend, 42
      ut\assertError shims.setTextExtentsBackend, {}
      ut\assertError shims.setTextExtentsBackend, "nope"
  }
