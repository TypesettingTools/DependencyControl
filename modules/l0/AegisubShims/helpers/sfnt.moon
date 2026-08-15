Flags = require "l0.DependencyControl.Flags"

-- big-endian readers over a table's bytes, taking the offsets the SFNT format states
readU16 = (bytes, offset) ->
  high, low = bytes\byte offset + 1, offset + 2
  return high * 0x100 + low
readS16 = (bytes, offset) ->
  value = readU16 bytes, offset
  return value >= 0x8000 and value - 0x10000 or value
readU32 = (bytes, offset) ->
  return readU16(bytes, offset) * 0x10000 + readU16 bytes, offset + 2

---The styles the OS/2 table claims for the face, and which of its metrics it asks be preferred.
---@alias Os2FsSelection integer A combination of FsSelection members.
FsSelection = Flags "Os2FsSelection", {
  Italic: 0x001 -- the face is an italic or oblique cut
  Underscore: 0x002 -- the glyphs are underscored
  Negative: 0x004 -- the glyphs are drawn as their own negative
  Outlined: 0x008 -- the glyphs are hollow
  Strikeout: 0x010 -- the glyphs are struck through
  Bold: 0x020 -- the face is a bold cut
  Regular: 0x040 -- the face is neither italic nor bold, and no other style bit may be set with it
  UseTypoMetrics: 0x080 -- lay lines out by the sTypo values rather than the hhea ones
  Wws: 0x100 -- the family name distinguishes this face by weight, width and slope alone
  Oblique: 0x200 -- the face is oblique rather than a true italic
}

---The embedding permissions the OS/2 table states for the face.
---@alias Os2FsType integer A combination of FsType members.
FsType = Flags "Os2FsType", {
  -- the licensing level, of which a face states at most one; none at all means installable embedding
  {
    RestrictedLicense: 0x002 -- the face may not be embedded or exchanged without the owner's permission
    PreviewAndPrint: 0x004 -- an embedded copy may be viewed and printed, but not edited with
    Editable: 0x008 -- an embedded copy may also be edited with
  }
  NoSubsetting: 0x100 -- an embedded copy has to hold every glyph, not only the ones a document uses
  BitmapEmbeddingOnly: 0x200 -- only the face's bitmaps may be embedded, never its outlines
}

-- what each OS/2 version measures, so a block is only read off a table long enough to hold it
OS2_LENGTH_VERSION_0 = 78
OS2_LENGTH_VERSION_1 = 86
OS2_LENGTH_VERSION_2 = 96
OS2_LENGTH_VERSION_5 = 100

---A font's OS/2 and Windows metrics, whole. Every field a table version 0 predates is optional and
---comes back nil for a face declaring an earlier version than states it.
---@class ParsedOs2Table
---@field version integer The table's format version, 0 through 5.
---@field avgCharWidth integer Average width over the face's glyphs, in design units.
---@field weightClass integer Visual weight, 1 to 1000, where 400 is regular and 700 bold.
---@field widthClass integer Visual width, 1 to 9, where 5 is the face's normal proportions.
---@field fsType Os2FsType Embedding permissions the foundry states for the face.
---@field subscriptXSize integer Width a subscript should be set at, in design units.
---@field subscriptYSize integer Height a subscript should be set at, in design units.
---@field subscriptXOffset integer Horizontal shift applied to a subscript, in design units.
---@field subscriptYOffset integer Vertical shift applied to a subscript, positive downwards.
---@field superscriptXSize integer Width a superscript should be set at, in design units.
---@field superscriptYSize integer Height a superscript should be set at, in design units.
---@field superscriptXOffset integer Horizontal shift applied to a superscript, in design units.
---@field superscriptYOffset integer Vertical shift applied to a superscript, positive upwards.
---@field strikeoutSize integer Thickness of the strikeout stroke, in design units.
---@field strikeoutPosition integer Height of the strikeout stroke above the baseline.
---@field familyClass integer Packed IBM family class in the high byte and subclass in the low one.
---@field panose integer[] The ten PANOSE classification digits, in the order the standard states.
---@field unicodeRange1 integer Coverage bits 0 to 31 of the Unicode ranges the face claims.
---@field unicodeRange2 integer Coverage bits 32 to 63.
---@field unicodeRange3 integer Coverage bits 64 to 95.
---@field unicodeRange4 integer Coverage bits 96 to 127.
---@field vendorId string The foundry's four-character identifier, space padded as the face states it.
---@field fsSelection Os2FsSelection The face's style bits and its line-metric preference.
---@field firstCharIndex integer Lowest character code the face maps, as a Unicode code point.
---@field lastCharIndex integer Highest character code the face maps, capped at 0xFFFF.
---@field typoAscender integer The typographic ascent, in design units.
---@field typoDescender integer The typographic descent, negative below the baseline.
---@field typoLineGap integer The typographic line gap.
---@field winAscent integer Top of the Windows clipping cell above the baseline.
---@field winDescent integer Depth of that cell below the baseline, positive.
---@field codePageRange1? integer Coverage bits 0 to 31 of the legacy code pages the face claims; version 1 and up.
---@field codePageRange2? integer Coverage bits 32 to 63 of those code pages; version 1 and up.
---@field xHeight? integer Height of a lowercase x above the baseline; version 2 and up.
---@field capHeight? integer Height of a capital letter above the baseline; version 2 and up.
---@field defaultChar? integer Code point drawn for a character the face does not map; version 2 and up.
---@field breakChar? integer Code point a line may be broken at, usually the space; version 2 and up.
---@field maxContext? integer Longest run of glyphs any one layout feature looks at; version 2 and up.
---@field lowerOpticalPointSize? integer Smallest size the face is intended for, in twentieths of a point; version 5.
---@field upperOpticalPointSize? integer First size past what the face is intended for, same units; version 5.

---A font's horizontal header, whole. The four reserved fields are left out, the specification having
---them always zero.
---@class ParsedHheaTable
---@field majorVersion integer Major table version, 1 for every version defined so far.
---@field minorVersion integer Minor table version, 0 for every version defined so far.
---@field ascender integer The typographic ascent, in design units.
---@field descender integer The typographic descent, negative below the baseline.
---@field lineGap integer The leading the face asks for between lines.
---@field advanceWidthMax integer The widest advance any glyph in the face takes.
---@field minLeftSideBearing integer The smallest left side bearing over glyphs that have an outline.
---@field minRightSideBearing integer The smallest right side bearing over glyphs that have an outline.
---@field xMaxExtent integer The furthest right any glyph reaches, as left side bearing plus width.
---@field caretSlopeRise integer Rise of the caret's slope; 1 with a run of 0 stands a caret upright.
---@field caretSlopeRun integer Run of the caret's slope, 0 for an upright caret.
---@field caretOffset integer Shift applied to the caret to center it on a slanted glyph.
---@field metricDataFormat integer Format of the hmtx table, 0 for every version defined so far.
---@field numberOfHMetrics integer How many glyphs hmtx states an advance for, the rest sharing the last.

---Parses the tables of an SFNT font and derives the values the specification defines over them.
---
---SFNT is the container TrueType and OpenType fonts are stored in: a directory of tables, each named
---by a four-character tag, holding the glyph outlines and every metric a font declares. A table's raw
---bytes are taken from wherever they were obtained — `CTFontCopyTable`, `FT_Load_Sfnt_Table`, or a
---font file read whole — so this stays independent of the library that opened the face.
---
---Field names follow the OpenType specification, minus the Hungarian type prefixes its names use.
---@class AegisubShimsSfnt
Sfnt = {
  :FsSelection
  :FsType

  ---Parses an OS/2 table out of the raw table bytes, as far as its version and length reach.
  ---@param bytes string The table, as the font file or the font library hands it over.
  ---@return ParsedOs2Table? parsed Nil for a table shorter than the 78 bytes version 0 measures.
  parseOs2Table: (bytes) ->
    return nil if #bytes < OS2_LENGTH_VERSION_0
    version = readU16 bytes, 0
    parsed = {
      :version
      avgCharWidth: readS16 bytes, 2
      weightClass: readU16 bytes, 4
      widthClass: readU16 bytes, 6
      fsType: readU16 bytes, 8
      subscriptXSize: readS16 bytes, 10
      subscriptYSize: readS16 bytes, 12
      subscriptXOffset: readS16 bytes, 14
      subscriptYOffset: readS16 bytes, 16
      superscriptXSize: readS16 bytes, 18
      superscriptYSize: readS16 bytes, 20
      superscriptXOffset: readS16 bytes, 22
      superscriptYOffset: readS16 bytes, 24
      strikeoutSize: readS16 bytes, 26
      strikeoutPosition: readS16 bytes, 28
      familyClass: readS16 bytes, 30
      panose: [bytes\byte 33 + digit for digit = 0, 9]
      unicodeRange1: readU32 bytes, 42
      unicodeRange2: readU32 bytes, 46
      unicodeRange3: readU32 bytes, 50
      unicodeRange4: readU32 bytes, 54
      vendorId: bytes\sub 59, 62
      fsSelection: readU16 bytes, 62
      firstCharIndex: readU16 bytes, 64
      lastCharIndex: readU16 bytes, 66
      typoAscender: readS16 bytes, 68
      typoDescender: readS16 bytes, 70
      typoLineGap: readS16 bytes, 72
      winAscent: readU16 bytes, 74
      winDescent: readU16 bytes, 76
    }

    if version >= 1 and #bytes >= OS2_LENGTH_VERSION_1
      parsed.codePageRange1 = readU32 bytes, 78
      parsed.codePageRange2 = readU32 bytes, 82

    if version >= 2 and #bytes >= OS2_LENGTH_VERSION_2
      parsed.xHeight = readS16 bytes, 86
      parsed.capHeight = readS16 bytes, 88
      parsed.defaultChar = readU16 bytes, 90
      parsed.breakChar = readU16 bytes, 92
      parsed.maxContext = readU16 bytes, 94

    if version >= 5 and #bytes >= OS2_LENGTH_VERSION_5
      parsed.lowerOpticalPointSize = readU16 bytes, 96
      parsed.upperOpticalPointSize = readU16 bytes, 98

    return parsed

  ---The baseline-to-baseline distance a horizontal header declares, being its ascent to its descent
  ---with the line gap counted in, as both the OpenType and TrueType specifications define it.
  ---@param hhea ParsedHheaTable The header to read.
  ---@return integer height The distance, in design units; zero or less for a face declaring none usable.
  getLineHeight: (hhea) -> hhea.ascender - hhea.descender + hhea.lineGap

  ---Parses a horizontal header out of the raw table bytes.
  ---@param bytes string The table, as the font file or the font library hands it over.
  ---@return ParsedHheaTable? parsed Nil for a table shorter than the fixed 36 bytes hhea always is.
  parseHheaTable: (bytes) ->
    return nil if #bytes < 36
    return {
      majorVersion: readU16 bytes, 0
      minorVersion: readU16 bytes, 2
      ascender: readS16 bytes, 4
      descender: readS16 bytes, 6
      lineGap: readS16 bytes, 8
      advanceWidthMax: readU16 bytes, 10
      minLeftSideBearing: readS16 bytes, 12
      minRightSideBearing: readS16 bytes, 14
      xMaxExtent: readS16 bytes, 16
      caretSlopeRise: readS16 bytes, 18
      caretSlopeRun: readS16 bytes, 20
      caretOffset: readS16 bytes, 22
      metricDataFormat: readS16 bytes, 32
      numberOfHMetrics: readU16 bytes, 34
    }
}

return Sfnt
