-- Measures text through CoreText, the macOS system text API, deriving the metrics from the OS/2
-- Windows cell exactly as the GDI and FreeType backends do, so a script measures the same numbers on
-- every platform. Installed as the `aegisub.text_extents` backend by l0.AegisubShims where CoreText
-- is reachable, which needs no libraries beyond the system frameworks.

ffi = require "ffi"
ffiCoreText = require "l0.AegisubShims.helpers.ffi-coretext"
textExtents = require "l0.AegisubShims.text-extents"
unicode = require "l0.DependencyControl.unicode"

msgs = {
  acquireFace: {
    noName: "The font name '%s' could not be converted to a CFString."
    noFont: "CoreText offered no font at all for '%s'."
    noTables: "The font '%s' carries no usable OS/2 and hhea tables, so its metrics cannot be read."
  }
  measure: {
    unavailable: "Measuring text needs CoreText, which is only reachable on macOS."
  }
}

{:coreFoundation, :coreText, :CgSize, :StringEncoding, :FontTrait, :FontOrientation,
  :TableTag} = ffiCoreText
isAvailable = ffiCoreText.isAvailable

{:MEASUREMENT_SCALE} = textExtents

-- any instance size works for reading the face's design values, which do not scale with it
PROBE_FONT_SIZE = 1000

Utf16Buffer = ffi.typeof "uint16_t[?]"
GlyphBuffer = ffi.typeof "uint16_t[?]"
CgSizeBuffer = ffi.typeof "$[?]", CgSize

-- open faces and their design metrics, keyed by what was asked for rather than by what matched
measuredFaces = {}

---Multiplies then divides in one rounded step, as FT_MulDiv and the GDI scaling round.
---@param value number The value to scale, non-negative.
---@param numerator number The scale's numerator, non-negative.
---@param denominator number The scale's denominator, positive.
---@return integer scaled The scaled value, rounded to the nearest integer.
mulDivRound = (value, numerator, denominator) ->
  return math.floor value * numerator / denominator + 0.5

-- big-endian readers over a table's bytes, taking the offsets the SFNT format states
readU16 = (bytes, offset) ->
  high, low = bytes\byte offset + 1, offset + 2
  return high * 0x100 + low
readS16 = (bytes, offset) ->
  value = readU16 bytes, offset
  return value >= 0x8000 and value - 0x10000 or value

---The OS/2 fields the Windows-cell derivation reads.
---@class ParsedOs2Table
---@field version integer The table's format version.
---@field fsSelection integer The style and metric-preference bit set.
---@field typoAscender integer The typographic ascent, in design units.
---@field typoDescender integer The typographic descent, negative below the baseline.
---@field typoLineGap integer The typographic line gap.
---@field winAscent integer Top of the Windows clipping cell above the baseline.
---@field winDescent integer Depth of that cell below the baseline, positive.

---Parses the OS/2 table fields the derivation reads out of the raw table bytes.
---@param bytes string The table, as the font file or CTFontCopyTable carries it.
---@return ParsedOs2Table? parsed Nil when the bytes are shorter than a version 0 table.
parseOs2Table = (bytes) ->
  return nil if #bytes < 78
  return {
    version: readU16 bytes, 0
    fsSelection: readU16 bytes, 62
    typoAscender: readS16 bytes, 68
    typoDescender: readS16 bytes, 70
    typoLineGap: readS16 bytes, 72
    winAscent: readU16 bytes, 74
    winDescent: readU16 bytes, 76
  }

---The hhea fields the Windows-cell derivation reads.
---@class ParsedHheaTable
---@field ascender integer The typographic ascent, in design units.
---@field descender integer The typographic descent, negative below the baseline.
---@field lineGap integer The leading the face asks for between lines.

---Parses the horizontal header fields the derivation reads out of the raw table bytes.
---@param bytes string The table, as the font file or CTFontCopyTable carries it.
---@return ParsedHheaTable? parsed Nil when the bytes are shorter than the fields read.
parseHheaTable = (bytes) ->
  return nil if #bytes < 10
  return {
    ascender: readS16 bytes, 4
    descender: readS16 bytes, 6
    lineGap: readS16 bytes, 8
  }

---The vertical metrics GDI reports for a face realized into a requested cell height.
---@class DerivedCellMetrics
---@field ppem integer The em the face is realized at, in device units.
---@field descent integer Depth below the baseline, in device units.
---@field extlead integer Leading beyond the cell, in device units.

---Derives the vertical metrics for a face realized into a requested cell height, as GDI derives
---TEXTMETRIC. The descent scales by the requested height directly, never reaching the rasterizer,
---while the leading and the advances scale by the realized integer em that GDI rasterizes at.
---@param measured MeasuredCoreTextFace The face's design metrics.
---@param fontSize integer Requested cell height, already multiplied by MEASUREMENT_SCALE.
---@return DerivedCellMetrics derived Values in device units, still carrying the measurement scale.
deriveCellMetrics = (measured, fontSize) ->
  {:unitsPerEm, :cellHeight} = measured
  ppem = mulDivRound fontSize, unitsPerEm, cellHeight
  return {
    :ppem
    descent: mulDivRound measured.winDescent, fontSize, cellHeight
    extlead: mulDivRound measured.lineGap, ppem, unitsPerEm
  }

---Reads a font table's bytes off an open font.
---@param font ffi.cdata* The CTFont to read from.
---@param tag CoreTextTableTag The table to read.
---@return string? bytes The raw table, nil when the face carries none.
readFontTable = (font, tag) ->
  data = coreText.CTFontCopyTable font, tag, 0
  return nil if data == nil
  ffi.gc data, coreFoundation.CFRelease
  return ffi.string coreFoundation.CFDataGetBytePtr(data), coreFoundation.CFDataGetLength data

---An open em-sized font together with the design values the derivation reads.
---@class MeasuredCoreTextFace
---@field font ffi.cdata* The CTFont at em size, so its advances come back in design units.
---@field family string Family the style asked for, which messages name.
---@field unitsPerEm integer Design units per em, which every design value below is expressed in.
---@field cellHeight integer Height of the cell Windows lays the face out in, in design units.
---@field winDescent integer Depth of that cell below the baseline, in design units.
---@field lineGap integer Leading the face asks for beyond that cell, in design units.

---Opens the font a style asks for, reading the design metrics off it once.
---@param style AegisubStyle The style to set the text in.
---@return MeasuredCoreTextFace? measured Nil when no font could be resolved or read.
---@return string? err Why the font could not be measured with.
acquireFace = (style) ->
  family = style.fontname or ""
  traits = (style.bold and FontTrait.Bold or 0) + (style.italic and FontTrait.Italic or 0)
  requestKey = "#{family}\0#{traits}"

  cached = measuredFaces[requestKey]
  return cached if cached

  cfName = coreFoundation.CFStringCreateWithBytes nil, family, #family, StringEncoding.Utf8, 0
  return nil, msgs.acquireFace.noName\format family if cfName == nil
  ffi.gc cfName, coreFoundation.CFRelease

  -- CoreText substitutes a fallback face for an unknown name, so this resolves like the GDI mapper
  -- and fontconfig do. A face lacking the requested traits keeps the base cut.
  resolveFont = (size) ->
    base = coreText.CTFontCreateWithName cfName, size, nil
    return nil if base == nil
    ffi.gc base, coreFoundation.CFRelease
    return base if traits == 0

    styled = coreText.CTFontCreateCopyWithSymbolicTraits base, 0, nil, traits,
      FontTrait.Bold + FontTrait.Italic
    return base if styled == nil
    return ffi.gc styled, coreFoundation.CFRelease

  probe = resolveFont PROBE_FONT_SIZE
  return nil, msgs.acquireFace.noFont\format family if probe == nil

  unitsPerEm = tonumber coreText.CTFontGetUnitsPerEm probe
  os2Bytes = readFontTable probe, TableTag.Os2
  hheaBytes = readFontTable probe, TableTag.HoriHeader
  os2 = os2Bytes and parseOs2Table os2Bytes
  hhea = hheaBytes and parseHheaTable hheaBytes
  return nil, msgs.acquireFace.noTables\format family unless os2 and hhea and unitsPerEm > 0

  cellHeight = os2.winAscent + os2.winDescent
  return nil, msgs.acquireFace.noTables\format family unless cellHeight > 0

  -- Room the Windows cell has beyond the typographic ascent and descent is leading the line already
  -- carries, so only the part of the face's line gap exceeding it is still external leading. Arial's
  -- cell matches its typographic span and its whole gap survives, while Calibri's is taller by exactly
  -- its line gap and none of it does.
  typographicHeight = hhea.ascender - hhea.descender
  lineGap = math.max 0, hhea.lineGap - (cellHeight - typographicHeight)

  measured = {
    -- at em size, the advance of every glyph comes back as its design value exactly
    font: resolveFont unitsPerEm
    :family
    :unitsPerEm
    :cellHeight
    :lineGap
    winDescent: os2.winDescent
  }
  measuredFaces[requestKey] = measured
  return measured

---Sums the advances of a run in device units, one code point at a time, each advance rounded on its
---own as GDI reports whole-pixel extents.
---Takes code points from a strict decode, so the UTF-16 conversion cannot reject one.
---@param measured MeasuredCoreTextFace The face to measure with.
---@param ppem integer The realized em to scale each design advance by.
---@param codePoints integer[] The run's code points, at least one.
---@return number width The summed advances, in device units.
sumAdvances = (measured, ppem, codePoints) ->
  count = #codePoints

  -- the glyph lookup takes UTF-16, and a code point past the BMP occupies a surrogate pair there
  -- whose glyph lands in the pair's first slot
  units, unitStarts = unicode.encodeUtf16 codePoints

  unitBuffer = Utf16Buffer #units
  unitBuffer[index - 1] = unit for index, unit in ipairs units
  unitGlyphs = GlyphBuffer #units
  -- an unmapped character leaves glyph zero, whose advance is the face's missing-glyph advance
  coreText.CTFontGetGlyphsForCharacters measured.font, unitBuffer, unitGlyphs, #units

  glyphs = GlyphBuffer count
  glyphs[index - 1] = unitGlyphs[unitStart] for index, unitStart in ipairs unitStarts
  advances = CgSizeBuffer count
  coreText.CTFontGetAdvancesForGlyphs measured.font, FontOrientation.Default, glyphs, advances, count

  width = 0
  width += mulDivRound advances[index].width, ppem, measured.unitsPerEm for index = 0, count - 1
  return width

---Measures a run of text set in a style, as `aegisub.text_extents` reports it on Windows.
---@param style AegisubStyle The style to set the text in.
---@param text string The text to measure.
---@return number width Advance the run takes, trailing spaces included, after the style's scale_x.
---@return number height Line height of the realized face, not the glyphs' bounds, after scale_y.
---@return number descent Depth below the baseline, read from the face, so the same for any text.
---@return number extlead Gap the face asks for between lines, also read from it rather than the text.
measure = (style, text) ->
  error msgs.measure.unavailable, 2 unless isAvailable

  -- Aegisub hands GDI the cell height as a whole number, so a fractional one truncates there and here
  fontSize = math.floor (style.fontsize or 0) * MEASUREMENT_SCALE
  return 0, 0, 0, 0 unless fontSize > 0

  spacing = (style.spacing or 0) * MEASUREMENT_SCALE

  codePoints, decodeErr = unicode.decodeUtf8 text, unicode.DecodeMode.Strict
  error decodeErr, 2 unless codePoints

  measured, faceErr = acquireFace style
  error faceErr, 2 unless measured

  derived = deriveCellMetrics measured, fontSize

  -- Advances scale per glyph by the realized integer em and never carry kerning, matching the extent
  -- calls GDI answers with; spacing is added once per code point.
  count = #codePoints
  width = count > 0 and sumAdvances(measured, derived.ppem, codePoints) + spacing * count or 0
  height = count > 0 and fontSize or 0

  horizontalScale = (style.scale_x or 100) / 100
  verticalScale = (style.scale_y or 100) / 100

  scaledWidth = horizontalScale * width / MEASUREMENT_SCALE
  scaledHeight = verticalScale * height / MEASUREMENT_SCALE
  scaledDescent = verticalScale * derived.descent / MEASUREMENT_SCALE
  scaledExtlead = verticalScale * derived.extlead / MEASUREMENT_SCALE
  return scaledWidth, scaledHeight, scaledDescent, scaledExtlead

---Aegisub-compatible text measurement through CoreText, for installing as the text-extents backend.
---@class AegisubTextExtentsCoreText
---@field isAvailable boolean Whether the frameworks loaded, so whether `measure` can be called.
---@field measure AegisubTextExtentsBackend Measures by the Windows cell; raises when it cannot.
CoreTextExtents = {
  ---@type boolean
  isAvailable: isAvailable

  ---@type AegisubTextExtentsBackend
  measure: measure
}

UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
return UnitTestSuite\withTestExports CoreTextExtents, {:parseOs2Table, :parseHheaTable,
  :deriveCellMetrics, :mulDivRound}
