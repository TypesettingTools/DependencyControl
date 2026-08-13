-- Pins the TEXTMETRIC derivations the FreeType and CoreText backends apply to reproduce GDI without
-- one. Pure arithmetic over design values, so it needs neither a font library nor a font file and
-- runs everywhere.
-- Called from test.moon as: (controls\requireTest "aegisub-gdi-metrics")!
->
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
  gdiMetrics = require "l0.AegisubShims.helpers.gdi-metrics"
  sfnt = require "l0.AegisubShims.helpers.sfnt"
  textExtents = require "l0.AegisubShims.text-extents"
  {:mulDivRound} = UnitTestSuite\getTestExports gdiMetrics
  {:CellSource} = gdiMetrics
  {:FsSelection} = sfnt
  {:VerticalMetricFallbackBehavior} = textExtents

  fittedCell = (ascent, descent) ->
    return {:ascent, :descent, height: ascent + descent, source: CellSource.WindowsCell, emSized: false}

  -- Native GDI TEXTMETRIC reads for these faces at these lfHeights, measured on Windows 11: the
  -- derivation has to land on every one. Sizes cover the whole-point, fractional and large cases.
  arialFace = {
    unitsPerEm: 2048, hasCffOutlines: false
    cell: fittedCell 1854, 434
    hhea: {ascender: 1854, descender: -434, lineGap: 67}
  }
  timesFace = {
    unitsPerEm: 2048, hasCffOutlines: false
    cell: fittedCell 1825, 443
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

  -- Native reads for three faces with no OS/2 table, which GDI lays out in the bounding box with the
  -- requested height as the realized em, and for one of them with a line gap patched in to separate the
  -- two candidate leading rules. Bucephalus is not on a 1000-unit em and ArgosANouveau's box is shorter than its em,
  -- so the two cases the derivation could confuse are both here.
  emSizedFace = (unitsPerEm, boundsAscent, boundsDescent, lineGap = 0) ->
    return {
      :unitsPerEm, hasCffOutlines: false
      hhea: {ascender: boundsAscent, descender: -boundsDescent, :lineGap}
      cell: {
        ascent: boundsAscent, descent: boundsDescent, height: boundsAscent + boundsDescent
        source: CellSource.OutlineBounds, emSized: true
      }
    }
  gdiEmSizedCases = {
    -- Bucephalus, upem 1200, box 1151/-342
    {face: emSizedFace(1200, 1151, 342), fontSize: 2560, ppem: 2560, ascent: 2455, descent: 730, extlead: 0}
    -- AbileneFLF, upem 1000, box 901/-108
    {face: emSizedFace(1000, 901, 108), fontSize: 2560, ppem: 2560, ascent: 2307, descent: 276, extlead: 0}
    -- ArgosANouveau, upem 1000, box 734/-188, whose box falls short of its em
    {face: emSizedFace(1000, 734, 188), fontSize: 2560, ppem: 2560, ascent: 1879, descent: 481, extlead: 0}
    -- AbileneFLF again, with hhea.lineGap patched to 200, which GDI reports whole and undeducted
    {face: emSizedFace(1000, 901, 108, 200), fontSize: 2560, ppem: 2560, ascent: 2307, descent: 276, extlead: 512}
  }

  -- a distinct span in each of the places a face may state one, so the height a cell comes back with
  -- names which of them it was read from
  makeOs2Table = (winAscent, winDescent, fsSelection = 0) ->
    return {:winAscent, :winDescent, :fsSelection, typoAscender: 800, typoDescender: -150}
  emptyOs2 = {winAscent: 0, winDescent: 0, fsSelection: 0, typoAscender: 0, typoDescender: 0}
  header = {ascender: 900, descender: -180, lineGap: 60}
  emptyHeader = {ascender: 0, descender: 0, lineGap: 0}
  bounds = {yMax: 1100, yMin: -300}

  {
    _description: "GDI TEXTMETRIC derivations"

    mulDivRound_roundsToTheNearestInteger: (ut) ->
      ut\assertEquals mulDivRound(100, 2048, 2048), 100
      ut\assertEquals mulDivRound(1387, 1, 2), 694
      ut\assertEquals mulDivRound(1, 1, 3), 0

    deriveCell_readsTheWindowsCellFirst: (ut) ->
      cell = gdiMetrics.deriveCell makeOs2Table(1000, 200), header, bounds
      ut\assertFieldsEqual cell,
        {ascent: 1000, descent: 200, height: 1200, source: CellSource.WindowsCell, emSized: false},
        "cell"

    -- read as signed, a winDescent above 0x7FFF is a descender above the baseline, which shortens the
    -- cell instead of making it 16 bits tall
    deriveCell_readsTheWindowsCellMetricsAsSigned: (ut) ->
      cell = gdiMetrics.deriveCell makeOs2Table(747, 0x10000 - 100), header, bounds
      ut\assertFieldsEqual cell, {ascent: 747, descent: -100, height: 647}, "cell"

    -- Windows will not lay out a face whose Windows cell measures nothing, and GDI reaches for the
    -- bounding box only for a face with no OS/2 table
    deriveCell_gdiOffersNothingForAnUnusableCell: (ut) ->
      ut\assertNil gdiMetrics.deriveCell makeOs2Table(0, 0), header, bounds
      ut\assertNil gdiMetrics.deriveCell emptyOs2, header, bounds

    deriveCell_gdiReadsTheOutlinesForAFaceStatingNoOs2Table: (ut) ->
      cell = gdiMetrics.deriveCell nil, header, bounds
      ut\assertFieldsEqual cell,
        {ascent: 1100, descent: 300, height: 1400, source: CellSource.OutlineBounds, emSized: true},
        "cell"

    -- libass reads the typographic span, which GDI never looks at
    deriveCell_libassFallsBackToTheHorizontalHeader: (ut) ->
      cell = gdiMetrics.deriveCell makeOs2Table(0, 0), header, bounds,
        VerticalMetricFallbackBehavior.Libass
      ut\assertFieldsEqual cell,
        {ascent: 900, descent: 180, height: 1080, source: CellSource.HorizontalHeader, emSized: false},
        "cell"

    deriveCell_libassPrefersTheTypoSpanForAFaceAskingForIt: (ut) ->
      os2 = makeOs2Table 0, 0, FsSelection.UseTypoMetrics
      cell = gdiMetrics.deriveCell os2, header, bounds, VerticalMetricFallbackBehavior.Libass
      ut\assertFieldsEqual cell,
        {ascent: 800, descent: 150, height: 950, source: CellSource.TypoMetrics}, "cell"

    -- with USE_TYPO_METRICS set the header is never tried, libass retrying those same typo values and
    -- then the bounding box
    deriveCell_libassSkipsTheHeaderWhereUseTypoMetricsIsSet: (ut) ->
      os2 = makeOs2Table 0, 0, FsSelection.UseTypoMetrics
      os2.typoAscender, os2.typoDescender = 0, 0
      cell = gdiMetrics.deriveCell os2, header, bounds, VerticalMetricFallbackBehavior.Libass
      ut\assertFieldsEqual cell, {height: 1400, source: CellSource.OutlineBounds}, "cell"

    deriveCell_libassReadsTheTypoSpanBehindAnUnusableHeader: (ut) ->
      cell = gdiMetrics.deriveCell makeOs2Table(0, 0), emptyHeader, bounds,
        VerticalMetricFallbackBehavior.Libass
      ut\assertFieldsEqual cell,
        {ascent: 800, descent: 150, height: 950, source: CellSource.TypoMetrics}, "cell"

    -- the outlines are fitted to the requested height here, where GDI takes that height as the em
    deriveCell_libassFitsTheOutlineBounds: (ut) ->
      cell = gdiMetrics.deriveCell nil, nil, bounds, VerticalMetricFallbackBehavior.Libass
      ut\assertFieldsEqual cell,
        {ascent: 1100, descent: 300, height: 1400, source: CellSource.OutlineBounds, emSized: false},
        "cell"

    deriveCell_refuseOffersNothingBeyondTheWindowsCell: (ut) ->
      ut\assertFieldsEqual gdiMetrics.deriveCell(makeOs2Table(1000, 200), header, bounds,
        VerticalMetricFallbackBehavior.Refuse), {height: 1200, source: CellSource.WindowsCell}, "cell"
      ut\assertNil gdiMetrics.deriveCell nil, header, bounds, VerticalMetricFallbackBehavior.Refuse

    deriveCell_nilWhereNoTableStatesASpan: (ut) ->
      ut\assertNil gdiMetrics.deriveCell!
      for fallback in *VerticalMetricFallbackBehavior.values
        ut\assertNil gdiMetrics.deriveCell emptyOs2, emptyHeader, {yMax: 0, yMin: 0}, fallback

    -- both backends measure through this, so it is held to the very TEXTMETRIC values GDI realized
    deriveTextMetrics_matchesNativeGdiMeasurements: (ut) ->
      for case in *gdiMeasuredCases
        derived = gdiMetrics.deriveTextMetrics case.face, case.face.cell, case.fontSize
        ut\assertEquals derived.ppem, case.ppem
        ut\assertEquals derived.descent, case.descent
        ut\assertEquals derived.extlead, case.extlead

    -- a face GDI lays out in its bounding box realizes at the requested height as an em, which puts
    -- every value on that em and leaves the height at whatever the box comes out at
    deriveTextMetrics_matchesNativeGdiMeasurementsOfAnEmSizedFace: (ut) ->
      for case in *gdiEmSizedCases
        derived = gdiMetrics.deriveTextMetrics case.face, case.face.cell, case.fontSize
        ut\assertEquals derived.ppem, case.ppem
        ut\assertEquals derived.ascent, case.ascent
        ut\assertEquals derived.descent, case.descent
        ut\assertEquals derived.extlead, case.extlead

    -- the advances take the realized em, which is what parts them from the descent
    deriveTextMetrics_scalesDesignValuesByTheRealizedEm: (ut) ->
      derived = gdiMetrics.deriveTextMetrics arialFace, arialFace.cell, 2560
      ut\assertEquals derived.toDeviceUnits(arialFace.unitsPerEm), derived.ppem
      ut\assertZero derived.toDeviceUnits 0

    -- a face whose descender points above the baseline reports no descent at all
    deriveTextMetrics_clampsANegativeDescentToZero: (ut) ->
      face = {
        unitsPerEm: 1000, hasCffOutlines: false
        hhea: {ascender: 747, descender: -262, lineGap: 0}
        cell: {ascent: 747, descent: -100, height: 647, source: CellSource.WindowsCell, emSized: false}
      }
      derived = gdiMetrics.deriveTextMetrics face, face.cell, 2560
      ut\assertEquals derived.ppem, 3957
      ut\assertEquals derived.ascent, 2956
      ut\assertZero derived.descent
      ut\assertEquals derived.extlead, 1432

    -- the design values of the two faces at either end of what the deduction does, read off the
    -- installed files: Arial's cell matches its typographic span, Calibri's exceeds it by its gap
    getExternalLeading_deductsTheRoomTheCellAlreadyCovers: (ut) ->
      arial = {ascender: 1854, descender: -434, lineGap: 67}
      ut\assertEquals gdiMetrics.getExternalLeading(arial, fittedCell(1854, 434), false), 67
      calibri = {ascender: 1536, descender: -512, lineGap: 452}
      ut\assertEquals gdiMetrics.getExternalLeading(calibri, fittedCell(1950, 550), false), 0

    -- a cell taller than the whole line height leaves no leading rather than a negative one
    getExternalLeading_flooredAtZero: (ut) ->
      hhea = {ascender: 1000, descender: -200, lineGap: 50}
      ut\assertEquals gdiMetrics.getExternalLeading(hhea, fittedCell(1400, 200), false), 0

    getExternalLeading_zeroForPostScriptOutlines: (ut) ->
      hhea = {ascender: 1000, descender: -200, lineGap: 1000}
      ut\assertEquals gdiMetrics.getExternalLeading(hhea, fittedCell(1000, 200), true), 0

    -- the line gap is stated in the horizontal header and nowhere else
    getExternalLeading_zeroWithoutAHorizontalHeader: (ut) ->
      ut\assertZero gdiMetrics.getExternalLeading nil, fittedCell(1854, 434), false

    -- realized as an em, the cell is not a span the line height has to fit inside, so the gap survives
    -- whole where the deduction would have taken all of it
    getExternalLeading_takesTheWholeGapForAnEmSizedCell: (ut) ->
      hhea = {ascender: 900, descender: -100, lineGap: 200}
      emSized = {ascent: 901, descent: 108, height: 1009, source: CellSource.OutlineBounds, emSized: true}
      ut\assertEquals gdiMetrics.getExternalLeading(hhea, emSized, false), 200
      ut\assertEquals gdiMetrics.getExternalLeading(hhea, fittedCell(901, 108), false), 191

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
          cell = {height: cellHeight, emSized: false}
          ut\assertEquals gdiMetrics.getExternalLeading(hhea, cell, false), specified
  }
