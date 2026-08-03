-- Pins the TEXTMETRIC derivations the FreeType and CoreText backends apply to reproduce GDI without
-- one. Pure arithmetic over design values, so it needs neither a font library nor a font file and
-- runs everywhere.
-- Called from test.moon as: (controls\requireTest "aegisub-gdi-metrics")!
->
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
  gdiMetrics = require "l0.AegisubShims.helpers.gdi-metrics"
  {:mulDivRound} = UnitTestSuite\getTestExports gdiMetrics

  -- Native GDI TEXTMETRIC reads for these faces at these lfHeights, measured on Windows 11: the
  -- derivation has to land on every one. Sizes cover the whole-point, fractional and large cases.
  arialFace = {
    unitsPerEm: 2048, cellHeight: 2288, hasCffOutlines: false
    os2: {winAscent: 1854, winDescent: 434}
    hhea: {ascender: 1854, descender: -434, lineGap: 67}
  }
  timesFace = {
    unitsPerEm: 2048, cellHeight: 2268, hasCffOutlines: false
    os2: {winAscent: 1825, winDescent: 443}
    hhea: {ascender: 1825, descender: -443, lineGap: 87}
  }
  gdiMeasuredCases = {
    {face: arialFace, fontSize: 768, ppem: 687, descent: 146, extlead: 22}
    {face: arialFace, fontSize: 2560, ppem: 2291, descent: 486, extlead: 75}
    {face: arialFace, fontSize: 2656, ppem: 2377, descent: 504, extlead: 78}
    {face: arialFace, fontSize: 6400, ppem: 5729, descent: 1214, extlead: 187}
    {face: timesFace, fontSize: 768, ppem: 694, descent: 150, extlead: 29}
    {face: timesFace, fontSize: 2560, ppem: 2312, descent: 500, extlead: 98}
    {face: timesFace, fontSize: 2656, ppem: 2398, descent: 519, extlead: 102}
    {face: timesFace, fontSize: 6400, ppem: 5779, descent: 1250, extlead: 245}
  }

  {
    _description: "GDI TEXTMETRIC derivations"

    mulDivRound_roundsToTheNearestInteger: (ut) ->
      ut\assertEquals mulDivRound(100, 2048, 2048), 100
      ut\assertEquals mulDivRound(1387, 1, 2), 694
      ut\assertEquals mulDivRound(1, 1, 3), 0

    -- both backends measure through this, so it is held to the very TEXTMETRIC values GDI realized
    deriveTextMetrics_matchesNativeGdiMeasurements: (ut) ->
      for case in *gdiMeasuredCases
        derived = gdiMetrics.deriveTextMetrics case.face, case.fontSize
        ut\assertEquals derived.ppem, case.ppem
        ut\assertEquals derived.descent, case.descent
        ut\assertEquals derived.extlead, case.extlead

    -- the advances take the realized em, which is what parts them from the descent
    deriveTextMetrics_scalesDesignValuesByTheRealizedEm: (ut) ->
      derived = gdiMetrics.deriveTextMetrics arialFace, 2560
      ut\assertEquals derived.toDeviceUnits(arialFace.unitsPerEm), derived.ppem
      ut\assertZero derived.toDeviceUnits 0

    -- the design values of the two faces at either end of what the deduction does, read off the
    -- installed files: Arial's cell matches its typographic span, Calibri's exceeds it by its gap
    getExternalLeading_deductsTheRoomTheCellAlreadyCovers: (ut) ->
      arial = {ascender: 1854, descender: -434, lineGap: 67}
      ut\assertEquals gdiMetrics.getExternalLeading(arial, 1854 + 434, false), 67
      calibri = {ascender: 1536, descender: -512, lineGap: 452}
      ut\assertEquals gdiMetrics.getExternalLeading(calibri, 1950 + 550, false), 0

    -- a cell taller than the whole line height leaves no leading rather than a negative one
    getExternalLeading_flooredAtZero: (ut) ->
      hhea = {ascender: 1000, descender: -200, lineGap: 50}
      ut\assertEquals gdiMetrics.getExternalLeading(hhea, 1600, false), 0

    getExternalLeading_zeroForPostScriptOutlines: (ut) ->
      hhea = {ascender: 1000, descender: -200, lineGap: 1000}
      ut\assertEquals gdiMetrics.getExternalLeading(hhea, 1200, true), 0

    -- transcribed from the OpenType recommendations, "Baseline to Baseline Distances", which state
    -- the same derivation as MAX(0, (ascender - descender + lineGap) - (usWinAscent + usWinDescent))
    getExternalLeading_agreesWithTheSpecifiedFormula: (ut) ->
      for hhea in *{
        {ascender: 1854, descender: -434, lineGap: 67}
        {ascender: 1536, descender: -512, lineGap: 452}
        {ascender: 2189, descender: -600, lineGap: 0}
      }
        for cellHeight in *{2048, 2288, 2500, 3000}
          specified = math.max 0,
            (hhea.ascender - hhea.descender + hhea.lineGap) - cellHeight
          ut\assertEquals gdiMetrics.getExternalLeading(hhea, cellHeight, false), specified
  }
