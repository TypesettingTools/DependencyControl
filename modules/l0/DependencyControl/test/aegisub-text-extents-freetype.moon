-- cspell:ignore AVAVAV -- non-ASCII and kerning-pair samples, which are the fixtures themselves
-- Pins the FreeType text-extents backend against the relationships it holds to whatever fonts the
-- machine has, rather than against captured numbers: fontconfig substitutes what it likes for a family
-- that is not installed, so the absolute values differ per machine. Agreement with GDI is checked
-- separately, by running both against the same font files; see text-extents-investigation/README.md.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents-freetype")!
->
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
  gdiMetrics = require "l0.AegisubShims.helpers.gdi-metrics"
  haveShims, shims = pcall require, "l0.AegisubShims"
  haveFreeType, freetype = pcall require, "l0.AegisubShims.text-extents-backends.freetype"
  haveGdi, gdi = pcall require, "l0.AegisubShims.text-extents-backends.gdi"

  testExports = haveFreeType and UnitTestSuite\getTestExports(freetype) or {}
  {:matchFont, :prepareAegisubWindowsMetrics} = testExports

  -- AbileneFLF's design values, whose native GDI reads pin the derivation in aegisub-gdi-metrics: a
  -- face with no OS/2 table, which GDI lays out in its glyph bounding box
  faceWithoutOs2 = {
    family: "TestFace", unitsPerEm: 1000, hasCffOutlines: false
    hhea: {ascender: 900, descender: -100, lineGap: 0}
    outlineBounds: {yMax: 901, yMin: -108}
  }
  -- and StencilFull's, whose Windows cell measures nothing, so Windows will not load the file
  faceWithEmptyCell = {
    family: "TestFace", unitsPerEm: 1000, hasCffOutlines: false
    os2: {winAscent: 0, winDescent: 0, fsSelection: 0, typoAscender: 747, typoDescender: -200}
    hhea: {ascender: 747, descender: -262, lineGap: 0}
    outlineBounds: {yMax: 901, yMin: -108}
  }
  settingsWith = (fallback) -> {dpi: 96, verticalMetricFallback: fallback}

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

    createBackend_rejectsAnUnknownVerticalMetricFallback: (ut) ->
      ut\assertErrorMsgMatches (-> freetype.createBackend {verticalMetricFallback: 99}), {},
        "Invalid value"

    -- GDI lays a face with no OS/2 table out in its bounding box, taking the requested height as
    -- the realized em, so the line height comes out at whatever that box measures
    prepareAegisubWindowsMetrics_gdiReadsTheOutlinesOfAFaceStatingNoOs2Table: (ut) ->
      prepared, err = prepareAegisubWindowsMetrics faceWithoutOs2, 2560,
        settingsWith freetype.VerticalMetricFallbackBehavior.Gdi
      ut\assertNil err
      ut\assertEquals prepared.descent, 276
      ut\assertEquals prepared.height, 2307 + 276

    -- and will not lay out a face whose cell measures nothing, so neither will this
    prepareAegisubWindowsMetrics_gdiRefusesAFaceStatingAnUnusableCell: (ut) ->
      prepared, err = prepareAegisubWindowsMetrics faceWithEmptyCell, 2560,
        settingsWith freetype.VerticalMetricFallbackBehavior.Gdi
      ut\assertNil prepared
      ut\assertMatches err, "no usable OS/2 Windows cell"

    -- libass measures that same face by fitting its typographic span to the requested height, which is
    -- then what the line height comes out at
    prepareAegisubWindowsMetrics_libassFitsTheTypographicSpan: (ut) ->
      prepared, err = prepareAegisubWindowsMetrics faceWithEmptyCell, 2560,
        settingsWith freetype.VerticalMetricFallbackBehavior.Libass
      ut\assertNil err
      ut\assertEquals prepared.height, 2560
      ut\assertEquals prepared.descent, 665

    prepareAegisubWindowsMetrics_refuseTakesOnlyTheWindowsCell: (ut) ->
      prepared, err = prepareAegisubWindowsMetrics faceWithoutOs2, 2560,
        settingsWith freetype.VerticalMetricFallbackBehavior.Refuse
      ut\assertNil prepared
      ut\assertMatches err, "Refuse fallback"

    -- Both contracts measure the same advances and differ only in what they normalize against, so
    -- their widths hold the ratio of the two spans whatever face fontconfig substitutes here.
    createBackend_macModeNormalizesAgainstTheLineHeight: (ut) ->
      measureMac = freetype.createBackend {metricMode: freetype.MetricMode.AegisubMac, kerning: false}
      measureWindows = freetype.createBackend {metricMode: freetype.MetricMode.AegisubWindows}
      style = baseStyle {fontsize: 100}
      windowsWidth = measureWindows style, "Hello"
      macWidth = measureMac style, "Hello"
      ut\assertTrue windowsWidth > 0
      ut\assertTrue macWidth > 0

      -- the mac contract reports the face's own descent and leading, so both stay finite and sane
      _, macHeight, macDescent, macExtlead = measureMac style, "Hello"
      ut\assertEquals macHeight, 100
      ut\assertTrue macDescent > 0 and macDescent < 100
      ut\assertTrue macExtlead >= 0

    -- an empty run measures as nothing at all under this contract, as it does under GDI
    createBackend_macModeGivesAnEmptyStringNoExtent: (ut) ->
      measureMac = freetype.createBackend {metricMode: freetype.MetricMode.AegisubMac}
      width, height = measureMac baseStyle!, ""
      ut\assertEquals width, 0
      ut\assertEquals height, 0

    createBackend_rejectsNonTableOptions: (ut) ->
      ut\assertError freetype.createBackend, "Face"

    -- fontconfig returns a file even when nothing matches, so an unknown name still comes back with
    -- a usable path
    matchFont_reportsAnUnknownFamilyAsSubstituted: (ut) ->
      file = matchFont "NoSuchFontExistsHere"
      ut\assertNotNil file
      ut\assertTrue file.substituted
      ut\assertNotNil file.path

    -- the generic families, which every fontconfig install maps to a real font
    matchFont_treatsAnAliasAsAMatch: (ut) ->
      for family in *{"sans-serif", "serif", "monospace"}
        file = matchFont family
        ut\assertNotNil file
        ut\assertFalse file.substituted, family

    -- an empty request has no name to match, so the default is not a substitution
    matchFont_treatsAnEmptyFamilyAsAMatch: (ut) ->
      file = matchFont ""
      ut\assertNotNil file
      ut\assertFalse file.substituted

    -- text the resolved face covers never reaches the fallback, so the option changes nothing there
    createBackend_fontFallbackLeavesCoveredTextAlone: (ut) ->
      style = baseStyle!
      withFallback = freetype.createBackend {metricMode: freetype.MetricMode.AegisubLinux}
      withoutFallback = freetype.createBackend
        metricMode: freetype.MetricMode.AegisubLinux, fontFallback: false
      ut\assertEquals {withFallback style, "Hello"}, {withoutFallback style, "Hello"}

    -- U+0378 is unassigned, so no installed face has a glyph and the walk finds nothing to substitute
    createBackend_fontFallbackFindsNoFaceForAnUnassignedCodePoint: (ut) ->
      style = baseStyle!
      withFallback = freetype.createBackend {metricMode: freetype.MetricMode.AegisubLinux}
      withoutFallback = freetype.createBackend
        metricMode: freetype.MetricMode.AegisubLinux, fontFallback: false
      ut\assertEquals {withFallback style, "\205\184"}, {withoutFallback style, "\205\184"}

    matchFont_matchesANameWhateverItsCase: (ut) ->
      resolved, shouted = matchFont("sans-serif"), matchFont "SANS-SERIF"
      ut\assertNotNil resolved
      ut\assertNotNil shouted
      ut\assertEquals shouted.path, resolved.path
      ut\assertFalse shouted.substituted

    -- the umbrella installs GDI where it can and falls back to this backend everywhere else
    shims_installTheBackendWhereGdiIsUnavailable: (ut) ->
      return ut\skip "GDI is available here, so it is installed instead" if haveGdi and gdi.isAvailable
      ut\assertIs shims.getTextExtentsBackend!, freetype.measure
  }
