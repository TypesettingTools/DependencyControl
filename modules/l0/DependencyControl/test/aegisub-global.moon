-- Pins the parts of the faux `aegisub` global that carry a contract of their own, rather than standing
-- in for something Aegisub computes. Inside Aegisub the global is the real API, so these run only
-- against the stand-in.
-- Called from test.moon as: (controls\requireTest "aegisub-global")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"

  STYLE_SAMPLE = {fontname: "Arial", fontsize: 40, bold: false, spacing: 0, scale_x: 100, scale_y: 100}

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
