-- Pins the SFNT table parsers the text-extents backends derive their metrics from: the OS/2 and hhea
-- fields against real font files on disk, and the length guards against truncated input. Pure byte
-- parsing, so it needs no font library and runs everywhere.
-- Called from test.moon as: (controls\requireTest "aegisub-sfnt")!
->
  sfnt = require "l0.AegisubShims.helpers.sfnt"

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

  -- Fonts with independently known metrics: the Arial values were confirmed against native GDI
  -- TEXTMETRIC reads, the DejaVu Sans values against FreeType's own view of the same file.
  --
  -- Only what the typeface's design fixes is pinned. A field derived from the glyph inventory —
  -- `advanceWidthMax`, the side bearings, `xMaxExtent`, `numberOfHMetrics`, `avgCharWidth`,
  -- `maxContext`, the character-index bounds, and the OS/2 table version — differs between builds of
  -- the same face, so those are checked for shape rather than value by the test below.

  -- The Windows font directory is wherever the install lives, which SHGetKnownFolderPath would answer
  -- with and %SystemRoot% already states. Locating a face by family instead would mean fontconfig,
  -- and the point of these tests is that parsing needs no font library at all.
  windowsFontsDir = "#{(os.getenv('SystemRoot') or os.getenv('WINDIR') or 'C:/Windows')}/Fonts"

  -- macOS ships Arial too, at /System/Library/Fonts/Supplemental, but as a different build: its span
  -- against its cell measures 1.0296 where this file's tables give 1.0293, so its numbers are not
  -- these numbers and it would fail the comparison rather than widen it.
  knownFonts = {
    {
      paths: {"#{windowsFontsDir}/arial.ttf"}
      os2: {
        weightClass: 400, widthClass: 5, familyClass: 2053, vendorId: "TMC "
        xHeight: 1062, capHeight: 1467
        typoAscender: 1491, typoDescender: -431, typoLineGap: 307
        winAscent: 1854, winDescent: 434
      }
      panose: {2, 11, 6, 4, 2, 2, 2, 2, 2, 4}
      fsSelection: "Regular"
      fsType: "Editable"
      hhea: {
        majorVersion: 1, minorVersion: 0, ascender: 1854, descender: -434, lineGap: 67
        caretSlopeRise: 1, caretSlopeRun: 0, caretOffset: 0, metricDataFormat: 0
      }
      lineHeight: 2355
    }
    {
      paths: {
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf" -- Debian and Ubuntu
        "/usr/share/fonts/TTF/DejaVuSans.ttf" -- Arch
        "/usr/share/fonts/dejavu/DejaVuSans.ttf" -- Fedora and openSUSE
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf" -- newer Fedora
      }
      os2: {winAscent: 1901, winDescent: 483, typoAscender: 1556, typoDescender: -492, typoLineGap: 410}
      hhea: {ascender: 1901, descender: -483, lineGap: 0}
      lineHeight: 2384
    }
  }

  -- the first entry this machine holds a file for, with `path` set to where it was found
  findKnownFont = ->
    for known in *knownFonts
      for candidate in *known.paths
        file = io.open candidate, "rb"
        if file
          file\close!
          known.path = candidate
          return known

  {
    _description: "The SFNT table parsers shared by the text-extents backends."

    parseOs2Table_readsARealFontsTable: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      parsed = sfnt.parseOs2Table assert readTableFromFontFile known.path, "OS/2"
      ut\assertFieldsEqual parsed, known.os2, "OS/2"

    parseHheaTable_readsARealFontsTable: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      parsed = sfnt.parseHheaTable assert readTableFromFontFile known.path, "hhea"
      ut\assertFieldsEqual parsed, known.hhea, "hhea"

    -- The fields a build of the face decides rather than its design still have to parse, so they are
    -- checked for being there and being plausible instead of against a value that moves.
    parseTables_readEveryFieldTheBuildDecides: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      hhea = sfnt.parseHheaTable assert readTableFromFontFile known.path, "hhea"
      os2 = sfnt.parseOs2Table assert readTableFromFontFile known.path, "OS/2"

      ut\assertTrue hhea.advanceWidthMax > 0
      ut\assertTrue hhea.numberOfHMetrics > 0
      ut\assertTrue hhea.xMaxExtent > 0
      ut\assertTrue hhea.minLeftSideBearing < hhea.xMaxExtent
      ut\assertTrue hhea.minRightSideBearing < hhea.xMaxExtent

      ut\assertTrue os2.version >= 0 and os2.version <= 5
      ut\assertTrue os2.avgCharWidth > 0
      ut\assertTrue os2.firstCharIndex <= os2.lastCharIndex
      ut\assertTrue os2.maxContext >= 0 if os2.maxContext

    parseOs2Table_readsThePanoseDigitsInOrder: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      return ut\skip "no PANOSE recorded for #{known.path}" unless known.panose
      parsed = sfnt.parseOs2Table assert readTableFromFontFile known.path, "OS/2"
      ut\assertEquals #parsed.panose, 10
      ut\assertEquals parsed.panose[index], digit for index, digit in ipairs known.panose

    -- a version 0 table states none of the later blocks, so they come back absent rather than zeroed
    parseOs2Table_omitsWhatTheVersionPredates: (ut) ->
      whole = readTableFromFontFile (findKnownFont! or {}).path or "", "OS/2"
      return ut\skip "no font with independently known metrics on this machine" unless whole
      asVersion0 = "\0\0" .. whole\sub(3, 78)
      parsed = assert sfnt.parseOs2Table asVersion0
      ut\assertEquals parsed.version, 0
      ut\assertNil parsed.codePageRange1
      ut\assertNil parsed.xHeight
      ut\assertNil parsed.lowerOpticalPointSize
      -- everything version 0 does state still parses
      ut\assertEquals parsed.winAscent, sfnt.parseOs2Table(whole).winAscent

    getLineHeight_countsTheLineGapIn: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      hhea = sfnt.parseHheaTable assert readTableFromFontFile known.path, "hhea"
      ut\assertEquals sfnt.getLineHeight(hhea), known.lineHeight

    -- the two OS/2 bit fields come back as plain numbers, read through the flag sets on the module
    parseOs2Table_bitFieldsReadThroughTheirFlagSets: (ut) ->
      known = findKnownFont!
      return ut\skip "no font with independently known metrics on this machine" unless known
      return ut\skip "no bit fields recorded for #{known.path}" unless known.fsSelection
      parsed = sfnt.parseOs2Table assert readTableFromFontFile known.path, "OS/2"
      ut\assertEquals sfnt.FsSelection\describe(parsed.fsSelection), known.fsSelection
      ut\assertEquals sfnt.FsType\describe(parsed.fsType), known.fsType

    -- the bit the metric derivations turn on, which every implementation disagrees about honoring
    fsSelection_exposesTheTypographicMetricsBit: (ut) ->
      ut\assertEquals sfnt.FsSelection.UseTypoMetrics, 0x080
      ut\assertTrue sfnt.FsSelection\has 0x0A0, "UseTypoMetrics"
      ut\assertFalse sfnt.FsSelection\has 0x020, "UseTypoMetrics"
      ut\assertEquals sfnt.FsSelection\describe(0x0A0), "Bold|UseTypoMetrics"

    parseOs2Table_rejectsATruncatedTable: (ut) ->
      ut\assertNil sfnt.parseOs2Table "far too short"

    parseHheaTable_rejectsATruncatedTable: (ut) ->
      ut\assertNil sfnt.parseHheaTable "x"

    -- hhea is a fixed 36 bytes, so a table holding only the metric fields is malformed
    parseHheaTable_rejectsATableStoppingAfterTheMetrics: (ut) ->
      ut\assertNil sfnt.parseHheaTable string.rep "\0", 10
  }
