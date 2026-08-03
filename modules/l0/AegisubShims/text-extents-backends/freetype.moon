ffi = require "ffi"
ffiFontconfig = require "l0.AegisubShims.helpers.ffi-fontconfig"
ffiFreeType = require "l0.AegisubShims.helpers.ffi-freetype"
gdiMetrics = require "l0.AegisubShims.helpers.gdi-metrics"
sfnt = require "l0.AegisubShims.helpers.sfnt"
textExtents = require "l0.AegisubShims.text-extents"
unicode = require "l0.DependencyControl.unicode"
utils = require "l0.DependencyControl.utils"

msgs = {
  matchFont: {
    noPattern: "Could not build a fontconfig pattern to look '%s' up with."
    noMatch: "fontconfig found no font to set '%s' in."
    noFile: "fontconfig matched '%s' to a font it could not name a file for."
  }
  resolveFace: {
    openFailed: "FreeType could not open '%s' for the font '%s': %s"
    noTables: "The font '%s' has no usable OS/2 and hhea tables, so its metrics cannot be read."
  }
  prepareAegisubMacMetrics: {
    noSpan: "The font '%s' declares no usable line height, so the macOS contract cannot be derived for it."
  }
  measure: {
    unavailable: "Measuring text needs FreeType and fontconfig, which could not both be loaded."
    noSize: "FreeType would not realize the font '%s' at %d pixels: %s"
    noAdvance: "FreeType would not report the advance of glyph %d in the font '%s': %s"
  }
  createBackend: {
    badDpi: "A DPI has to be a positive number, got %s."
  }
}

{:freetype, :library, :FaceOut, :AdvanceOut, :KerningOut, :HoriHeaderPointer, :Os2Pointer, :SfntTag,
  :LoadFlag, :KerningMode, :FaceFlag} = ffiFreeType
{:fontconfig, :StringOut, :IntegerOut, :Property, :Weight, :Slant, :MatchKind, :Result} = ffiFontconfig
-- Every C symbol this backend names, bound here rather than read off the namespace at each call, so a
-- name the helper does not declare fails when this module loads instead of when the call is reached.
{:FT_Done_Face, :FT_Get_Advance, :FT_Get_Char_Index, :FT_Get_Kerning, :FT_Get_Sfnt_Table, :FT_New_Face,
  :FT_Set_Pixel_Sizes} = freetype
{:FcConfigSubstitute, :FcDefaultSubstitute, :FcFontMatch, :FcPatternAddInteger, :FcPatternAddString,
  :FcPatternCreate, :FcPatternDestroy, :FcPatternGetInteger, :FcPatternGetString} = fontconfig

isAvailable = ffiFreeType.isAvailable and ffiFontconfig.isAvailable

{:MEASUREMENT_SCALE, :POINTS_PER_INCH, :DEFAULT_DPI, :MetricMode} = textExtents

-- FreeType reports advances as 16.16 fixed-point pixels and its scaled face metrics as 26.6, so each
-- is divided by the units its format packs into one pixel.
UNITS_PER_PIXEL_16_16 = 65536
UNITS_PER_PIXEL_26_6 = 64

-- reused across calls, since a measurement only ever reads them back before the next one writes
advanceOut, kerningOut = AdvanceOut!, KerningOut!

-- matched files by what was asked for, and open faces by the file a request matched to, so two
-- requests fontconfig answers with the same file share one open face and one set of metrics
matchedFiles, resolvedFaces = {}, {}

---A face fontconfig picked out, as the file holding it.
---@class FontFile
---@field path string Path to the file the face lives in.
---@field index integer Index of the face within that file, zero for a file holding one face.
---@field family string Family that was asked for, which messages name rather than the matched file.

---Resolves a font request to a font file, substituting as fontconfig sees fit.
---
---Takes either a style, whose family, bold and italic fields make the request, or those three
---directly for a caller measuring outside a style.
---@param family string Family name to match; an empty one leaves fontconfig its own default.
---@param weight? FontconfigWeight Weight to match, Regular by default.
---@param slant? FontconfigSlant Slant to match, Roman by default.
---@return FontFile? file Nil when fontconfig could not name a file to use.
---@return string? err Why nothing usable came back.
---@overload fun(style: AegisubStyle): FontFile?, string?
matchFont = (family, weight = Weight.Regular, slant = Slant.Roman) ->
  if "table" == type family
    style = family
    family = style.fontname
    weight = style.bold and Weight.Bold or Weight.Regular
    slant = style.italic and Slant.Italic or Slant.Roman
  family or= ""

  requestKey = "#{family}\0#{weight}\0#{slant}"
  cached = matchedFiles[requestKey]
  return cached if cached

  request = FcPatternCreate!
  return nil, msgs.matchFont.noPattern\format family if request == nil
  ffi.gc request, FcPatternDestroy

  FcPatternAddString request, Property.Family, family
  FcPatternAddInteger request, Property.Weight, weight
  FcPatternAddInteger request, Property.Slant, slant

  -- the user's own fontconfig rules first, then the defaults that fill in whatever they left unset
  FcConfigSubstitute nil, request, MatchKind.Pattern
  FcDefaultSubstitute request

  matched = FcFontMatch nil, request, IntegerOut!
  return nil, msgs.matchFont.noMatch\format family if matched == nil
  ffi.gc matched, FcPatternDestroy

  fileOut = StringOut!
  unless Result.Match == FcPatternGetString matched, Property.File, 0, fileOut
    return nil, msgs.matchFont.noFile\format family

  indexOut = IntegerOut!
  index = 0
  if Result.Match == FcPatternGetInteger matched, Property.Index, 0, indexOut
    index = tonumber indexOut[0]

  file = {path: ffi.string(fileOut[0]), :index, :family}
  matchedFiles[requestKey] = file
  return file

---Copies a horizontal header off the FT_Face into the shape the SFNT parser produces, so a face read
---through FreeType and one read through another library are the same record downstream.
---@param hhea ffi.cdata* The TT_HoriHeader FT_Get_Sfnt_Table handed back.
---@return ParsedHheaTable parsed The header's fields, as Lua numbers.
toParsedHheaTable = (hhea) ->
  return {
    majorVersion: math.floor tonumber(hhea.Version) / 0x10000
    minorVersion: bit.band tonumber(hhea.Version), 0xFFFF
    ascender: tonumber hhea.Ascender
    descender: tonumber hhea.Descender
    lineGap: tonumber hhea.Line_Gap
    advanceWidthMax: tonumber hhea.advance_Width_Max
    minLeftSideBearing: tonumber hhea.min_Left_Side_Bearing
    minRightSideBearing: tonumber hhea.min_Right_Side_Bearing
    xMaxExtent: tonumber hhea.xMax_Extent
    caretSlopeRise: tonumber hhea.caret_Slope_Rise
    caretSlopeRun: tonumber hhea.caret_Slope_Run
    caretOffset: tonumber hhea.caret_Offset
    metricDataFormat: tonumber hhea.metric_Data_Format
    numberOfHMetrics: tonumber hhea.number_Of_HMetrics
  }

---Copies an OS/2 table off the FT_Face into the shape the SFNT parser produces, as far as the version
---the face declares reaches. FreeType zeroes the fields a version predates rather than leaving them
---out, so the version gates them here for the two sources to agree.
---@param os2 ffi.cdata* The TT_OS2 FT_Get_Sfnt_Table handed back.
---@return ParsedOs2Table parsed The table's fields, as Lua numbers.
toParsedOs2Table = (os2) ->
  version = tonumber os2.version
  parsed = {
    :version
    avgCharWidth: tonumber os2.xAvgCharWidth
    weightClass: tonumber os2.usWeightClass
    widthClass: tonumber os2.usWidthClass
    fsType: tonumber os2.fsType
    subscriptXSize: tonumber os2.ySubscriptXSize
    subscriptYSize: tonumber os2.ySubscriptYSize
    subscriptXOffset: tonumber os2.ySubscriptXOffset
    subscriptYOffset: tonumber os2.ySubscriptYOffset
    superscriptXSize: tonumber os2.ySuperscriptXSize
    superscriptYSize: tonumber os2.ySuperscriptYSize
    superscriptXOffset: tonumber os2.ySuperscriptXOffset
    superscriptYOffset: tonumber os2.ySuperscriptYOffset
    strikeoutSize: tonumber os2.yStrikeoutSize
    strikeoutPosition: tonumber os2.yStrikeoutPosition
    familyClass: tonumber os2.sFamilyClass
    panose: [tonumber os2.panose[digit] for digit = 0, 9]
    unicodeRange1: tonumber os2.ulUnicodeRange1
    unicodeRange2: tonumber os2.ulUnicodeRange2
    unicodeRange3: tonumber os2.ulUnicodeRange3
    unicodeRange4: tonumber os2.ulUnicodeRange4
    vendorId: ffi.string os2.achVendID, 4
    fsSelection: tonumber os2.fsSelection
    firstCharIndex: tonumber os2.usFirstCharIndex
    lastCharIndex: tonumber os2.usLastCharIndex
    typoAscender: tonumber os2.sTypoAscender
    typoDescender: tonumber os2.sTypoDescender
    typoLineGap: tonumber os2.sTypoLineGap
    winAscent: tonumber os2.usWinAscent
    winDescent: tonumber os2.usWinDescent
  }

  if version >= 1
    parsed.codePageRange1 = tonumber os2.ulCodePageRange1
    parsed.codePageRange2 = tonumber os2.ulCodePageRange2

  if version >= 2
    parsed.xHeight = tonumber os2.sxHeight
    parsed.capHeight = tonumber os2.sCapHeight
    parsed.defaultChar = tonumber os2.usDefaultChar
    parsed.breakChar = tonumber os2.usBreakChar
    parsed.maxContext = tonumber os2.usMaxContext

  if version >= 5
    parsed.lowerOpticalPointSize = tonumber os2.usLowerOpticalPointSize
    parsed.upperOpticalPointSize = tonumber os2.usUpperOpticalPointSize

  return parsed

---A face opened from a matched file, with the shared design values and what FreeType adds to them.
---@class FreeTypeFace: ResolvedFace
---@field face ffi.cdata* The open FT_Face, released when this record is collected.
---@field hasKerning boolean Whether the face has a kern table, the only kerning FreeType reads.

---Opens a matched font file and reads the design metrics off it, once per file and family.
---@param file FontFile The file to resolve, as `matchFont` matched it.
---@return FreeTypeFace? resolved Nil when the file could not be opened or has no usable metrics.
---@return string? err Why the font could not be measured with.
resolveFace = (file) ->
  {:path, :index, :family} = file
  -- keyed by the family as well as the file, so a message still names what its own caller asked for
  requestKey = "#{family}\0#{path}\0#{index}"

  cached = resolvedFaces[requestKey]
  return cached if cached

  faceOut = FaceOut!
  code = FT_New_Face library, path, index, faceOut
  unless code == 0
    return nil, msgs.resolveFace.openFailed\format path, family, ffiFreeType.describeError code
  face = ffi.gc faceOut[0], FT_Done_Face

  os2 = ffi.cast Os2Pointer, FT_Get_Sfnt_Table face, SfntTag.Os2
  hhea = ffi.cast HoriHeaderPointer, FT_Get_Sfnt_Table face, SfntTag.Hhea
  if os2 == nil or hhea == nil or os2.version == ffiFreeType.NO_OS2_TABLE_VERSION
    return nil, msgs.resolveFace.noTables\format family

  parsedOs2 = toParsedOs2Table os2
  cellHeight = gdiMetrics.getCellHeight parsedOs2
  return nil, msgs.resolveFace.noTables\format family unless cellHeight > 0

  resolved = {
    :face
    :family
    :cellHeight
    os2: parsedOs2
    hhea: toParsedHheaTable hhea
    unitsPerEm: tonumber face.units_per_EM
    hasKerning: 0 != bit.band tonumber(face.face_flags), FaceFlag.Kerning
    hasCffOutlines: ffiFreeType.isCffOutlined face
  }
  resolvedFaces[requestKey] = resolved
  return resolved

---A face readied for one measurement, with the vertical metrics and the per-glyph lookups a run needs.
---@class PreparedMetrics
---@field descent number Depth below the baseline, in whatever units the advances come back in.
---@field extlead number Leading beyond the line, in those same units.
---@field normalize fun(width: number, height: number, descent: number, extlead: number): number, number, number, number Takes a measured run onto the requested cell height.
---@field reportsHeightForEmptyRun boolean Whether an empty string still reports the line height.
---@field spacingOf fun(spacing: number): number The device units one character adds for the style's `spacing`.
---@field advanceOf fun(glyphIndex: integer): number?, string? Advance of one glyph, or why it failed.
---@field kerningOf fun(leftGlyph: integer, rightGlyph: integer): number Kerning between two glyphs, zero where the face has none.

---Hands a measured run on unchanged, for a contract whose advances already come back at the requested
---cell height.
---@param width number Advance the run takes.
---@param height number Line height.
---@param descent number Depth below the baseline.
---@param extlead number Leading beyond the line.
---@return number width The advance, unchanged.
---@return number height The line height, unchanged.
---@return number descent The depth below the baseline, unchanged.
---@return number extlead The leading, unchanged.
measuredAtRequestedSize = (width, height, descent, extlead) -> width, height, descent, extlead

---Readies a face to be measured against its OS/2 Windows cell, deriving the metrics as GDI does.
---
---Measured against GDI over a 36-face test corpus at four sizes, all four values are exact on 81.4%
---of the 1757 cases where the face has glyphs for the whole text and land within a 64th of a device
---pixel on 96.5%, with a mean width error of 0.046%. The height is never off by more than that 64th
---and the external leading is exact; the remaining width misses are GDI grid-fitting each glyph. A face setting fsSelection
---USE_TYPO_METRICS changes nothing here: GDI ignores the bit, and this derivation reads the same
---usWin and hhea values GDI reads.
---
---Where the face lacks a glyph for a character the mean width error is 31.5% over 413 cases. GDI
---substitutes another face for that character and reports its advance, while this backend resolves
---one face per style and measures .notdef. That figure depends on what is installed and says nothing
---about the derivation.
---
---Kerning reads only the legacy `kern` table, so a face kerning through GPOS alone measures without
---any. The style's `encoding` is ignored, which is where the descent and the leading still differ.
---@param resolved FreeTypeFace The face to measure with.
---@param fontSize integer Requested cell height, already multiplied by MEASUREMENT_SCALE.
---@return PreparedMetrics prepared Values already at the requested size, so nothing is normalized.
prepareAegisubWindowsMetrics = (resolved, fontSize, dpi) ->
  {:face, :family} = resolved

  -- GDI rasterizes at integer ppem values, so the advances and the leading are calculated off the
  -- realized/rounded em rather than the requested one to match what GDI reports.
  -- The cell metrics never reach the rasterizer: at a positive `LOGFONTW.lfHeight = fontSize`, GDI
  -- scales both `tmAscent` and `tmDescent` straight off that requested height in the ratio the design
  -- metrics hold, and reports `tmHeight` as their sum. Rounding the two separately is why that sum is
  -- only usually fontSize, landing a 64th of a pixel either side of it at a couple of sizes per face.
  derived = gdiMetrics.deriveTextMetrics resolved, fontSize
  toDeviceUnits = derived.toDeviceUnits

  kerningMode = KerningMode.Unscaled -- read once to avoid metamethod overhead on hot path
  return {
    descent: derived.descent
    extlead: derived.extlead
    normalize: measuredAtRequestedSize
    -- GDI measures a zero-length run as having no height at all
    reportsHeightForEmptyRun: false
    -- and adds the spacing as given, having no divisor to put it through
    spacingOf: (spacing) -> spacing * MEASUREMENT_SCALE

    advanceOf: (glyphIndex) ->
      code = FT_Get_Advance face, glyphIndex, LoadFlag.NoScale, advanceOut
      unless code == 0
        return nil, msgs.measure.noAdvance\format glyphIndex, family, ffiFreeType.describeError code
      return toDeviceUnits tonumber advanceOut[0]

    kerningOf: (leftGlyph, rightGlyph) ->
      code = FT_Get_Kerning face, leftGlyph, rightGlyph, kerningMode, kerningOut
      return code == 0 and toDeviceUnits(tonumber kerningOut.x) or 0
  }

---Readies a face to be measured as Aegisub does on Linux, where the results are normalized so the
---typographic line height comes out at the nominal font size.
---
---Measured against a running Aegisub 3.4.2 on Ubuntu over a 36-face test corpus at four sizes, the
---mean width error is 0.556% on the 1757 cases where the face has glyphs for the whole text. Height
---and external leading are exact on every case.
---Where the face lacks a glyph the mean width error is 39.8% over 413 cases, Pango substituting
---another face per character where this backend measures .notdef.
---A face setting fsSelection USE_TYPO_METRICS takes its span from the OS/2 sTypo values instead of
---the hhea ones, in Pango and FreeType alike, so this mode follows Aegisub there too — to 0.3% on
---the corpus face where that redirect moves every metric by 1.68x.
---
---Kerning is the largest residual. This mode reads only the legacy `kern` table, while Pango kerns
---through GPOS, so a face whose GPOS values the kern table does not duplicate measures differently on
---any text with kerning pairs: 3.1% mean on two-letter pairs over the 21 corpus faces with GPOS and
---no kern table, 6.1% on Calibri where the two tables disagree, and nothing on text without pairs or
---on a face kerning through the kern table alone.
---
---A style setting `spacing` is measured to 0.019% over those cases at the default DPI of 96. Aegisub
---adds the spacing after measuring and then divides by the line height it measured, which leaves the
---spacing scaled by the DPI the text was realized at while the advances scale with that height and
---cancel out. This mode scales it the same way. To reproduce Aegisub's measurements on a high-DPI
---display, configure the backend with that display's DPI.
---
---Measured against GDI over the same corpus, the mean width error is 15.8% on the cases where the
---face has glyphs for the whole text, and the descent is off by 10.8%.
---The deviation is largely driven by ignoring the Windows cell dimensions (`usWinAscent` and `usWinDescent`
---in the OS/2 table) yielding values off by the ratio between the Windows cell height and the
---typographic span — the hhea one, or the OS/2 sTypo one for a face setting fsSelection
---USE_TYPO_METRICS, which FreeType honors and GDI ignores. As usually the Windows cell is taller or
---equal to the typographic span, results usually skew larger than GDI's (between 0.98x and 2.195x in
---the corpus) because any padding the Windows cell would have added doesn't have to fit into the
---total line height, which is fixed to the nominal font size.
---The ratio accounts for 90.0% of the cases, and when removed, the mean error reduces to 0.785%.
---The external leading differs by 19.4% for a different reason. It is reported as zero here whatever
---line gap the face declares, so the ratio has no bearing on it.
---
---The style's `encoding` is ignored, as the wx branch ignores it.
---@param resolved FreeTypeFace The face to measure with.
---@param fontSize integer Requested em size, already multiplied by MEASUREMENT_SCALE.
---@return PreparedMetrics? prepared Values at the realized size, which `normalize` takes to the requested one.
---@return string? err Why the face could not be realized at that size.
prepareAegisubLinuxMetrics = (resolved, fontSize, dpi) ->
  {:face, :family} = resolved

  code = FT_Set_Pixel_Sizes face, 0, fontSize
  unless code == 0
    return nil, msgs.measure.noSize\format family, fontSize, ffiFreeType.describeError code

  metrics = face.size.metrics
  ascent = tonumber(metrics.ascender) / UNITS_PER_PIXEL_26_6
  descent = -tonumber(metrics.descender) / UNITS_PER_PIXEL_26_6
  kerningMode = KerningMode.Default

  -- Wx reports the run's width, height, descent and leading in pixels; Aegisub multiplies all four by
  -- `fontSize` over the reported pixel height, which brings the final height out at `fontSize`.
  --
  -- Since FreeType doesn't do layout, we use Pango's formula with FreeType's pixel values to arrive at
  -- a pixel height that yields the same factor, which then scales FreeType's pixel advances.
  -- The final height is not scaled here, since it has already been fixed to the nominal font size.
  lineHeight = ascent + descent
  toRequestedSize = lineHeight > 0 and fontSize / lineHeight or 1
  normalize = (width, height, descent, extlead) ->
    return width * toRequestedSize, height, descent * toRequestedSize, extlead * toRequestedSize

  return {
    :descent
    :normalize

    -- wxGTK reports no external leading at all
    extlead: 0

    -- and reports the line height for an empty string, where GDI reports zero
    reportsHeightForEmptyRun: true

    -- the line-height divisor leaves the spacing scaled by the resolution
    spacingOf: (spacing) -> spacing * MEASUREMENT_SCALE * POINTS_PER_INCH / dpi

    advanceOf: (glyphIndex) ->
      code = FT_Get_Advance face, glyphIndex, LoadFlag.Default, advanceOut
      unless code == 0
        return nil, msgs.measure.noAdvance\format glyphIndex, family, ffiFreeType.describeError code
      return tonumber(advanceOut[0]) / UNITS_PER_PIXEL_16_16

    kerningOf: (leftGlyph, rightGlyph) ->
      code = FT_Get_Kerning face, leftGlyph, rightGlyph, kerningMode, kerningOut
      return code == 0 and tonumber(kerningOut.x) / UNITS_PER_PIXEL_26_6 or 0
  }

---Readies a face to be measured as Aegisub does on macOS, where the results are normalized so the
---hhea line span, the line gap included, comes out at the nominal font size.
---
---Measured against a running Aegisub 3.4.2 on macOS over a 36-face test corpus at four sizes, the mean
---width error is 0.537% on the 1757 cases where the face has glyphs for the whole text, with the
---descent off by 0.065% and the external leading by 0.105%. Height is exact on every case, and all
---four metrics land within a 64th on 79.3% of those 1757.
---Where the face lacks a glyph the width error is 23.6% over 413 cases, the descent 26.6% and the
---leading 49.7%. macOS substitutes another face per character there and reports that face's metrics,
---the vertical ones as much as the widths, where this reads one face's tables throughout.
---
---Measured against GDI over the same corpus, the mean width error is 14.3% on the 1569 non-empty cases
---whose text the face can set, and the descent is off by 17.6%.
---The deviation has the same shape the Linux contract's does, differing only in which span stands in
---for the Windows cell: normalizing against the hhea line height rather than `usWinAscent` plus
---`usWinDescent` puts every width a factor of winCell/hheaSpan away from GDI's. Dividing that ratio
---out takes the width error to 0.798%, and it improves the figure on 99.0% of the 901 cases whose face
---states the two spans differently. A face whose cell and line height agree measures the same either
---way, since the line gap is most of what separates them.
---The hhea values are read no matter fsSelection USE_TYPO_METRICS asks, the macOS text stack ignoring
---that bit as GDI does, so the sTypo redirect that moves the Linux contract leaves this one where it is.
---External leading scales directly off the hhea line gap, with no deduction for the room the Windows
---cell adds beyond the typographic span. It is also read off a PostScript-outlined face, where GDI
---reads none at all: on the eight CJK corpus faces declaring a full em of gap, GDI reports zero
---external leading and this reports a whole extra line. The span ratio has no bearing on either.
---@param resolved FreeTypeFace The face to measure with.
---@param fontSize integer Requested line span, already multiplied by MEASUREMENT_SCALE.
---@return PreparedMetrics? prepared Values already at the requested size, so nothing is normalized.
---@return string? err Why the contract could not be derived for the face.
prepareAegisubMacMetrics = (resolved, fontSize, dpi) ->
  {:face, :family, :unitsPerEm, :hhea} = resolved
  lineHeight = sfnt.getLineHeight hhea
  return nil, msgs.prepareAegisubMacMetrics.noSpan\format family unless lineHeight > 0

  -- CoreText lays a run out at a fractional em, so nothing here rounds to a whole pixel the way the
  -- GDI derivation has to.
  emPixels = fontSize * unitsPerEm / lineHeight
  toDeviceUnits = (designUnits) -> designUnits * emPixels / unitsPerEm

  kerningMode = KerningMode.Unscaled -- read once to avoid metamethod overhead on hot path
  return {
    descent: -hhea.descender * fontSize / lineHeight
    extlead: hhea.lineGap * fontSize / lineHeight
    normalize: measuredAtRequestedSize
    -- macOS measures a zero-length run as having no height at all, just like GDI does
    reportsHeightForEmptyRun: false
    -- spacing joins the run in the realized em rather than in the requested size, so it scales with it
    spacingOf: (spacing) -> spacing * MEASUREMENT_SCALE * unitsPerEm / lineHeight

    advanceOf: (glyphIndex) ->
      code = FT_Get_Advance face, glyphIndex, LoadFlag.NoScale, advanceOut
      unless code == 0
        return nil, msgs.measure.noAdvance\format glyphIndex, family, ffiFreeType.describeError code
      return toDeviceUnits tonumber advanceOut[0]

    kerningOf: (leftGlyph, rightGlyph) ->
      code = FT_Get_Kerning face, leftGlyph, rightGlyph, kerningMode, kerningOut
      return code == 0 and toDeviceUnits(tonumber kerningOut.x) or 0
  }

prepareByMode = {
  [MetricMode.AegisubWindows]: prepareAegisubWindowsMetrics
  [MetricMode.AegisubLinux]: prepareAegisubLinuxMetrics
  [MetricMode.AegisubMac]: prepareAegisubMacMetrics
}

-- GDI measures the characters one by one and never consults the kern table, while wxWidgets shapes
-- the run through the platform's text engine and does.
defaultsByMode = {
  [MetricMode.AegisubWindows]: {kerning: false}
  [MetricMode.AegisubLinux]: {kerning: true}
  [MetricMode.AegisubMac]: {kerning: true}
}

---Builds a text-extents backend measuring by a chosen contract.
---@param options? TextExtentsOptions How to measure; each key left out follows the mode.
---@return AegisubTextExtentsBackend measure Measures a run of text, raising where it cannot.
createBackend = (options) ->
  utils.assertArgType options, 1, "table" if options != nil
  options or= {}

  metricMode = options.metricMode or MetricMode.AegisubWindows
  valid, modeErr = MetricMode\validate metricMode, "options.metricMode"
  assert valid, modeErr

  prepare = prepareByMode[metricMode]
  applyKerning = defaultsByMode[metricMode].kerning
  applyKerning = options.kerning if options.kerning != nil

  dpi = options.dpi or DEFAULT_DPI
  assert "number" == type(dpi) and dpi > 0,
    msgs.createBackend.badDpi\format tostring options.dpi

  ---@param style AegisubStyle The style to set the text in.
  ---@param text string The text to measure.
  ---@return number width Advance the run takes, trailing spaces included, after the style's scale_x.
  ---@return number height Line height of the realized face, not the glyphs' bounds, after scale_y.
  ---@return number descent Depth below the baseline, read from the face, so the same for any text.
  ---@return number extlead Gap the face asks for between lines, also read from it rather than the text.
  return (style, text) ->
    error msgs.measure.unavailable, 2 unless isAvailable

    -- Aegisub hands GDI the cell height as a whole number, so a fractional one truncates there and here
    fontSize = math.floor (style.fontsize or 0) * MEASUREMENT_SCALE
    return 0, 0, 0, 0 unless fontSize > 0

    hasSpacing = (style.spacing or 0) != 0

    codePoints, decodeErr = unicode.decodeUtf8 text, unicode.DecodeMode.Strict
    error decodeErr, 2 unless codePoints

    file, matchErr = matchFont style
    error matchErr, 2 unless file

    resolved, faceErr = resolveFace file
    error faceErr, 2 unless resolved

    prepared, prepareErr = prepare resolved, fontSize, dpi
    error prepareErr, 2 unless prepared

    spacing = prepared.spacingOf style.spacing or 0

    -- Aegisub's non-Windows code branch for spacing measures character by character, so an empty run
    -- never reads the face at all and *every* metric stays zero, descent and leading included.
    return 0, 0, 0, 0 if prepared.reportsHeightForEmptyRun and hasSpacing and #codePoints == 0

    -- kerning describes text set solid, so inter-character spacing rules it out however it was asked for
    kerns = applyKerning and not hasSpacing and resolved.hasKerning

    width, previousGlyph = 0, nil
    for codePoint in *codePoints
      glyphIndex = FT_Get_Char_Index resolved.face, codePoint
      width += prepared.kerningOf previousGlyph, glyphIndex if kerns and previousGlyph
      advance, advanceErr = prepared.advanceOf glyphIndex
      error advanceErr, 2 unless advance
      width += advance + spacing
      previousGlyph = glyphIndex

    -- An empty string produces a line height equal to the nominal font size under wxGTK/Pango,
    -- as opposed to 0 under GDI (except in the above-mentioned spacing case where it is 0 under both).
    measuresEmptyRun = prepared.reportsHeightForEmptyRun and not hasSpacing
    height = (#codePoints > 0 or measuresEmptyRun) and fontSize or 0

    return textExtents.applyStyleScale style,
      prepared.normalize width, height, prepared.descent, prepared.extlead

---Aegisub-compatible text measurement through FreeType, with font names resolved by fontconfig.
---`l0.AegisubShims` installs it as the `aegisub.text_extents` backend wherever GDI is not reachable.
---
---Aegisub measures through whichever library the platform it was built for offers:
---
--- * Windows — GDI, whose numbers libass and VSFilter also render by
--- * Linux and the other X11 platforms — Pango, by way of wxGTK
--- * macOS — CoreText, by way of wxOSX
---
---Its source has one branch for Windows and one for everything else, but that second branch measures
---through wxWidgets, which makes it two implementations disagreeing with each other about as much as
---either disagrees with GDI. Each is a metric contract here, chosen through `TextExtentsMetricMode`
---and measured against a running Aegisub over the same 36-face corpus.
---
---`AegisubWindows` is the default on every platform, so a script measures the same numbers wherever it
---runs, and the ones the renderer will lay the subtitle out by.
---@class AegisubTextExtentsFreeType
---@field isAvailable boolean Whether FreeType and fontconfig both loaded, so whether measuring works.
---@field measure AegisubTextExtentsBackend Measures by the Windows cell; throws when it cannot.
---@field createBackend fun(options?: TextExtentsOptions): AegisubTextExtentsBackend Builds a backend measuring by a chosen contract.
---@field MetricMode Enum The metric contracts on offer, as a TextExtentsMetricMode enum.
return {
  ---@type boolean
  isAvailable: isAvailable
  ---@type AegisubTextExtentsBackend
  measure: createBackend!
  createBackend: createBackend
  MetricMode: MetricMode
}
