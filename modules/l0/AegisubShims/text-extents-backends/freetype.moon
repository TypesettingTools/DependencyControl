-- cspell:ignore Marlett -- the Windows face the charmap order below is settled by
ffi = require "ffi"
constants = require "l0.DependencyControl.Constants"
ffiFontconfig = require "l0.AegisubShims.helpers.ffi-fontconfig"
ffiFreeType = require "l0.AegisubShims.helpers.ffi-freetype"
fontEncoding = require "l0.AegisubShims.helpers.font-encoding"
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
    notScalable: "The font '%s' has no scalable outlines, so it cannot be set at an arbitrary size."
  }
  prepareAegisubWindowsMetrics: {
    noCell: "The font '%s' declares no usable OS/2 Windows cell, and the %s fallback offers no span to measure it by."
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
  :LoadFlag, :KerningMode, :FaceFlag, :Encoding} = ffiFreeType
{:fontconfig, :StringOut, :IntegerOut, :CharSetOut, :Property, :Weight, :Slant, :MatchKind,
  :Result} = ffiFontconfig
-- Every C symbol this backend names, bound here rather than read off the namespace at each call, so a
-- name the helper does not declare fails when this module loads instead of when the call is reached.
{:FT_Done_Face, :FT_Get_Advance, :FT_Get_Char_Index, :FT_Get_Kerning, :FT_Get_Sfnt_Table, :FT_New_Face,
  :FT_Select_Charmap, :FT_Set_Pixel_Sizes} = freetype
{:FcCharSetHasChar, :FcConfigSubstitute, :FcDefaultSubstitute, :FcFontMatch, :FcFontSetDestroy,
  :FcFontSort, :FcPatternAddInteger, :FcPatternAddString, :FcPatternCreate, :FcPatternDestroy,
  :FcPatternGetCharSet, :FcPatternGetInteger, :FcPatternGetString} = fontconfig

isAvailable = ffiFreeType.isAvailable and ffiFontconfig.isAvailable

{:MEASUREMENT_SCALE, :POINTS_PER_INCH, :DEFAULT_DPI, :MetricMode, :VerticalMetricFallbackBehavior} = textExtents

-- FreeType reports advances as 16.16 fixed-point pixels and its scaled face metrics as 26.6, so each
-- is divided by the units its format packs into one pixel.
UNITS_PER_PIXEL_16_16 = 65536
UNITS_PER_PIXEL_26_6 = 64

-- reused across calls, since a measurement only ever reads them back before the next one writes
advanceOut, kerningOut = AdvanceOut!, KerningOut!

-- .notdef, which every font reserves at index zero for a character it cannot draw
MISSING_GLYPH_INDEX = 0

-- the encoder for each charmap FreeType can select, keyed by the encoding it is selected under
asCodePoint = fontEncoding.encoderFor fontEncoding.Encoding.Unicode

charmapIndexers = {
  [Encoding.MsSymbol]: fontEncoding.encoderFor fontEncoding.Encoding.Symbol
  [Encoding.AppleRoman]: fontEncoding.encoderFor fontEncoding.Encoding.MacRoman
}

-- A cache of matched faces and resolved metrics, both by keyed by the requested traits.
matchedFaces, resolvedFaceMetrics = {}, {}

---The face fontconfig selected, addressed by the file holding it and its index within that file.
---@class MatchedFace
---@field path string Path to the file the face lives in.
---@field index integer Index of the face within that file, zero for a file holding one face.
---@field family string The family name that was requested, not one read from the matched face.
---@field weight FontconfigWeight The weight that was requested.
---@field slant FontconfigSlant The slant that was requested.
---@field substituted boolean True when the selected face matches none of the requested names.

-- A family name no font uses, added after the requested one to mark where its aliases end.
-- fontconfig appends its full default fallback chain to every request, including one it cannot
-- resolve, so the names before this marker are the requested name's aliases and the rest is the chain.
FAMILY_ALIASES_END = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}FamilyAliasesEnd"

-- keyed by the family alone, since fontconfig expands a name to the same aliases at every weight
acceptedNamesByFamily = {}

---Returns the requested family name together with the aliases fontconfig maps it to.
---
---fontconfig maps a generic family to whatever the machine has, so DejaVu Sans is a valid match for
---sans-serif. Comparison lowercases both sides, so names outside ASCII compare case-sensitively.
---@param family string The requested family name.
---@return table<string, true> accepted The name and its aliases, lowercased, as a lookup.
getAcceptedNames = (family) ->
  cached = acceptedNamesByFamily[family]
  return cached if cached

  accepted = {[family\lower!]: true}
  probe = FcPatternCreate!
  if probe != nil
    ffi.gc probe, FcPatternDestroy
    FcPatternAddString probe, Property.Family, family
    FcPatternAddString probe, Property.Family, FAMILY_ALIASES_END
    FcConfigSubstitute nil, probe, MatchKind.Pattern

    nameOut = StringOut!
    index = 0
    while Result.Match == FcPatternGetString probe, Property.Family, index, nameOut
      name = ffi.string nameOut[0]
      break if name == FAMILY_ALIASES_END
      accepted[name\lower!] = true
      index += 1

  acceptedNamesByFamily[family] = accepted
  return accepted

---Checks whether the selected face matches the requested name.
---
---fontconfig returns a file for every request, falling back to a default face when nothing matches,
---so the names the face itself declares are the only way to tell a match from a fallback.
---@param matched ffi.cdata* The pattern FcFontMatch returned.
---@param accepted table<string, true> The requested name and its aliases.
---@return boolean isRequested False when the face declares none of them as a family or full name.
isRequestedFace = (matched, accepted) ->
  nameOut = StringOut!
  for property in *{Property.Family, Property.FullName}
    index = 0
    while Result.Match == FcPatternGetString matched, property, index, nameOut
      return true if accepted[ffi.string(nameOut[0])\lower!]
      index += 1
  return false

---Resolves a font request to a face, substituting as fontconfig sees fit.
---
---Takes either a style, whose family, bold and italic fields make the request, or those three
---directly for a caller measuring outside a style.
---@param family string Family name to match; an empty one leaves fontconfig its own default.
---@param weight? FontconfigWeight Weight to match, Regular by default.
---@param slant? FontconfigSlant Slant to match, Roman by default.
---@return MatchedFace? face The selected face. Nil when fontconfig could not name a file to open.
---@return string? err Why nothing usable came back.
---@overload fun(style: AegisubStyle): MatchedFace?, string?
matchFont = (family, weight = Weight.Regular, slant = Slant.Roman) ->
  if "table" == type family
    style = family
    family = style.fontname
    weight = style.bold and Weight.Bold or Weight.Regular
    slant = style.italic and Slant.Italic or Slant.Roman
  family or= ""

  requestKey = "#{family}\0#{weight}\0#{slant}"
  cached = matchedFaces[requestKey]
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

  -- an empty request has no name to match, so fontconfig's default is the correct result
  substituted = family != "" and not isRequestedFace matched, getAcceptedNames family

  face = {path: ffi.string(fileOut[0]), :index, :family, :weight, :slant, :substituted}
  matchedFaces[requestKey] = face
  return face

-- candidate lists by request, each anchoring the FcFontSet its character sets live in
sortedCandidatesByRequest = {}

---Returns every installed face in fontconfig's preference order for one request.
---
---Pango substitutes for a character its chosen face lacks by walking this order to the first face
---whose charset has the character, so a fallback walking the same order picks the same face.
---@param family string The requested family name.
---@param weight FontconfigWeight The requested weight.
---@param slant FontconfigSlant The requested slant.
---@return {path: string, index: integer, charSet: ffi.cdata*}[] candidates Best first; empty where fontconfig could not sort.
getSortedCandidates = (family, weight, slant) ->
  requestKey = "#{family}\0#{weight}\0#{slant}"
  cached = sortedCandidatesByRequest[requestKey]
  return cached if cached

  candidates = {}
  request = FcPatternCreate!
  if request != nil
    ffi.gc request, FcPatternDestroy
    FcPatternAddString request, Property.Family, family
    FcPatternAddInteger request, Property.Weight, weight
    FcPatternAddInteger request, Property.Slant, slant
    FcConfigSubstitute nil, request, MatchKind.Pattern
    FcDefaultSubstitute request

    -- trimming drops only faces whose whole coverage earlier faces already have, which never
    -- removes the first face covering any character, so the walk shortens and the picks stay
    sorted = FcFontSort nil, request, 1, nil, IntegerOut!
    if sorted != nil
      ffi.gc sorted, FcFontSetDestroy
      -- the patterns and their character sets live inside the set, so the list keeps it referenced
      candidates.fontSet = sorted
      fileOut, indexOut, charSetOut = StringOut!, IntegerOut!, CharSetOut!
      for position = 0, sorted.nfont - 1
        pattern = sorted.fonts[position]
        continue unless Result.Match == FcPatternGetCharSet pattern, Property.CharSet, 0, charSetOut
        continue unless Result.Match == FcPatternGetString pattern, Property.File, 0, fileOut
        index = 0
        index = tonumber indexOut[0] if Result.Match == FcPatternGetInteger pattern, Property.Index, 0, indexOut
        candidates[#candidates + 1] = {path: ffi.string(fileOut[0]), :index, charSet: charSetOut[0]}

  sortedCandidatesByRequest[requestKey] = candidates
  return candidates

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
---@field toCharIndex fun(codePoint: integer): integer? Takes a code point to the index its charmap is keyed by, nil where that charmap states none.

---Opens a matched face and reads the design metrics off it, once per face and family.
---
---A face missing either table still resolves, leaving fallback behavior to each contract's derivation.
---@param matched MatchedFace The face to open, as `matchFont` selected it.
---@return FreeTypeFace? resolved Nil when the file could not be opened, or holds only bitmaps and so cannot be set at an arbitrary size.
---@return string? err Why the font could not be measured with.
resolveFace = (matched) ->
  {:path, :index, :family} = matched
  -- keyed by the family as well as the file, so a message still names what its own caller asked for
  requestKey = "#{family}\0#{path}\0#{index}"

  cached = resolvedFaceMetrics[requestKey]
  return cached if cached

  faceOut = FaceOut!
  code = FT_New_Face library, path, index, faceOut
  unless code == 0
    return nil, msgs.resolveFace.openFailed\format path, family, ffiFreeType.describeError code
  face = ffi.gc faceOut[0], FT_Done_Face

  faceFlags = tonumber face.face_flags
  return nil, msgs.resolveFace.notScalable\format family unless 0 != bit.band faceFlags, FaceFlag.Scalable

  -- FT_New_Face selects a Unicode charmap and leaves the face with none where the font states no
  -- Unicode subtable, which puts every lookup at glyph zero. Symbol comes before Mac Roman because
  -- GDI reads it where a face states both, and the two disagree: Marlett maps every byte it states to
  -- a different glyph through each.
  toCharIndex = asCodePoint
  if face.charmap == nil
    for encoding in *{Encoding.MsSymbol, Encoding.AppleRoman}
      if 0 == FT_Select_Charmap face, encoding
        toCharIndex = charmapIndexers[encoding]
        break

  os2 = ffi.cast Os2Pointer, FT_Get_Sfnt_Table face, SfntTag.Os2
  hhea = ffi.cast HoriHeaderPointer, FT_Get_Sfnt_Table face, SfntTag.Hhea
  hasOs2 = os2 != nil and os2.version != ffiFreeType.NO_OS2_TABLE_VERSION
  parsedOs2 = hasOs2 and toParsedOs2Table(os2) or nil
  parsedHhea = hhea != nil and toParsedHheaTable(hhea) or nil

  resolved = {
    :face
    :family
    os2: parsedOs2
    hhea: parsedHhea
    -- in design units, as FreeType reports it; zero where the font leaves the box unset
    outlineBounds: {yMax: tonumber(face.bbox.yMax), yMin: tonumber face.bbox.yMin}
    unitsPerEm: tonumber face.units_per_EM
    :toCharIndex
    hasKerning: 0 != bit.band faceFlags, FaceFlag.Kerning
    hasCffOutlines: ffiFreeType.isCffOutlined face
  }
  resolvedFaceMetrics[requestKey] = resolved
  return resolved

---The two `TextExtentsOptions` relevant to the freetype metric preparation, validated and with defaults filled in.
---@class FreeTypeContractOptions
---@field dpi number Resolution to measure at, which only the Linux contract's spacing term reads.
---@field verticalMetricFallback TextExtentsVerticalMetricFallbackBehavior What to measure a face with when its OS/2 Windows cell is unusable.
---@field fontFallback boolean Whether the Linux contract substitutes another face for a character the resolved face has no glyph for.

---A face readied for one measurement, with the vertical metrics and the per-glyph lookups a run needs.
---@class PreparedMetrics
---@field height number Line height a run of at least one character comes out at, in whatever units the advances come back in.
---@field descent number Depth below the baseline, in those same units.
---@field extlead number Leading beyond the line, in those same units.
---@field normalize fun(width: number, height: number, descent: number, extlead: number): number, number, number, number Takes a measured run onto the requested cell height.
---@field fallbackAdvanceOf? fun(codePoint: integer): number? Advance of a character through a substitute face, nil where no installed face covers it; absent for a contract measuring `.notdef` instead.
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
---and the external leading is exact. Every remaining width miss is one device unit on a single glyph,
---which GDI grid-fits and this derivation scales linearly. A face setting fsSelection
---USE_TYPO_METRICS changes nothing here: GDI ignores the bit, and this derivation reads the same
---usWin and hhea values GDI reads.
---
---Where the face lacks a glyph for a character the mean width error is 31.5% over 413 cases. GDI
---substitutes another face for that character and reports its advance, while this backend resolves
---one face per style and measures .notdef. That figure depends on what is installed and says nothing
---about the derivation.
---
---Kerning reads only the legacy `kern` table, so a face kerning through GPOS alone measures without
---any. The style's `encoding` is ignored, which is where the descent and the leading still differ. A
---control character measures as `.notdef`, where GDI drops some of them by a rule that varies with the
---face, but it is not allowed as an input by `text_extents`, anyway.
---
---A face with no usable Windows cell is one GDI will not measure, so there are no numbers left to
---agree with, and `verticalMetricFallback` chooses what to measure it by instead.
---@param resolved FreeTypeFace The face to measure with.
---@param fontSize integer Requested height, already multiplied by MEASUREMENT_SCALE.
---@param options FreeTypeContractOptions What the backend was configured with.
---@return PreparedMetrics? prepared Values already at the requested size, so nothing is normalized.
---@return string? err Why the contract could not be derived for the face.
prepareAegisubWindowsMetrics = (resolved, fontSize, options) ->
  {:face, :family, :os2, :hhea, :outlineBounds} = resolved
  fallback = options.verticalMetricFallback

  cell = gdiMetrics.deriveCell os2, hhea, outlineBounds, fallback
  unless cell
    fallbackName = VerticalMetricFallbackBehavior\describe fallback, (key) -> key
    return nil, msgs.prepareAegisubWindowsMetrics.noCell\format family, fallbackName

  derived = gdiMetrics.deriveTextMetrics resolved, cell, fontSize
  toDeviceUnits = derived.toDeviceUnits

  kerningMode = KerningMode.Unscaled -- read once to avoid metamethod overhead on hot path
  return {
    descent: derived.descent
    extlead: derived.extlead
    -- GDI reports the ascent and descent summed, which for a fitted cell is the requested height and
    -- for one realized as an em is whatever the span comes out at.
    height: derived.ascent + derived.descent
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
---The ascent and descent come off the face realized at the requested size rather than off its tables,
---so this contract needs neither the OS/2 nor the hhea values and has no fallback to choose.
---
---Measured against a running Aegisub 3.4.2 on Ubuntu over a 36-face test corpus at four sizes, the
---mean width error is 0.556% on the 1757 cases where the face has glyphs for the whole text. Height
---and external leading are exact on every case.
---Where the face lacks a glyph for a character, the measurement takes it through the first covering
---face in fontconfig's preference order, which is the order Pango substitutes by: measured against
---the Pango backend over a 40-face corpus, the Japanese missing-glyph cases land at 0.03% mean width
---error. The normalization divides a line a substitute set by the spans of the faces that set it and
---reports the deepest descent among them, and kerning never crosses a face boundary. Setting
---`fontFallback: false` measures `.notdef` instead. Emoji stay off by 40.3% mean: Pango sets them in
---a bitmap-only face, which this backend does not resolve.
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
---@param options FreeTypeContractOptions What the backend was configured with, read for the resolution and the fallback.
---@param matched MatchedFace The request the face answered, whose traits order the fallback's candidates.
---@return PreparedMetrics? prepared Values at the realized size, which `normalize` takes to the requested one.
---@return string? err Why the face could not be realized at that size.
prepareAegisubLinuxMetrics = (resolved, fontSize, options, matched) ->
  {:face, :family} = resolved

  code = FT_Set_Pixel_Sizes face, 0, fontSize
  unless code == 0
    return nil, msgs.measure.noSize\format family, fontSize, ffiFreeType.describeError code

  metrics = face.size.metrics
  ascent = tonumber(metrics.ascender) / UNITS_PER_PIXEL_26_6
  descent = -tonumber(metrics.descender) / UNITS_PER_PIXEL_26_6
  kerningMode = KerningMode.Default

  -- Pango substitutes for a character its chosen face lacks through the first covering face in
  -- fontconfig's preference order, so the fallback walks the same order. Which faces set the line
  -- is tracked for the normalization below.
  substitutesUsed, primaryUsed = nil, false
  fallbackAdvanceOf = nil
  if options.fontFallback
    candidates = getSortedCandidates matched.family, matched.weight, matched.slant
    realized = {}
    substitutesUsed = {}
    fallbackAdvanceOf = (codePoint) ->
      for candidate in *candidates
        continue if 0 == FcCharSetHasChar candidate.charSet, codePoint
        substitute = resolveFace {path: candidate.path, index: candidate.index, family: matched.family}
        continue unless substitute
        unless realized[substitute]
          continue unless 0 == FT_Set_Pixel_Sizes substitute.face, 0, fontSize
          realized[substitute] = true
        charIndex = substitute.toCharIndex codePoint
        continue unless charIndex
        glyphIndex = FT_Get_Char_Index substitute.face, charIndex
        continue if glyphIndex == MISSING_GLYPH_INDEX
        continue unless 0 == FT_Get_Advance substitute.face, glyphIndex, LoadFlag.Default, advanceOut
        substitutesUsed[substitute.face] = true
        return tonumber(advanceOut[0]) / UNITS_PER_PIXEL_16_16
      return nil

  -- Wx reports the run's width, height, descent and leading in pixels; Aegisub multiplies all four by
  -- `fontSize` over the reported pixel height, which brings the final height out at `fontSize`.
  --
  -- Since FreeType doesn't do layout, we use Pango's formula with FreeType's pixel values to arrive at
  -- a pixel height that yields the same factor, which then scales FreeType's pixel advances.
  -- The final height is not scaled here, since it has already been fixed to the nominal font size.
  --
  -- Pango reads a line's vertical metrics off the runs it laid out, so a line a substitute set
  -- divides by the spans of the faces that set it and reports the deepest descent among them.
  lineHeight = ascent + descent
  toRequestedSize = lineHeight > 0 and fontSize / lineHeight or 1
  normalize = (width, height, lineDescent, extlead) ->
    if substitutesUsed and next substitutesUsed
      substitutesUsed[face] = true if primaryUsed
      maxAscent, maxDescent = 0, 0
      for used in pairs substitutesUsed
        maxAscent = math.max maxAscent, tonumber(used.size.metrics.ascender) / UNITS_PER_PIXEL_26_6
        maxDescent = math.max maxDescent, -tonumber(used.size.metrics.descender) / UNITS_PER_PIXEL_26_6
      span = maxAscent + maxDescent
      factor = span > 0 and fontSize / span or 1
      return width * factor, height, maxDescent * factor, 0
    return width * toRequestedSize, height, lineDescent * toRequestedSize, extlead * toRequestedSize

  return {
    :descent
    :normalize
    :fallbackAdvanceOf
    height: fontSize

    -- wxGTK reports no external leading at all
    extlead: 0

    -- and reports the line height for an empty string, where GDI reports zero
    reportsHeightForEmptyRun: true

    -- the line-height divisor leaves the spacing scaled by the resolution
    spacingOf: (spacing) -> spacing * MEASUREMENT_SCALE * POINTS_PER_INCH / options.dpi

    advanceOf: (glyphIndex) ->
      primaryUsed = true
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
---@param options FreeTypeContractOptions What the backend was configured with, none of which this contract reads.
---@return PreparedMetrics? prepared Values already at the requested size, so nothing is normalized.
---@return string? err Why the contract could not be derived for the face.
prepareAegisubMacMetrics = (resolved, fontSize, options) ->
  {:face, :family, :unitsPerEm, :hhea} = resolved
  lineHeight = hhea and sfnt.getLineHeight(hhea) or 0
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
    height: fontSize
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

  verticalMetricFallback = options.verticalMetricFallback or VerticalMetricFallbackBehavior.Gdi
  valid, fallbackErr = VerticalMetricFallbackBehavior\validate verticalMetricFallback,
    "options.verticalMetricFallback"
  assert valid, fallbackErr

  fontFallback = options.fontFallback != false

  contractOptions = {:dpi, :verticalMetricFallback, :fontFallback}

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

    matched, matchErr = matchFont style
    error matchErr, 2 unless matched

    resolved, faceErr = resolveFace matched
    error faceErr, 2 unless resolved

    prepared, prepareErr = prepare resolved, fontSize, contractOptions, matched
    error prepareErr, 2 unless prepared

    spacing = prepared.spacingOf style.spacing or 0

    -- Aegisub's non-Windows code branch for spacing measures character by character, so an empty run
    -- never reads the face at all and *every* metric stays zero, descent and leading included.
    return 0, 0, 0, 0 if prepared.reportsHeightForEmptyRun and hasSpacing and #codePoints == 0

    -- kerning describes text set solid, so inter-character spacing rules it out however it was asked for
    kerns = applyKerning and not hasSpacing and resolved.hasKerning

    -- a character the encoding states no index for reaches .notdef, every index in a charmap already
    -- naming another character's glyph
    toCharIndex = resolved.toCharIndex

    -- a contract offering a fallback substitutes another face for a character the resolved face
    -- lacks; the substitute contributes its advance alone, kerning never crossing a face boundary
    fallbackAdvanceOf = prepared.fallbackAdvanceOf

    width, previousGlyph = 0, nil
    for codePoint in *codePoints
      charIndex = toCharIndex codePoint
      glyphIndex = charIndex and FT_Get_Char_Index(resolved.face, charIndex) or MISSING_GLYPH_INDEX
      if glyphIndex == MISSING_GLYPH_INDEX and fallbackAdvanceOf
        substituteAdvance = fallbackAdvanceOf codePoint
        if substituteAdvance
          width += substituteAdvance + spacing
          previousGlyph = nil
          continue
      width += prepared.kerningOf previousGlyph, glyphIndex if kerns and previousGlyph
      advance, advanceErr = prepared.advanceOf glyphIndex
      error advanceErr, 2 unless advance
      width += advance + spacing
      previousGlyph = glyphIndex

    -- An empty string produces a line height equal to the nominal font size under wxGTK/Pango,
    -- as opposed to 0 under GDI (except in the above-mentioned spacing case where it is 0 under both).
    measuresEmptyRun = prepared.reportsHeightForEmptyRun and not hasSpacing
    height = (#codePoints > 0 or measuresEmptyRun) and prepared.height or 0

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
---@field VerticalMetricFallbackBehavior Enum What to measure a face with when its Windows cell is unusable, as a TextExtentsVerticalMetricFallbackBehavior enum.
FreeTypeExtents = {
  ---@type boolean
  isAvailable: isAvailable
  ---@type AegisubTextExtentsBackend
  measure: createBackend!
  createBackend: createBackend
  MetricMode: MetricMode
  VerticalMetricFallbackBehavior: VerticalMetricFallbackBehavior
}

UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
return UnitTestSuite\withTestExports FreeTypeExtents,
  {:matchFont, :prepareAegisubWindowsMetrics, :resolveFace}
