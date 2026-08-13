-- Pins the CoreText text-extents backend. Its Windows-cell derivation is shared, and pinned against
-- native TEXTMETRIC reads in aegisub-gdi-metrics; what is left here needs the CTFont call layer, so
-- those tests run only on macOS.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents-coretext")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"
  haveCoreText, coretext = pcall require, "l0.AegisubShims.text-extents-backends.coretext"
  haveGdi, gdi = pcall require, "l0.AegisubShims.text-extents-backends.gdi"

  baseStyle = (overrides) ->
    style = shims.Ass.createStyle {fontname: "Helvetica", fontsize: 40}
    style[key] = value for key, value in pairs overrides or {}
    return style

  {
    _description: "The CoreText text-extents backend, whose call layer runs only on macOS."

    measure_raisesWhereCoreTextIsUnreachable: (ut) ->
      return ut\skip "CoreText is available here" if coretext.isAvailable
      ut\assertErrorMsgMatches (-> coretext.measure baseStyle!, "Hello"), {}, "needs CoreText"

    -- the options are checked as the backend is built, before anything reaches CoreText
    createBackend_rejectsAnUnknownVerticalMetricFallback: (ut) ->
      ut\assertErrorMsgMatches (-> coretext.createBackend {verticalMetricFallback: 99}), {},
        "Invalid value"

    -- the invariants below need the CTFont call layer, so they run only on macOS

    measure_emptyStringHasNoExtent: (ut) ->
      return ut\skip "needs CoreText" unless coretext.isAvailable
      width, height, descent, extlead = coretext.measure baseStyle!, ""
      ut\assertZero width
      ut\assertZero height
      ut\assertGreaterThan descent, 0
      ut\assertGreaterThanOrEquals extlead, 0

    measure_heightIsTheNominalFontSize: (ut) ->
      return ut\skip "needs CoreText" unless coretext.isAvailable
      _, height = coretext.measure baseStyle(fontsize: 37), "Hello"
      ut\assertAlmostEquals height, 37

    measure_scaleXMultipliesWidthOnly: (ut) ->
      return ut\skip "needs CoreText" unless coretext.isAvailable
      width, height, descent, extlead = coretext.measure baseStyle!, "Hello"
      wide, wideHeight, wideDescent, wideExtlead = coretext.measure baseStyle(scale_x: 200), "Hello"
      ut\assertAlmostEquals wide, width * 2
      ut\assertAlmostEquals wideHeight, height
      ut\assertAlmostEquals wideDescent, descent
      ut\assertAlmostEquals wideExtlead, extlead

    measure_spacingIsAddedPerCharacter: (ut) ->
      return ut\skip "needs CoreText" unless coretext.isAvailable
      atOne = coretext.measure baseStyle(spacing: 1), "Hello"
      atTwo = coretext.measure baseStyle(spacing: 2), "Hello"
      ut\assertAlmostEquals atTwo - atOne, 5

    measure_rejectsMalformedUtf8Text: (ut) ->
      return ut\skip "needs CoreText" unless coretext.isAvailable
      ut\assertErrorMsgMatches (-> coretext.measure baseStyle!, "bad\255text"), {}, "not valid UTF%-8"

    shims_installTheBackendWhereOnlyCoreTextIsAvailable: (ut) ->
      return ut\skip "needs CoreText" unless haveShims and coretext.isAvailable
      return ut\skip "GDI is available here, so it is installed instead" if haveGdi and gdi.isAvailable
      ut\assertIs shims.getTextExtentsBackend!, coretext.measure
  }
