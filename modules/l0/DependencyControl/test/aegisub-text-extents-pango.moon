-- Pins the Pango text-extents backend against the invariants of the contract it reproduces, and
-- against the FreeType backend's AegisubLinux mode, which emulates the same measurements: on text a
-- single face sets without kerning, the two have to agree closely. Absolute values differ per
-- machine, since fontconfig substitutes what it likes; agreement with a running Aegisub is checked
-- separately, by diffing dumps over a shared corpus; see text-extents-investigation/README.md.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents-pango")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"
  havePango, pangoBackend = pcall require, "l0.AegisubShims.text-extents-backends.pango"
  haveFreeType, freetype = pcall require, "l0.AegisubShims.text-extents-backends.freetype"

  -- a family every fontconfig install resolves to something for, installed or not
  baseStyle = (overrides) ->
    style = shims.Ass.createStyle {fontname: "sans-serif", fontsize: 40}
    style[key] = value for key, value in pairs overrides or {}
    return style

  {
    _description: "The Pango text-extents backend, against the Aegisub-on-Linux contract it reproduces."
    _condition: ->
      return haveShims and havePango and pangoBackend.isAvailable, "needs Pango, pangocairo and GObject"

    measure_keepsTheHeightOfAnEmptyString: (ut) ->
      width, height = pangoBackend.measure baseStyle(fontsize: 37), ""
      ut\assertZero width
      ut\assertAlmostEquals height, 37

    -- with spacing set, the measurement runs character by character and an empty run never reaches
    -- a measurement at all, so every metric stays zero, descent included
    measure_dropsEveryMetricOfAnEmptyStringWithSpacing: (ut) ->
      width, height, descent, extlead = pangoBackend.measure baseStyle(fontsize: 37, spacing: 1), ""
      ut\assertZero width
      ut\assertZero height
      ut\assertZero descent
      ut\assertZero extlead

    measure_heightIsTheNominalFontSize: (ut) ->
      _, height = pangoBackend.measure baseStyle(fontsize: 37), "Hello"
      ut\assertAlmostEquals height, 37

    measure_externalLeadingIsAlwaysZero: (ut) ->
      _, _, _, extlead = pangoBackend.measure baseStyle!, "Hello"
      ut\assertZero extlead

    measure_widthGrowsWithText: (ut) ->
      short = pangoBackend.measure baseStyle!, "i"
      long = pangoBackend.measure baseStyle!, "iiiiiiiiii"
      ut\assertGreaterThan long, short

    -- advance width, not inked width: a run of spaces has to measure wider than nothing
    measure_trailingSpacesAddWidth: (ut) ->
      bare = pangoBackend.measure baseStyle!, "Hi"
      padded = pangoBackend.measure baseStyle!, "Hi   "
      ut\assertGreaterThan padded, bare

    measure_scaleXMultipliesWidthOnly: (ut) ->
      width, height, descent = pangoBackend.measure baseStyle!, "Hello"
      wide, wideHeight, wideDescent = pangoBackend.measure baseStyle(scale_x: 200), "Hello"

      ut\assertAlmostEquals wide, width * 2
      ut\assertAlmostEquals wideHeight, height
      ut\assertAlmostEquals wideDescent, descent

    measure_scaleYMultipliesTheVerticalMetrics: (ut) ->
      width, height, descent = pangoBackend.measure baseStyle!, "Hello"
      tall, tallHeight, tallDescent = pangoBackend.measure baseStyle(scale_y: 200), "Hello"

      ut\assertAlmostEquals tall, width
      ut\assertAlmostEquals tallHeight, height * 2
      ut\assertAlmostEquals tallDescent, descent * 2

    -- The absolute widening per character depends on the face's line height, since Aegisub's Linux
    -- branch normalizes the added spacing along with everything else. The per-character count does
    -- not: the same face widens a five-character run exactly two and a half times as much as a
    -- two-character one.
    measure_spacingIsAddedPerCharacter: (ut) ->
      fiveAtOne = pangoBackend.measure baseStyle(spacing: 1), "Hello"
      fiveAtTwo = pangoBackend.measure baseStyle(spacing: 2), "Hello"
      twoAtOne = pangoBackend.measure baseStyle(spacing: 1), "Hi"
      twoAtTwo = pangoBackend.measure baseStyle(spacing: 2), "Hi"
      ut\assertAlmostEquals (fiveAtTwo - fiveAtOne) / (twoAtTwo - twoAtOne), 2.5, 0.01

    -- One character, not one byte: a two-byte character drawn from the same face widens like one
    -- ASCII character, where a per-byte count would double it. An astral character would prove the
    -- same but may fall back to a face with a different line height, which changes the widening.
    measure_spacingCountsAMultiByteCharacterOnce: (ut) ->
      fiveAtOne = pangoBackend.measure baseStyle(spacing: 1), "Hello"
      fiveAtTwo = pangoBackend.measure baseStyle(spacing: 2), "Hello"
      oneAtOne = pangoBackend.measure baseStyle(spacing: 1), "ü"
      oneAtTwo = pangoBackend.measure baseStyle(spacing: 2), "ü"
      ut\assertAlmostEquals (fiveAtTwo - fiveAtOne) / (oneAtTwo - oneAtOne), 5, 0.01

    -- fontconfig substitutes for a family nothing provides, so a measurement still comes back
    measure_unknownFamilyStillMeasures: (ut) ->
      width = pangoBackend.measure baseStyle(fontname: "NoSuchFontExistsHere"), "Hello"
      ut\assertGreaterThan width, 0

    measure_nonPositiveFontSizeHasNoExtent: (ut) ->
      width, height, descent, extlead = pangoBackend.measure baseStyle(fontsize: 0), "Hello"
      ut\assertZero width
      ut\assertZero height
      ut\assertZero descent
      ut\assertZero extlead

    measure_rejectsMalformedUtf8Text: (ut) ->
      ut\assertErrorMsgMatches (-> pangoBackend.measure baseStyle!, "bad\255text"), {}, "not valid UTF%-8"

    -- both stand in for the same Aegisub measurement, so on solid text with no kerning pairs they
    -- have to land within the FreeType emulation's own documented distance from the real thing
    measure_agreesWithTheFreeTypeLinuxModeOnSolidText: (ut) ->
      return ut\skip "needs the FreeType backend for comparison" unless haveFreeType and freetype.isAvailable
      measureLinux = freetype.createBackend {metricMode: freetype.MetricMode.AegisubLinux}
      style = baseStyle!
      pangoWidth = pangoBackend.measure style, "iiiiiiiiii"
      freetypeWidth = measureLinux style, "iiiiiiiiii"
      ut\assertAlmostEquals pangoWidth, freetypeWidth, freetypeWidth * 0.02

    -- the default backend keeps the Windows contract, so this one is never installed by the umbrella
    shims_neverInstallTheBackendByDefault: (ut) ->
      ut\assertIsNot shims.getTextExtentsBackend!, pangoBackend.measure

    -- Only the spacing term reads the resolution; a run measured solid normalizes it away, leaving
    -- at most the whole-pixel rounding underneath.
    createBackend_resolutionLeavesSolidTextAlone: (ut) ->
      atDefault = pangoBackend.createBackend!
      atHighDpi = pangoBackend.createBackend {dpi: 192}
      style = baseStyle!
      ut\assertAlmostEquals atHighDpi(style, "Hello"), atDefault(style, "Hello"), 0.05

    -- doubling the resolution halves what a unit of spacing adds to each character's advance
    createBackend_resolutionScalesTheSpacingTerm: (ut) ->
      atDefault = pangoBackend.createBackend!
      atHighDpi = pangoBackend.createBackend {dpi: 192}
      solid, spaced = baseStyle!, baseStyle spacing: 4
      addedAtDefault = atDefault(spaced, "Hello") - atDefault(solid, "Hello")
      addedAtHighDpi = atHighDpi(spaced, "Hello") - atHighDpi(solid, "Hello")
      ut\assertGreaterThan addedAtDefault, 0
      ut\assertAlmostEquals addedAtHighDpi / addedAtDefault, 0.5, 0.01

    createBackend_rejectsANonPositiveResolution: (ut) ->
      ut\assertErrorMsgMatches (-> pangoBackend.createBackend {dpi: 0}), {}, "positive"

    createBackend_rejectsNonTableOptions: (ut) ->
      ut\assertError pangoBackend.createBackend, "Face"
  }
