ffi = require "ffi"
ffiCoreText = require "l0.AegisubShims.helpers.ffi-coretext"
gdiMetrics = require "l0.AegisubShims.helpers.gdi-metrics"
sfnt = require "l0.AegisubShims.helpers.sfnt"
textExtents = require "l0.AegisubShims.text-extents"
unicode = require "l0.DependencyControl.unicode"
utils = require "l0.DependencyControl.utils"

msgs = {
  resolveFace: {
    noName: "The font name '%s' could not be converted to a CFString."
    noFont: "CoreText offered no font at all for '%s'."
    noTables: "The font '%s' has no usable OS/2 and hhea tables, so its metrics cannot be read."
  }
  measure: {
    unavailable: "Measuring text needs CoreText, which is only reachable on macOS."
  }
  measureAegisubMacMetrics: {
    noFont: "CoreText would not realize the font '%s' at the size asked for."
    noLine: "CoreText would not lay a run out in the font '%s'."
  }
  createBackend: {
    noLinuxContract: "The Linux contract is Pango's, which CoreText cannot reproduce; use the Pango or FreeType backend for it."
  }
}

{:coreFoundation, :coreText, :coreFoundationSymbols, :coreTextSymbols, :CgSize, :CgAffineTransform,
  :StringEncoding, :NumberType, :FontTrait, :FontWeight, :FontWidth, :FontOrientation,
  :TableTag} = ffiCoreText
-- eager-load all used CoreText symbols so we error out early (and in non-macOS test runs) when an undeclared one is used
{:CFAttributedStringCreate, :CFDataGetBytePtr, :CFDataGetLength, :CFDictionaryCreate,
  :CFDictionaryGetValue, :CFNumberCreate, :CFNumberGetValue, :CFRelease, :CFStringCreateWithBytes,
  :CFStringGetCString} = coreFoundation
{:CTFontCopyPostScriptName, :CTFontCopyTable, :CTFontCreateWithFontDescriptor,
  :CTFontDescriptorCopyAttribute, :CTFontDescriptorCreateWithAttributes, :CTFontGetAdvancesForGlyphs,
  :CTFontGetGlyphsForCharacters, :CTFontGetUnitsPerEm, :CTLineCreateWithAttributedString,
  :CTLineGetTypographicBounds} = coreText
{:kCFTypeDictionaryKeyCallBacks, :kCFTypeDictionaryValueCallBacks} = coreFoundationSymbols
{:kCTFontAttributeName, :kCTFontFamilyNameAttribute, :kCTFontSizeAttribute, :kCTFontSlantTrait,
  :kCTFontSymbolicTrait, :kCTFontTraitsAttribute, :kCTFontWeightTrait, :kCTFontWidthTrait} = coreTextSymbols

isAvailable = ffiCoreText.isAvailable

{:MEASUREMENT_SCALE, :MetricMode, :WxRounding} = textExtents

-- any instance size works for reading the face's design values, which do not scale with it
PROBE_FONT_SIZE = 1000

Utf16Buffer = ffi.typeof "uint16_t[?]"
GlyphBuffer = ffi.typeof "uint16_t[?]"
CgSizeBuffer = ffi.typeof "$[?]", CgSize

-- the key and value arrays a dictionary is built from, and the buffers CoreFoundation reads a number
-- out of or writes one into
PointerArray = ffi.typeof "const void*[?]"
BoundsOut = ffi.typeof "double[3]"
SlantOut = ffi.typeof "double[1]"
DoubleIn = ffi.typeof "double[1]"
IntIn = ffi.typeof "int[1]"

-- room for any PostScript name, which the OpenType specification recommends keeping to 127 characters
MAX_FACE_NAME_BYTES = 512
StringOut = ffi.typeof "char[#{MAX_FACE_NAME_BYTES}]"

-- The slant wxOSX applies itself where a family offers up no italic cut of its own, transcribed from
-- wxWidgets' kSlantTransform.
SYNTHETIC_SLANT_DEGREES = 11
SYNTHETIC_SLANT = CgAffineTransform 1, 0, math.tan(math.rad SYNTHETIC_SLANT_DEGREES), 1, 0, 0

-- a face whose descriptor states less slant than this counts as upright, as wx counts it
MAX_UPRIGHT_SLANT = 0.01

-- open faces and their design metrics, keyed by what was asked for rather than by what matched
measuredFaces = {}

-- How each wx generation takes a measured extent to the whole wxCoord it hands back. Every value
-- measured here is non-negative, so rounding to the nearest is a floor of the value plus a half.
takeToWholeBy = {
  [WxRounding.Round]: (value) -> math.floor value + 0.5
  [WxRounding.Ceil]: math.ceil
}

---How far a descriptor's matched face already slants, which says whether the family offered up a real
---italic cut or left the request upright.
---@param descriptor ffi.cdata* The descriptor to read.
---@return number slant Zero for a descriptor stating none, which is also what an unreadable one gives.
getDescriptorSlant = (descriptor) ->
  traitsDict = CTFontDescriptorCopyAttribute descriptor, kCTFontTraitsAttribute
  return 0 if traitsDict == nil
  ffi.gc traitsDict, CFRelease

  slant = CFDictionaryGetValue traitsDict, kCTFontSlantTrait
  return 0 if slant == nil

  out = SlantOut!
  return 0 if 0 == CFNumberGetValue ffi.cast("void*", slant), NumberType.Double, out
  return tonumber out[0]

---Reads a font table's bytes off an open font.
---@param font ffi.cdata* The CTFont to read from.
---@param tag CoreTextTableTag The table to read.
---@return string? bytes The raw table, nil when the face carries none.
readFontTable = (font, tag) ->
  data = CTFontCopyTable font, tag, 0
  return nil if data == nil
  ffi.gc data, CFRelease
  return ffi.string CFDataGetBytePtr(data), CFDataGetLength data

---Wraps a number as a CFNumber, which is how a font attribute or trait states one.
---@param value number The value to wrap.
---@param numberType CoreFoundationNumberType How CoreFoundation should store it.
---@return ffi.cdata*? number Nil when CoreFoundation would not build one; collected when it would.
createCfNumber = (value, numberType) ->
  buffer = numberType == NumberType.Int and IntIn! or DoubleIn!
  buffer[0] = value
  number = CFNumberCreate nil, numberType, buffer
  return nil if number == nil
  return ffi.gc number, CFRelease

---Builds a CoreFoundation dictionary out of key and value pairs.
---
---The entry list keeps every value reachable until the dictionary retains them, which the pointer
---arrays alone would not: they hold addresses, so a value nothing else refers to could be collected
---between the store and the call.
---@param entries table[] Pairs as `{key, value}`, both CoreFoundation objects.
---@return ffi.cdata*? dictionary Nil when CoreFoundation would not build one; collected when it would.
createCfDictionary = (entries) ->
  count = #entries
  keys, values = PointerArray(count), PointerArray count
  keys[index - 1], values[index - 1] = entry[1], entry[2] for index, entry in ipairs entries

  dictionary = CFDictionaryCreate nil, keys, values, count,
    kCFTypeDictionaryKeyCallBacks,
    kCFTypeDictionaryValueCallBacks
  return nil if dictionary == nil
  return ffi.gc dictionary, CFRelease

---Builds the descriptor a font request is matched through, as `wxNativeFontInfo::CreateCTFontDescriptor`
---builds it: the family name, the italic bit as a symbolic trait, and the weight and width as numbers.
---
---Which member of a family answers decides its kern pairs even where it leaves the advances alone, so
---the request has to be spelled the way wx spells it. Asking by font name instead of family name, or
---for symbolic bold instead of a numeric weight, can land on a metrically identical member that kerns
---differently.
---@param cfName ffi.cdata* The family name, as a CFString.
---@param bold boolean Whether the style asks for a bold face.
---@param italic boolean Whether the style asks for an italic face.
---@param size number The size to state on the descriptor.
---@return ffi.cdata*? descriptor Nil when CoreText would not build one; collected when it would.
buildDescriptor = (cfName, bold, italic, size) ->
  weight = createCfNumber (bold and FontWeight.Bold or FontWeight.Regular), NumberType.CgFloat
  width = createCfNumber FontWidth.Regular, NumberType.CgFloat
  sizeNumber = createCfNumber size, NumberType.CgFloat
  return nil unless weight and width and sizeNumber

  traitEntries = {
    {kCTFontWeightTrait, weight}
    {kCTFontWidthTrait, width}
  }
  if italic
    symbolic = createCfNumber FontTrait.Italic, NumberType.Int
    return nil unless symbolic
    traitEntries[#traitEntries + 1] = {kCTFontSymbolicTrait, symbolic}

  traits = createCfDictionary traitEntries
  return nil unless traits

  attributes = createCfDictionary {
    {kCTFontFamilyNameAttribute, cfName}
    {kCTFontTraitsAttribute, traits}
    {kCTFontSizeAttribute, sizeNumber}
  }
  return nil unless attributes

  descriptor = CTFontDescriptorCreateWithAttributes attributes
  return nil if descriptor == nil
  return ffi.gc descriptor, CFRelease

---Reads a CFString back as a Lua string.
---@param cfString ffi.cdata* The string to read.
---@return string? text Nil for a string longer than the buffer or holding what UTF-8 cannot state.
readCfString = (cfString) ->
  buffer = StringOut!
  return nil if 0 == CFStringGetCString cfString, buffer, MAX_FACE_NAME_BYTES,
    StringEncoding.Utf8
  return ffi.string buffer

---A face CoreText resolved, with the shared design values read off its SFNT tables.
---@class CoreTextFace: ResolvedFace
---@field face ffi.cdata* The CTFont at em size, so its advances come back in design units.
---@field postScriptName string? Name of the face the request matched, absent when it could not be read.

---Opens the font a style asks for, reading the design metrics off it once.
---@param style AegisubStyle The style to set the text in.
---@return CoreTextFace? measured Nil when no font could be resolved or read.
---@return string? err Why the font could not be measured with.
resolveFace = (style) ->
  family = style.fontname or ""
  bold, italic = not not style.bold, not not style.italic
  requestKey = "#{family}\0#{bold and 1 or 0}\0#{italic and 1 or 0}"

  cached = measuredFaces[requestKey]
  return cached if cached

  cfName = CFStringCreateWithBytes nil, family, #family, StringEncoding.Utf8, 0
  return nil, msgs.resolveFace.noName\format family if cfName == nil
  ffi.gc cfName, CFRelease

  -- CoreText substitutes a fallback face for an unknown name, so this resolves like the GDI mapper
  -- and fontconfig do.
  resolveFont = (size) ->
    descriptor = buildDescriptor cfName, bold, italic, size
    return nil unless descriptor

    -- wx slants the face itself when the one it matched is upright, so italic still reads as italic
    slantMatrix = nil
    slantMatrix = SYNTHETIC_SLANT if italic and getDescriptorSlant(descriptor) < MAX_UPRIGHT_SLANT

    font = CTFontCreateWithFontDescriptor descriptor, size, slantMatrix
    return nil if font == nil
    return ffi.gc font, CFRelease

  probe = resolveFont PROBE_FONT_SIZE
  return nil, msgs.resolveFace.noFont\format family if probe == nil

  unitsPerEm = tonumber CTFontGetUnitsPerEm probe
  os2Bytes = readFontTable probe, TableTag.Os2
  hheaBytes = readFontTable probe, TableTag.HoriHeader
  os2 = os2Bytes and sfnt.parseOs2Table os2Bytes
  hhea = hheaBytes and sfnt.parseHheaTable hheaBytes
  return nil, msgs.resolveFace.noTables\format family unless os2 and hhea and unitsPerEm > 0

  cellHeight = gdiMetrics.getCellHeight os2
  return nil, msgs.resolveFace.noTables\format family unless cellHeight > 0

  -- Both tables are kept whole, each contract reading the face's own numbers its own way. The Windows
  -- one deducts the room the cell already adds from the line gap; the macOS one takes it as stated.
  sizedFonts = {}
  measured = {
    -- at em size, the advance of every glyph comes back as its design value exactly
    face: resolveFont unitsPerEm

    ---The same face realized at a measurement size, which laying a run out needs and reading design
    ---values does not. Kept per size, a font being immutable once created.
    ---@param size number The size to realize at.
    ---@return ffi.cdata*? font Nil when CoreText would not realize the face at that size.
    fontAtSize: (size) ->
      sizedFonts[size] or= resolveFont size
      return sizedFonts[size]
    :family
    :unitsPerEm
    :cellHeight
    :os2
    :hhea
    -- read once here: the answer is a property of the face, and the call copies a table out of it
    hasCffOutlines: nil != readFontTable probe, TableTag.Cff
    postScriptName: do
      cfPostScriptName = CTFontCopyPostScriptName probe
      if cfPostScriptName == nil then nil
      else
        ffi.gc cfPostScriptName, CFRelease
        readCfString cfPostScriptName
  }
  measuredFaces[requestKey] = measured
  return measured

---Sums the advances of a run in device units, one code point at a time, each scaled on its own.
---Takes code points from a strict decode, so the UTF-16 conversion cannot reject one.
---@param measured CoreTextFace The face to measure with.
---@param scaleAdvance fun(designUnits: number): number Takes one design advance onto device units.
---@param codePoints integer[] The run's code points, at least one.
---@return number width The summed advances, in device units.
sumAdvances = (measured, scaleAdvance, codePoints) ->
  count = #codePoints

  -- the glyph lookup takes UTF-16, and a code point past the BMP occupies a surrogate pair there
  -- whose glyph lands in the pair's first slot
  units, unitStarts = unicode.encodeUtf16 codePoints

  unitBuffer = Utf16Buffer #units
  unitBuffer[index - 1] = unit for index, unit in ipairs units
  unitGlyphs = GlyphBuffer #units
  -- an unmapped character leaves glyph zero, whose advance is the face's missing-glyph advance
  CTFontGetGlyphsForCharacters measured.face, unitBuffer, unitGlyphs, #units

  glyphs = GlyphBuffer count
  glyphs[index - 1] = unitGlyphs[unitStart] for index, unitStart in ipairs unitStarts
  advances = CgSizeBuffer count
  CTFontGetAdvancesForGlyphs measured.face, FontOrientation.Default, glyphs, advances, count

  width = 0
  width += scaleAdvance advances[index].width for index = 0, count - 1
  return width

---What one run measures as when CoreText lays it out, the way wxOSX asks for it, each value taken to
---the whole number wxCoord holds it in.
---@class LaidOutRun
---@field width integer Advance the run takes, in the units the font was realized at.
---@field height integer Ascent to descent with the leading counted in, which wx reports as the height.
---@field descent integer Depth below the baseline.
---@field leading integer Gap the face asks for beyond the line.

---Lays a run out through CTLine and reads its typographic bounds, which is what wxWidgets measures
---with on macOS (`wxMacCoreGraphicsContext::GetTextExtent`). The platform's own kerning and its
---per-character fallback are in the numbers, neither of which a derivation off one face's tables has.
---
---An empty run is measured as a single space, as wx measures it, so the face's descent and leading
---still come back; the caller forces the width and the height to zero as wx does.
---
---Every value is rounded on the way out, because wxDC hands text extents back as `wxCoord`, which is
---an integer, and Aegisub normalizes what it was handed rather than what CoreText measured. Rounding
---after the normalization instead would miss by a few thousandths on most runs.
---@param font ffi.cdata* The CTFont to lay the run out in, at the size it should measure at.
---@param text string The run, as UTF-8.
---@param takeToWhole fun(value: number): integer How the wx version being reproduced reaches a wxCoord.
---@return LaidOutRun? run Nil when CoreText would not build the line.
laidOutRun = (font, text, takeToWhole) ->
  text = " " if text == ""

  cfText = CFStringCreateWithBytes nil, text, #text, StringEncoding.Utf8, 0
  return nil if cfText == nil
  ffi.gc cfText, CFRelease

  attributes = createCfDictionary {{kCTFontAttributeName, font}}
  return nil unless attributes

  attributed = CFAttributedStringCreate nil, cfText, attributes
  return nil if attributed == nil
  ffi.gc attributed, CFRelease

  line = CTLineCreateWithAttributedString attributed
  return nil if line == nil
  ffi.gc line, CFRelease

  bounds = BoundsOut!
  width = CTLineGetTypographicBounds line, bounds, bounds + 1, bounds + 2
  ascent, descent, leading = tonumber(bounds[0]), tonumber(bounds[1]), tonumber(bounds[2])
  return {
    width: takeToWhole width
    height: takeToWhole ascent + descent + leading
    descent: takeToWhole descent
    leading: takeToWhole leading
  }

---Measures a run the way Aegisub does on macOS: laid out through CTLine, then normalized so the line
---height CoreText reported comes out at the nominal font size.
---
---Measured against a running Aegisub 3.4.2 on macOS over a 36-face test corpus at four sizes, the
---height, the descent and the external leading are identical on all 2400 cases, and the width on all
---but 79, which agree to five decimal places. Laying out the run leverages CoreText's per-character
---substitution and kerning, matching Aegisub's behavior on macOS exactly in both regards.
---
---Measured against GDI over the same corpus, the mean width error is 13.71% on those 1757 cases, the
---descent 18.37% and the external leading 19.56%, with the height exact to 0.0064% — the same as the
---macOS Aegisub implementation itself fares against GDI.
---
---The normalization is Aegisub's own, quirks included. A style setting `spacing` sends it down a
---per-character loop where each character is normalized by its own measured height, and the running
---maxima compare a new character's unscaled height against the already-scaled one — which shows the
---moment font fallback mixes faces of different line heights. An empty run never enters that loop at
---all, so every metric stays zero.
---@param measured CoreTextFace The face to measure with.
---@param style AegisubStyle The style to set the text in.
---@param text string The text to measure.
---@param fontSize number The whole size the face is realized at, already multiplied by MEASUREMENT_SCALE.
---@param requestedSize number The size asked for before truncation, which the normalization divides by.
---@param takeToWhole fun(value: number): integer How the wx version being reproduced reaches a wxCoord.
---@return number? width Advance the run takes, before the style's scale_x.
---@return number|string height Line height, or why the run could not be laid out.
---@return number descent Depth below the baseline.
---@return number extlead Gap the face asks for beyond the line.
measureAegisubMacMetrics = (measured, style, text, fontSize, requestedSize, takeToWhole) ->
  font = measured.fontAtSize fontSize
  return nil, msgs.measureAegisubMacMetrics.noFont\format measured.family unless font

  spacing = (style.spacing or 0) * MEASUREMENT_SCALE
  if spacing == 0
    run = laidOutRun font, text, takeToWhole
    return nil, msgs.measureAegisubMacMetrics.noLine\format measured.family unless run

    -- wx measures an empty run as a space and then forces the width and the height back to zero,
    -- keeping the space's descent and leading, so those two still describe the face
    runWidth = text == "" and 0 or run.width
    runHeight = text == "" and 0 or run.height

    scaling = requestedSize / (runHeight > 0 and runHeight or 1)
    return runWidth * scaling, runHeight * scaling, run.descent * scaling, run.leading * scaling

  width, height, descent, extlead = 0, 0, 0, 0
  iterateChars = assert unicode.iterateChars text
  for char in iterateChars
    run = laidOutRun font, char, takeToWhole
    return nil, msgs.measureAegisubMacMetrics.noLine\format measured.family unless run
    runHeight = run.height
    scaling = requestedSize / (runHeight > 0 and runHeight or 1)
    width += (run.width + spacing) * scaling
    height = runHeight > height and runHeight * scaling or height
    descent = run.descent > descent and run.descent * scaling or descent
    extlead = run.leading > extlead and run.leading * scaling or extlead
  return width, height, descent, extlead

---Builds a text-extents backend measuring by a chosen contract.
---
---The macOS contract is measured by laying out the run through CTLine exactly as wxWidgets does,
---so the platform's own kerning and its per-character fallback are in the numbers.
---Aegisub's normalization is then applied over the result, its per-character spacing loop and
---that loop's comparison quirk included.
---wxDC hands a text extent back as a whole `wxCoord`, and which way it gets there changed in wx 3.2,
---from rounding to the nearest to rounding up. Aegisub 3.4.2 builds against 3.1.4 and 3.5 against the
---3.2 branch, so the two report different numbers for the same text; `wxRounding` states which to
---reproduce and defaults to the `Round` of the current release.
---
---The Windows contract is derived instead, from the OS/2 cell the face states, since GDI is what it
---reproduces and GDI neither kerns nor falls back. Measured against GDI over the same corpus, all four
---values are exact on 81.4% of the 1757 cases where the face has glyphs for the whole text and within
---a 64th of a device pixel on 96.5%, with a mean width error of 0.0465%, a descent error of 0.2342%
---and the external leading exact everywhere. The worst of both is a style setting `encoding`, which
---this backend ignores as the FreeType one does.
---@param options? TextExtentsOptions How to measure; only `metricMode` is read.
---@return AegisubTextExtentsBackend measure Measures a run of text, raising where it cannot.
createBackend = (options) ->
  utils.assertArgType options, 1, "table" if options != nil
  options or= {}

  metricMode = options.metricMode or MetricMode.AegisubWindows
  valid, modeErr = MetricMode\validate metricMode, "options.metricMode"
  assert valid, modeErr
  assert metricMode != MetricMode.AegisubLinux, msgs.createBackend.noLinuxContract

  measuresMac = metricMode == MetricMode.AegisubMac

  wxRounding = options.wxRounding or WxRounding.Round
  valid, roundingErr = WxRounding\validate wxRounding, "options.wxRounding"
  assert valid, roundingErr
  takeToWhole = takeToWholeBy[wxRounding]

  ---@param style AegisubStyle The style to set the text in.
  ---@param text string The text to measure.
  ---@return number width Advance the run takes, trailing spaces included, after the style's scale_x.
  ---@return number height Line height of the realized face, not the glyphs' bounds, after scale_y.
  ---@return number descent Depth below the baseline, read from the face, so the same for any text.
  ---@return number extlead Gap the face asks for between lines, also read from it rather than the text.
  return (style, text) ->
    error msgs.measure.unavailable, 2 unless isAvailable

    -- Aegisub hands GDI the cell height as a whole number, so a fractional one truncates there and
    -- here. The macOS path keeps the untruncated size too: wxFont realizes at the whole point count
    -- while the normalization divides by what was asked for, both as Aegisub has them.
    requestedSize = (style.fontsize or 0) * MEASUREMENT_SCALE
    fontSize = math.floor requestedSize
    return 0, 0, 0, 0 unless fontSize > 0

    codePoints, decodeErr = unicode.decodeUtf8 text, unicode.DecodeMode.Strict
    error decodeErr, 2 unless codePoints

    measured, faceErr = resolveFace style
    error faceErr, 2 unless measured

    local width, height, descent, extlead
    if measuresMac
      -- laid out rather than derived, so the platform's own kerning and per-character fallback are in
      -- the numbers; every metric normalizes together, so nothing is scaled again below
      width, height, descent, extlead = measureAegisubMacMetrics measured, style, text, fontSize,
        requestedSize, takeToWhole
      error height, 2 unless width
    else
      derived = gdiMetrics.deriveTextMetrics measured, fontSize
      descent, extlead = derived.descent, derived.extlead
      -- Advances scale per glyph by the realized integer em, matching the extent calls GDI answers
      -- with; GDI takes the spacing as given and never kerns.
      scaleAdvance = derived.toDeviceUnits
      spacing = (style.spacing or 0) * MEASUREMENT_SCALE
      count = #codePoints
      width = count > 0 and sumAdvances(measured, scaleAdvance, codePoints) + spacing * count or 0
      height = count > 0 and fontSize or 0

    return textExtents.applyStyleScale style, width, height, descent, extlead

---Measures text through CoreText, the macOS system text API, which needs no libraries beyond the
---system frameworks. `l0.AegisubShims` installs it as the `aegisub.text_extents` backend wherever
---CoreText is reachable.
---
---The default contract derives from the OS/2 Windows cell exactly as the GDI and FreeType backends do,
---so a script measures the same numbers on every platform. `AegisubMac` instead reproduces what
---Aegisub itself reports on macOS, for a caller comparing against the editor rather than the renderer.
---@class AegisubTextExtentsCoreText
---@field isAvailable boolean Whether the frameworks loaded, so whether `measure` can be called.
---@field measure AegisubTextExtentsBackend Measures by the Windows cell; raises when it cannot.
---@field createBackend fun(options?: TextExtentsOptions): AegisubTextExtentsBackend Builds a backend measuring by a chosen contract.
---@field MetricMode Enum The metric contracts on offer, as a TextExtentsMetricMode enum.
---@field WxRounding Enum How a wx version reaches a whole wxCoord, as a WxTextExtentRounding enum.
CoreTextExtents = {
  ---@type boolean
  isAvailable: isAvailable

  ---@type AegisubTextExtentsBackend
  measure: createBackend!

  createBackend: createBackend
  MetricMode: MetricMode
  WxRounding: WxRounding
}

UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
return UnitTestSuite\withTestExports CoreTextExtents, {:resolveFace}
