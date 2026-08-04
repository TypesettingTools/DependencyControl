-- Measures text through FreeType, resolving font names with fontconfig.
-- Installed as the `aegisub.text_extents` backend by l0.AegisubShims where GDI is not reachable.
--
-- Aegisub's own two implementations do not agree, so which one to reproduce is a choice rather than a
-- detail; see TextExtentsMetricMode. The default reproduces the Windows numbers, which the GDI backend
-- also produces and which libass renders by, so a script measures the same on either platform.

ffi = require "ffi"

Enum = require "l0.DependencyControl.Enum"
ffiFontconfig = require "l0.AegisubShims.helpers.ffi-fontconfig"
ffiFreeType = require "l0.AegisubShims.helpers.ffi-freetype"
unicode = require "l0.DependencyControl.unicode"
utils = require "l0.DependencyControl.utils"

msgs = {
  matchFont: {
    noPattern: "Could not build a fontconfig pattern to look '%s' up with."
    noMatch: "fontconfig found no font to set '%s' in."
    noFile: "fontconfig matched '%s' to a font it could not name a file for."
  }
  acquireFace: {
    openFailed: "FreeType could not open '%s' for the font '%s': %s"
    noTables: "The font '%s' carries no usable OS/2 and hhea tables, so its metrics cannot be read."
  }
  measure: {
    unavailable: "Measuring text needs FreeType and fontconfig, which could not both be loaded."
    noSize: "FreeType would not realize the font '%s' at %d pixels: %s"
    noAdvance: "FreeType would not report the advance of glyph %d in the font '%s': %s"
  }
}

{:freetype, :library, :FaceOut, :AdvanceOut, :KerningOut, :HoriHeaderPointer, :Os2Pointer, :SfntTag,
  :LoadFlag, :KerningMode, :FaceFlag} = ffiFreeType
{:fontconfig, :StringOut, :IntegerOut, :Property, :Weight, :Slant, :MatchKind, :Result} = ffiFontconfig

isAvailable = ffiFreeType.isAvailable and ffiFontconfig.isAvailable

-- Aegisub measures at this multiple of the style's font size and divides the four results back down,
-- which buys six binary digits of resolution the whole-pixel metrics would otherwise round away.
MEASUREMENT_SCALE = 64

-- FreeType reports advances as 16.16 fixed-point pixels and its scaled face metrics as 26.6, so each
-- is divided by the units its format packs into one pixel.
UNITS_PER_PIXEL_16_16 = 65536
UNITS_PER_PIXEL_26_6 = 64

-- reused across calls, since a measurement only ever reads them back before the next one writes
advanceOut, kerningOut = AdvanceOut!, KerningOut!

-- open faces and their design metrics, keyed by what was asked for rather than by what matched
measuredFaces = {}

---Which of Aegisub's two disagreeing metric contracts to measure by.
---@alias TextExtentsMetricMode
---| 1 # AegisubWindows: the OS/2 Windows cell, derived as GDI derives TEXTMETRIC, which is also what libass renders by
---| 2 # AegisubPosix: what Aegisub reports on platforms other than Windows, where wxWidgets exposes only the typographic metrics
MetricMode = Enum "TextExtentsMetricMode", {
  AegisubWindows: 1
  AegisubPosix: 2
}

---How a backend built by `createBackend` should measure.
---@class TextExtentsOptions
---@field metricMode? TextExtentsMetricMode Which contract to measure by, `AegisubWindows` by default.
---@field kerning? boolean Whether to apply the face's kern table to text set solid; defaults to what the mode implies.

---A face fontconfig picked out, as the file holding it.
---@class FontFile
---@field path string Path to the file the face lives in.
---@field index integer Index of the face within that file, zero for a file holding one face.

---Resolves what a style asks for to a font file, substituting as fontconfig sees fit.
---@param family string Family name the style names; an empty one leaves fontconfig its own default.
---@param weight FontconfigWeight Weight to match.
---@param slant FontconfigSlant Slant to match.
---@return FontFile? file Nil when fontconfig could not name a file to use.
---@return string? err Why nothing usable came back.
matchFont = (family, weight, slant) ->
  request = fontconfig.FcPatternCreate!
  return nil, msgs.matchFont.noPattern\format family if request == nil
  ffi.gc request, fontconfig.FcPatternDestroy

  fontconfig.FcPatternAddString request, Property.Family, family
  fontconfig.FcPatternAddInteger request, Property.Weight, weight
  fontconfig.FcPatternAddInteger request, Property.Slant, slant

  -- the user's own fontconfig rules first, then the defaults that fill in whatever they left unset
  fontconfig.FcConfigSubstitute nil, request, MatchKind.Pattern
  fontconfig.FcDefaultSubstitute request

  matched = fontconfig.FcFontMatch nil, request, IntegerOut!
  return nil, msgs.matchFont.noMatch\format family if matched == nil
  ffi.gc matched, fontconfig.FcPatternDestroy

  fileOut = StringOut!
  unless Result.Match == fontconfig.FcPatternGetString matched, Property.File, 0, fileOut
    return nil, msgs.matchFont.noFile\format family

  indexOut = IntegerOut!
  index = 0
  if Result.Match == fontconfig.FcPatternGetInteger matched, Property.Index, 0, indexOut
    index = tonumber indexOut[0]

  return {path: ffi.string(fileOut[0]), :index}

---An open face together with the design values both metric contracts are derived from.
---@class MeasuredFace
---@field face ffi.cdata* The open FT_Face, released when this record is collected.
---@field family string Family the style asked for, which messages name rather than the matched file.
---@field unitsPerEm integer Design units per em, which every design value below is expressed in.
---@field cellHeight integer Height of the cell Windows lays the face out in, in design units.
---@field winDescent integer Depth of that cell below the baseline, in design units.
---@field lineGap integer Leading the face asks for beyond that cell, in design units.
---@field hasKerning boolean Whether the face carries a kern table, the only kerning FreeType reads.

---Opens the font a style asks for, reading the design metrics off it once.
---@param style table An Aegisub style table.
---@return MeasuredFace? measured Nil when no font could be resolved or opened.
---@return string? err Why the font could not be measured with.
acquireFace = (style) ->
  family = style.fontname or ""
  weight = style.bold and Weight.Bold or Weight.Regular
  slant = style.italic and Slant.Italic or Slant.Roman
  requestKey = "#{family}\0#{weight}\0#{slant}"

  cached = measuredFaces[requestKey]
  return cached if cached

  file, matchErr = matchFont family, weight, slant
  return nil, matchErr unless file

  faceOut = FaceOut!
  code = freetype.FT_New_Face library, file.path, file.index, faceOut
  unless code == 0
    return nil, msgs.acquireFace.openFailed\format file.path, family, ffiFreeType.describeError code
  face = ffi.gc faceOut[0], freetype.FT_Done_Face

  os2 = ffi.cast Os2Pointer, freetype.FT_Get_Sfnt_Table face, SfntTag.Os2
  hhea = ffi.cast HoriHeaderPointer, freetype.FT_Get_Sfnt_Table face, SfntTag.Hhea
  if os2 == nil or hhea == nil or os2.version == ffiFreeType.NO_OS2_TABLE_VERSION
    return nil, msgs.acquireFace.noTables\format family

  cellHeight = tonumber(os2.usWinAscent) + tonumber(os2.usWinDescent)
  return nil, msgs.acquireFace.noTables\format family unless cellHeight > 0

  -- The Windows cell already reserves more room than the typographic ascent and descent do, so only
  -- the part of the face's line gap reaching beyond that cell is still leading.
  typographicHeight = tonumber(hhea.Ascender) - tonumber(hhea.Descender)
  lineGap = math.max 0, tonumber(hhea.Line_Gap) - (cellHeight - typographicHeight)

  measured = {
    :face
    :family
    :cellHeight
    :lineGap
    unitsPerEm: tonumber face.units_per_EM
    winDescent: tonumber os2.usWinDescent
    hasKerning: 0 != bit.band tonumber(face.face_flags), FaceFlag.Kerning
  }
  measuredFaces[requestKey] = measured
  return measured

---A face readied for one measurement, with the vertical metrics and the per-glyph lookups a run needs.
---@class PreparedMetrics
---@field descent number Depth below the baseline, in whatever units the advances come back in.
---@field extlead number Leading beyond the line, in those same units.
---@field scaling number Factor taking those units onto the requested cell height.
---@field reportsHeightForEmptyRun boolean Whether an empty string still reports the line height.
---@field advanceOf fun(glyphIndex: integer): number?, string? Advance of one glyph, or why it failed.
---@field kerningOf fun(leftGlyph: integer, rightGlyph: integer): number Kerning between two glyphs, zero where the face has none.

---Readies a face to be measured against its OS/2 Windows cell, deriving the metrics as GDI does.
---@param measured MeasuredFace The face to measure with.
---@param fontSize integer Requested cell height, already multiplied by MEASUREMENT_SCALE.
---@return PreparedMetrics prepared Values already at the requested size, so `scaling` is one.
prepareWindowsCellMetrics = (measured, fontSize) ->
  {:face, :family, :unitsPerEm, :cellHeight} = measured

  -- The em the face is realized at, so its cell comes out at the requested height — what a positive
  -- LOGFONTW.lfHeight asks GDI for. Advances and leading scale by that realized em, while the descent
  -- scales by the requested height directly, which is what pins ascent plus descent to it exactly.
  emPixels = tonumber freetype.FT_MulDiv fontSize, unitsPerEm, cellHeight
  toDeviceUnits = (designUnits) -> tonumber freetype.FT_MulDiv designUnits, emPixels, unitsPerEm

  return {
    descent: tonumber freetype.FT_MulDiv measured.winDescent, fontSize, cellHeight
    extlead: toDeviceUnits measured.lineGap
    scaling: 1
    -- GDI measures a zero-length run as having no height at all
    reportsHeightForEmptyRun: false

    advanceOf: (glyphIndex) ->
      code = freetype.FT_Get_Advance face, glyphIndex, LoadFlag.NoScale, advanceOut
      unless code == 0
        return nil, msgs.measure.noAdvance\format glyphIndex, family, ffiFreeType.describeError code
      return toDeviceUnits tonumber advanceOut[0]

    kerningOf: (leftGlyph, rightGlyph) ->
      code = freetype.FT_Get_Kerning face, leftGlyph, rightGlyph, KerningMode.Unscaled, kerningOut
      return code == 0 and toDeviceUnits(tonumber kerningOut.x) or 0
  }

---Readies a face to be measured as Aegisub does off Windows, where the results are normalized so the
---typographic line height comes out at the nominal font size.
---@param measured MeasuredFace The face to measure with.
---@param fontSize integer Requested cell height, already multiplied by MEASUREMENT_SCALE.
---@return PreparedMetrics? prepared Values at the realized size, which `scaling` normalizes.
---@return string? err Why the face could not be realized at that size.
prepareAegisubPosixMetrics = (measured, fontSize) ->
  {:face, :family} = measured

  code = freetype.FT_Set_Pixel_Sizes face, 0, fontSize
  unless code == 0
    return nil, msgs.measure.noSize\format family, fontSize, ffiFreeType.describeError code

  metrics = face.size.metrics
  ascent = tonumber(metrics.ascender) / UNITS_PER_PIXEL_26_6
  descent = -tonumber(metrics.descender) / UNITS_PER_PIXEL_26_6
  lineHeight = ascent + descent

  return {
    :descent
    -- wxWidgets reports no external leading at all off Windows
    extlead: 0
    scaling: lineHeight > 0 and fontSize / lineHeight or 1
    -- and reports the line height for an empty string, where GDI reports zero
    reportsHeightForEmptyRun: true

    advanceOf: (glyphIndex) ->
      code = freetype.FT_Get_Advance face, glyphIndex, LoadFlag.Default, advanceOut
      unless code == 0
        return nil, msgs.measure.noAdvance\format glyphIndex, family, ffiFreeType.describeError code
      return tonumber(advanceOut[0]) / UNITS_PER_PIXEL_16_16

    kerningOf: (leftGlyph, rightGlyph) ->
      code = freetype.FT_Get_Kerning face, leftGlyph, rightGlyph, KerningMode.Default, kerningOut
      return code == 0 and tonumber(kerningOut.x) / UNITS_PER_PIXEL_26_6 or 0
  }

prepareByMode = {
  [MetricMode.AegisubWindows]: prepareWindowsCellMetrics
  [MetricMode.AegisubPosix]: prepareAegisubPosixMetrics
}

-- GDI measures the characters one by one and never consults the kern table, while wxWidgets shapes
-- the run through the platform's text engine and does.
defaultsByMode = {
  [MetricMode.AegisubWindows]: {kerning: false}
  [MetricMode.AegisubPosix]: {kerning: true}
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

  ---@param style table An Aegisub style table.
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

    spacing = (style.spacing or 0) * MEASUREMENT_SCALE

    codePoints, decodeErr = unicode.decodeUtf8 text, unicode.DecodeMode.Strict
    error decodeErr, 2 unless codePoints

    measured, faceErr = acquireFace style
    error faceErr, 2 unless measured

    prepared, prepareErr = prepare measured, fontSize
    error prepareErr, 2 unless prepared

    -- Aegisub's POSIX spacing branch measures character by character, so an empty run never reads the
    -- face at all and every metric stays zero, descent and leading included.
    return 0, 0, 0, 0 if prepared.reportsHeightForEmptyRun and spacing != 0 and #codePoints == 0

    -- kerning describes text set solid, so inter-character spacing rules it out however it was asked for
    kerns = applyKerning and spacing == 0 and measured.hasKerning

    width, previousGlyph = 0, nil
    for codePoint in *codePoints
      glyphIndex = freetype.FT_Get_Char_Index measured.face, codePoint
      width += prepared.kerningOf previousGlyph, glyphIndex if kerns and previousGlyph
      advance, advanceErr = prepared.advanceOf glyphIndex
      error advanceErr, 2 unless advance
      width += advance + spacing
      previousGlyph = glyphIndex

    horizontalScale = (style.scale_x or 100) / 100
    verticalScale = (style.scale_y or 100) / 100

    -- An empty run has no height under GDI but keeps the line height under wxWidgets — except that
    -- Aegisub's spacing branch measures character by character, so with spacing set an empty run is
    -- never measured at all and the height stays zero on both.
    measuresEmptyRun = prepared.reportsHeightForEmptyRun and spacing == 0
    height = (#codePoints > 0 or measuresEmptyRun) and fontSize or 0

    scaledWidth = horizontalScale * width * prepared.scaling / MEASUREMENT_SCALE
    scaledHeight = verticalScale * height / MEASUREMENT_SCALE
    scaledDescent = verticalScale * prepared.descent * prepared.scaling / MEASUREMENT_SCALE
    scaledExtlead = verticalScale * prepared.extlead * prepared.scaling / MEASUREMENT_SCALE
    return scaledWidth, scaledHeight, scaledDescent, scaledExtlead

---Aegisub-compatible text measurement through FreeType, for installing as the text-extents backend.
---@class AegisubTextExtentsFreeType
---@field isAvailable boolean Whether FreeType and fontconfig both loaded, so whether measuring works.
---@field measure AegisubTextExtentsBackend Measures by the Windows cell; raises when it cannot.
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
