-- cspell:ignore AVAVAV -- non-ASCII and kerning-pair samples, which are the fixtures themselves
-- Pins the FreeType text-extents backend against the relationships it holds to whatever fonts the
-- machine has, rather than against captured numbers: fontconfig substitutes what it likes for a family
-- that is not installed, so the absolute values differ per machine. Agreement with GDI is checked
-- separately, by running both against the same font files; see text-extents-investigation/README.md.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents-freetype")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"
  haveFreeType, freetype = pcall require, "l0.AegisubShims.text-extents-backends.freetype"
  haveGdi, gdi = pcall require, "l0.AegisubShims.text-extents-backends.gdi"

  -- a family every fontconfig install resolves to something for, installed or not
  baseStyle = (overrides) ->
    style = shims.Ass.createStyle {fontname: "sans-serif", fontsize: 40}
    style[key] = value for key, value in pairs overrides or {}
    return style

  local measureLinux
  measureLinux = freetype.createBackend {metricMode: freetype.MetricMode.AegisubLinux} if haveFreeType and freetype.isAvailable

  {
    _description: "The FreeType text-extents backend, against the invariants both metric modes hold to."
    _condition: ->
      return haveShims and haveFreeType and freetype.isAvailable, "needs FreeType and fontconfig"

    measure_emptyStringHasNoExtent: (ut) ->
      width, height = freetype.measure baseStyle!, ""
      ut\assertZero width
      ut\assertZero height

    -- Aegisub on Linux reports the line height for an empty run where Windows reports zero, so the
    -- mode that stands in for it has to keep the height its measurement never took
    measure_linuxModeKeepsTheHeightOfAnEmptyString: (ut) ->
      width, height = measureLinux baseStyle(fontsize: 37), ""
      ut\assertZero width
      ut\assertAlmostEquals height, 37

    -- with spacing set, Aegisub measures character by character and an empty run never reaches a
    -- measurement at all, so even the Linux mode reports nothing — descent and leading included
    measure_linuxModeDropsEveryMetricOfAnEmptyStringWithSpacing: (ut) ->
      width, height, descent, extlead = measureLinux baseStyle(fontsize: 37, spacing: 1), ""
      ut\assertZero width
      ut\assertZero height
      ut\assertZero descent
      ut\assertZero extlead

    -- descent comes from the face's metrics rather than the run, so it survives an empty string
    measure_faceMetricsAreReportedForAnEmptyString: (ut) ->
      _, _, descent, extlead = freetype.measure baseStyle!, ""
      ut\assertGreaterThan descent, 0
      ut\assertGreaterThanOrEquals extlead, 0

    -- both modes normalize onto the requested cell, which is what the style asked for
    measure_heightIsTheNominalFontSize: (ut) ->
      _, height = freetype.measure baseStyle(fontsize: 37), "Hello"
      _, linuxHeight = measureLinux baseStyle(fontsize: 37), "Hello"
      ut\assertAlmostEquals height, 37
      ut\assertAlmostEquals linuxHeight, 37

    measure_widthGrowsWithText: (ut) ->
      short = freetype.measure baseStyle!, "i"
      long = freetype.measure baseStyle!, "iiiiiiiiii"
      ut\assertGreaterThan long, short

    -- advance width, not inked width: a run of spaces has to measure wider than nothing
    measure_trailingSpacesAddWidth: (ut) ->
      bare = freetype.measure baseStyle!, "Hi"
      padded = freetype.measure baseStyle!, "Hi   "
      ut\assertGreaterThan padded, bare

    measure_scaleXMultipliesWidthOnly: (ut) ->
      width, height, descent, extlead = freetype.measure baseStyle!, "Hello"
      wide, wideHeight, wideDescent, wideExtlead = freetype.measure baseStyle(scale_x: 200), "Hello"

      ut\assertAlmostEquals wide, width * 2
      ut\assertAlmostEquals wideHeight, height
      ut\assertAlmostEquals wideDescent, descent
      ut\assertAlmostEquals wideExtlead, extlead

    measure_scaleYMultipliesTheVerticalMetrics: (ut) ->
      width, height, descent, extlead = freetype.measure baseStyle!, "Hello"
      tall, tallHeight, tallDescent, tallExtlead = freetype.measure baseStyle(scale_y: 200), "Hello"

      ut\assertAlmostEquals tall, width
      ut\assertAlmostEquals tallHeight, height * 2
      ut\assertAlmostEquals tallDescent, descent * 2
      ut\assertAlmostEquals tallExtlead, extlead * 2

    -- spacing is added once per character, so raising it by one widens a five-character run by five
    measure_spacingIsAddedPerCharacter: (ut) ->
      atOne = freetype.measure baseStyle(spacing: 1), "Hello"
      atTwo = freetype.measure baseStyle(spacing: 2), "Hello"
      ut\assertAlmostEquals atTwo - atOne, 5

    -- an astral character is one character here, where Aegisub's Windows path counts it twice
    measure_spacingCountsAnAstralCharacterOnce: (ut) ->
      atOne = freetype.measure baseStyle(spacing: 1), "\240\159\152\128"
      atTwo = freetype.measure baseStyle(spacing: 2), "\240\159\152\128"
      ut\assertAlmostEquals atTwo - atOne, 1

    measure_boldIsNeverNarrowerThanRegular: (ut) ->
      regular = freetype.measure baseStyle!, "Hello"
      bold = freetype.measure baseStyle(bold: true), "Hello"
      ut\assertGreaterThanOrEquals bold, regular

    -- fontconfig substitutes for a family nothing provides, so a measurement still comes back
    measure_unknownFamilyStillMeasures: (ut) ->
      width = freetype.measure baseStyle(fontname: "NoSuchFontExistsHere"), "Hello"
      ut\assertGreaterThan width, 0

    measure_nonPositiveFontSizeHasNoExtent: (ut) ->
      width, height, descent, extlead = freetype.measure baseStyle(fontsize: 0), "Hello"
      ut\assertZero width
      ut\assertZero height
      ut\assertZero descent
      ut\assertZero extlead

    measure_rejectsMalformedUtf8Text: (ut) ->
      ut\assertErrorMsgMatches (-> freetype.measure baseStyle!, "bad\255text"), {}, "not valid UTF%-8"

    -- a face carrying no kern table kerns to the same width, so this only ever narrows
    createBackend_kerningNeverWidensAKerningPair: (ut) ->
      withoutKerning = freetype.createBackend {kerning: false}
      withKerning = freetype.createBackend {kerning: true}
      ut\assertLessThanOrEquals withKerning(baseStyle!, "AVAVAV"), withoutKerning(baseStyle!, "AVAVAV")

    -- inter-character spacing measures the characters apart, which rules kerning out either way
    createBackend_spacingSuppressesKerning: (ut) ->
      withoutKerning = freetype.createBackend {kerning: false}
      withKerning = freetype.createBackend {kerning: true}
      spaced = baseStyle spacing: 3
      ut\assertAlmostEquals withKerning(spaced, "AVAVAV"), withoutKerning(spaced, "AVAVAV")

    createBackend_rejectsUnknownMetricMode: (ut) ->
      ut\assertErrorMsgMatches (-> freetype.createBackend {metricMode: 99}), {}, "Invalid value"

    -- The Linux contract divides its measurement by the line height, which leaves the spacing term
    -- scaled by the resolution the text was realized at. Doubling that halves what spacing adds.
    createBackend_resolutionScalesTheLinuxSpacingTerm: (ut) ->
      atDefault = freetype.createBackend {metricMode: freetype.MetricMode.AegisubLinux}
      atHighDpi = freetype.createBackend {
        metricMode: freetype.MetricMode.AegisubLinux, dpi: 192
      }
      solid, spaced = baseStyle!, baseStyle spacing: 4
      addedAtDefault = atDefault(spaced, "Hello") - atDefault(solid, "Hello")
      addedAtHighDpi = atHighDpi(spaced, "Hello") - atHighDpi(solid, "Hello")
      ut\assertGreaterThan addedAtDefault, 0
      ut\assertAlmostEquals addedAtHighDpi / addedAtDefault, 0.5, 0.001

    -- GDI adds spacing to each advance as given, with no measurement to normalize against
    createBackend_resolutionLeavesTheWindowsContractAlone: (ut) ->
      atDefault = freetype.createBackend!
      atHighDpi = freetype.createBackend {dpi: 192}
      solid, spaced = baseStyle!, baseStyle spacing: 4
      ut\assertAlmostEquals atHighDpi(spaced, "Hello"), atDefault(spaced, "Hello")
      -- and it adds exactly what the style asked for, five characters at four units each
      ut\assertAlmostEquals atDefault(spaced, "Hello") - atDefault(solid, "Hello"), 20

    createBackend_rejectsANonPositiveResolution: (ut) ->
      ut\assertErrorMsgMatches (-> freetype.createBackend {dpi: -1}), {}, "positive"

    createBackend_rejectsNonTableOptions: (ut) ->
      ut\assertError freetype.createBackend, "Face"

    -- the umbrella installs GDI where it can and falls back to this backend everywhere else
    shims_installTheBackendWhereGdiIsUnavailable: (ut) ->
      return ut\skip "GDI is available here, so it is installed instead" if haveGdi and gdi.isAvailable
      ut\assertIs shims.getTextExtentsBackend!, freetype.measure
  }
