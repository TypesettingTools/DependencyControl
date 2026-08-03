-- Pins the GDI text-extents backend against the relationships Aegisub's own implementation holds to,
-- rather than against captured numbers: it measures through a screen-compatible device context, so the
-- absolute values depend on the machine's fonts and display DPI and would not survive being written
-- down. Exact agreement with Aegisub is checked separately by a comparison run inside Aegisub.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents")!
->
  ffi = require "ffi"
  haveShims, shims = pcall require, "l0.AegisubShims"
  haveGdi, gdi = pcall require, "l0.AegisubShims.text-extents-backends.gdi"

  -- a face every Windows install carries, so the numbers below come from a real font
  baseStyle = (overrides) ->
    style = shims.Ass.createStyle {fontname: "Arial", fontsize: 40}
    style[key] = value for key, value in pairs overrides or {}
    return style

  {
    _description: "The GDI text-extents backend, against the invariants Aegisub's implementation holds."
    _condition: -> haveShims and haveGdi and gdi.isAvailable, "needs Windows with gdi32 loaded"

    measure_emptyStringHasNoExtent: (ut) ->
      width, height = gdi.measure baseStyle!, ""
      ut\assertZero width
      ut\assertZero height

    -- descent and extlead come from the font's metrics, not the string, so they survive an empty run
    measure_fontMetricsAreReportedForAnEmptyString: (ut) ->
      _, _, descent, extlead = gdi.measure baseStyle!, ""
      ut\assertGreaterThan descent, 0
      ut\assertGreaterThanOrEquals extlead, 0

    measure_widthGrowsWithText: (ut) ->
      short = gdi.measure baseStyle!, "i"
      long = gdi.measure baseStyle!, "iiiiiiiiii"
      ut\assertGreaterThan long, short

    -- advance width, not inked width: a run of spaces has to measure wider than nothing
    measure_trailingSpacesAddWidth: (ut) ->
      bare = gdi.measure baseStyle!, "Hi"
      padded = gdi.measure baseStyle!, "Hi   "
      ut\assertGreaterThan padded, bare

    measure_scaleXMultipliesWidthOnly: (ut) ->
      width, height, descent, extlead = gdi.measure baseStyle!, "Hello"
      wide, wideHeight, wideDescent, wideExtlead = gdi.measure baseStyle(scale_x: 200), "Hello"

      ut\assertAlmostEquals wide, width * 2
      ut\assertAlmostEquals wideHeight, height
      ut\assertAlmostEquals wideDescent, descent
      ut\assertAlmostEquals wideExtlead, extlead

    measure_scaleYMultipliesTheVerticalMetrics: (ut) ->
      width, height, descent, extlead = gdi.measure baseStyle!, "Hello"
      tall, tallHeight, tallDescent, tallExtlead = gdi.measure baseStyle(scale_y: 200), "Hello"

      ut\assertAlmostEquals tall, width
      ut\assertAlmostEquals tallHeight, height * 2
      ut\assertAlmostEquals tallDescent, descent * 2
      ut\assertAlmostEquals tallExtlead, extlead * 2

    -- spacing is added once per UTF-16 code unit, so raising it by one widens a five-unit run by five
    measure_spacingIsAddedPerCodeUnit: (ut) ->
      atOne = gdi.measure baseStyle(spacing: 1), "Hello"
      atTwo = gdi.measure baseStyle(spacing: 2), "Hello"
      ut\assertAlmostEquals atTwo - atOne, 5

    -- Aegisub walks the UTF-16 buffer, so an astral character counts as its two surrogate halves
    measure_spacingCountsSurrogateHalves: (ut) ->
      atOne = gdi.measure baseStyle(spacing: 1), "\240\159\152\128"
      atTwo = gdi.measure baseStyle(spacing: 2), "\240\159\152\128"
      ut\assertAlmostEquals atTwo - atOne, 2

    measure_boldIsNeverNarrowerThanRegular: (ut) ->
      regular = gdi.measure baseStyle!, "Hello"
      bold = gdi.measure baseStyle(bold: true), "Hello"
      ut\assertGreaterThanOrEquals bold, regular

    -- the face name is truncated into a LOGFONTW, so an overlong one still resolves to some font
    measure_overlongFaceNameStillMeasures: (ut) ->
      width = gdi.measure baseStyle(fontname: ("VeryLongFontName")\rep 4), "Hello"
      ut\assertGreaterThan width, 0

    measure_rejectsMalformedUtf8Text: (ut) ->
      ut\assertError gdi.measure, baseStyle!, "bad\255name"

    shims_installTheBackendOnWindows: (ut) ->
      ut\assertIs shims.getTextExtentsBackend!, gdi.measure
  }
