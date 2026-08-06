-- Pins the CoreText text-extents backend where no macOS is needed: the SFNT table parsers against
-- real font files on disk, and the cell derivation against TEXTMETRIC values measured natively from
-- GDI, the implementation the backend reproduces. The CTFont call layer runs only on macOS, so those
-- tests skip elsewhere.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents-coretext")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"
  haveCoreText, coretext = pcall require, "l0.AegisubShims.text-extents-backends.coretext"
  haveGdi, gdi = pcall require, "l0.AegisubShims.text-extents-backends.gdi"
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"

  {:parseOs2Table, :parseHheaTable, :deriveCellMetrics, :mulDivRound} = UnitTestSuite\getTestExports coretext

  -- big-endian readers over a font file's bytes, offsets as the SFNT directory states them
  readU16 = (bytes, offset) -> bytes\byte(offset + 1) * 0x100 + bytes\byte offset + 2
  readU32 = (bytes, offset) -> readU16(bytes, offset) * 0x10000 + readU16 bytes, offset + 2

  ---Reads one table out of a font file on disk, through the SFNT table directory.
  ---@param path string Path to a .ttf whose directory starts at byte zero.
  ---@param tag string The four-character table name.
  ---@return string? bytes The raw table, nil when the file or table is absent.
  readTableFromFontFile = (path, tag) ->
    file = io.open path, "rb"
    return nil unless file
    contents = file\read "*a"
    file\close!
    return nil if #contents < 12

    tableCount = readU16 contents, 4
    for index = 0, tableCount - 1
      entry = 12 + index * 16
      return nil if entry + 16 > #contents
      if tag == contents\sub entry + 1, entry + 4
        offset = readU32 contents, entry + 8
        length = readU32 contents, entry + 12
        return contents\sub offset + 1, offset + length

  -- fonts with independently known metrics: the Arial values were confirmed against native GDI
  -- TEXTMETRIC reads, the DejaVu Sans values against FreeType's own view of the same file
  KNOWN_FONTS = {
    {
      path: "C:/Windows/Fonts/arial.ttf"
      os2: {winAscent: 1854, winDescent: 434}
      hhea: {ascender: 1854, descender: -434, lineGap: 67}
    }
    {
      path: "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
      os2: {winAscent: 1901, winDescent: 483, typoAscender: 1556, typoDescender: -492, typoLineGap: 410}
      hhea: {ascender: 1901, descender: -483, lineGap: 0}
    }
  }

  findKnownFont = ->
    for known in *KNOWN_FONTS
      file = io.open known.path, "rb"
      if file
        file\close!
        return known

  -- Native GDI TEXTMETRIC reads for these faces at these lfHeights, measured on Windows 11: the
  -- derivation has to land on every one. Sizes cover the whole-point, fractional and large cases.
  arialFace = {unitsPerEm: 2048, cellHeight: 2288, winDescent: 434, lineGap: 67}
  timesFace = {unitsPerEm: 2048, cellHeight: 2268, winDescent: 443, lineGap: 87}
  GDI_MEASURED_CASES = {
    {face: arialFace, fontSize: 768, ppem: 687, descent: 146, extlead: 22}
    {face: arialFace, fontSize: 2560, ppem: 2291, descent: 486, extlead: 75}
    {face: arialFace, fontSize: 2656, ppem: 2377, descent: 504, extlead: 78}
    {face: arialFace, fontSize: 6400, ppem: 5729, descent: 1214, extlead: 187}
    {face: timesFace, fontSize: 768, ppem: 694, descent: 150, extlead: 29}
    {face: timesFace, fontSize: 2560, ppem: 2312, descent: 500, extlead: 98}
    {face: timesFace, fontSize: 2656, ppem: 2398, descent: 519, extlead: 102}
    {face: timesFace, fontSize: 6400, ppem: 5779, descent: 1250, extlead: 245}
  }

  baseStyle = (overrides) ->
    style = shims.Ass.createStyle {fontname: "Helvetica", fontsize: 40}
    style[key] = value for key, value in pairs overrides or {}
    return style

  {
    _description: "The CoreText text-extents backend: its pure derivation everywhere, its calls on macOS."

    mulDivRound_roundsToTheNearestInteger: (ut) ->
      ut\assertEquals mulDivRound(100, 2048, 2048), 100
      ut\assertEquals mulDivRound(1387, 1, 2), 694
      ut\assertEquals mulDivRound(1, 1, 3), 0

    -- the same derivation the FreeType backend runs through FT_MulDiv, here in plain arithmetic, so
    -- it is held to the very TEXTMETRIC values GDI realized for these faces
    deriveCellMetrics_matchesNativeGdiMeasurements: (ut) ->
      for case in *GDI_MEASURED_CASES
        derived = deriveCellMetrics case.face, case.fontSize
        ut\assertEquals derived.ppem, case.ppem
        ut\assertEquals derived.descent, case.descent
        ut\assertEquals derived.extlead, case.extlead

    parseOs2Table_readsARealFontsTable: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      parsed = parseOs2Table assert readTableFromFontFile known.path, "OS/2"
      ut\assertEquals parsed[key], value for key, value in pairs known.os2

    parseHheaTable_readsARealFontsTable: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      parsed = parseHheaTable assert readTableFromFontFile known.path, "hhea"
      ut\assertEquals parsed[key], value for key, value in pairs known.hhea

    parseOs2Table_rejectsATruncatedTable: (ut) ->
      ut\assertNil parseOs2Table "far too short"

    parseHheaTable_rejectsATruncatedTable: (ut) ->
      ut\assertNil parseHheaTable "x"

    measure_raisesWhereCoreTextIsUnreachable: (ut) ->
      return ut\skip "CoreText is available here" if coretext.isAvailable
      ut\assertErrorMsgMatches (-> coretext.measure baseStyle!, "Hello"), {}, "needs CoreText"

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
