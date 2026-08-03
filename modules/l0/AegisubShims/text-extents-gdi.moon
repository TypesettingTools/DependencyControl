-- Measures text through GDI, the way Aegisub does on Windows (src/auto4_base.cpp, CalculateTextExtents).
-- Installed as the `aegisub.text_extents` backend by l0.AegisubShims where gdi32 loads.
-- Matches the behavior of Aegisub exactly, quirks and all.

ffi = require "ffi"
ffiGdi = require "l0.AegisubShims.helpers.ffi-gdi"
ffiWindows = require "l0.DependencyControl.helpers.ffi-windows"

msgs = {
  measure: {
    noDeviceContext: "Could not create a device context to measure text with: %s"
    noFont: "Could not realize the font '%s' to measure text with: %s"
    noExtent: "GDI would not measure '%s': %s"
    noMetrics: "GDI would not report the metrics of the font '%s': %s"
  }
}

{:gdi32, :LogFontW, :Size, :TextMetricW, :MapMode, :FontWeight, :OutputPrecision, :ClipPrecision,
  :FontQuality, :FontPitch, :FontFamily, :CharSet} = ffiGdi

-- GDI reports extents in whole device units, so the font is realized at this multiple of the style's
-- size and every result divided back down. Being a power of two, it buys six binary digits of
-- resolution the integers would otherwise round away, and costs nothing in the division.
MEASUREMENT_SCALE = 64

-- Aegisub copies at most one unit less than LOGFONTW's face name holds, leaving the terminator, so a
-- longer name truncates identically here.
MAX_FACE_NAME_LENGTH = ffiGdi.FACE_NAME_CAPACITY - 1

---Fills a LOGFONTW from an Aegisub style table.
---@param style table An Aegisub style table.
---@param fontSize number The style's font size, already multiplied by MEASUREMENT_SCALE.
---@return ffi.cdata*? logFont A LOGFONTW struct for the style's face, nil where its name would not convert.
---@return string? err Why the face name could not be converted to UTF-16.
buildLogFont = (style, fontSize) ->
  wideName, err = ffiWindows.toWide style.fontname or ""
  return nil, err unless wideName

  logFont = LogFontW!
  logFont.lfHeight = fontSize
  logFont.lfWeight = style.bold and FontWeight.Bold or FontWeight.Normal
  logFont.lfItalic = style.italic and 1 or 0
  logFont.lfUnderline = style.underline and 1 or 0
  logFont.lfStrikeOut = style.strikeout and 1 or 0
  logFont.lfCharSet = style.encoding or CharSet.Default
  logFont.lfOutPrecision = OutputPrecision.TrueType
  logFont.lfClipPrecision = ClipPrecision.Default
  logFont.lfQuality = FontQuality.Antialiased
  logFont.lfPitchAndFamily = bit.bor FontPitch.Default, FontFamily.DontCare

  copiedUnits = math.min ffiWindows.getWideLength(wideName), MAX_FACE_NAME_LENGTH
  ffi.copy logFont.lfFaceName, wideName, copiedUnits * ffiWindows.WCHAR_SIZE
  return logFont

---Sums the width of a run one code unit at a time, adding the style's spacing after each.
---@param deviceContext ffi.cdata* The device context the font is selected into.
---@param wide ffi.cdata* The text as UTF-16.
---@param unitCount integer Code units to measure.
---@param spacing number Inter-character spacing, already multiplied by MEASUREMENT_SCALE.
---@return number? width Nil where GDI refused to measure a unit.
---@return number height Height of the *last* unit measured, which is what Aegisub reports here.
measureSpaced = (deviceContext, wide, unitCount, spacing) ->
  extent = Size!
  width, height = 0, 0

  -- one code unit at a time, not one character: Aegisub walks the UTF-16 buffer, so a surrogate pair
  -- is measured as two halves and kerning never applies
  for offset = 0, unitCount - 1
    return nil if 0 == gdi32.GetTextExtentPoint32W deviceContext, wide + offset, 1, extent
    width += extent.cx + spacing
    height = extent.cy

  return width, height

---Measures a run of text set in a style, as `aegisub.text_extents` reports it.
---@param style table An Aegisub style table.
---@param text string The text to measure.
---@return number width Advance the run takes, trailing spaces included, after the style's scale_x.
---@return number height Line height of the realized face, not the glyphs' bounds, after scale_y.
---@return number descent Depth below the baseline, read from the face, so the same for any text.
---@return number extlead Gap the face asks for between lines, also read from it rather than the text.
measure = (style, text) ->
  fontSize = (style.fontsize or 0) * MEASUREMENT_SCALE
  spacing = (style.spacing or 0) * MEASUREMENT_SCALE

  wideText, textErr = ffiWindows.toWide text
  error textErr, 2 unless wideText

  deviceContext = gdi32.CreateCompatibleDC nil
  error msgs.measure.noDeviceContext\format(ffiWindows.describeLastError!), 2 if deviceContext == nil

  local font, previousFont
  release = ->
    gdi32.SelectObject deviceContext, previousFont if previousFont
    gdi32.DeleteObject font if font
    -- an HDC needs DeleteDC; Aegisub hands it to DeleteObject, which refuses it and leaks the context
    gdi32.DeleteDC deviceContext

  -- GDI objects outlive a raise, so every failing path releases them before reporting
  fail = (message) ->
    release!
    error message, 3

  gdi32.SetMapMode deviceContext, MapMode.Text

  logFont, fontErr = buildLogFont style, fontSize
  fail fontErr unless logFont

  font = gdi32.CreateFontIndirectW logFont
  fail msgs.measure.noFont\format(style.fontname or "", ffiWindows.describeLastError!) if font == nil

  previousFont = gdi32.SelectObject deviceContext, font
  unitCount = ffiWindows.getWideLength wideText

  local width, height
  if spacing != 0
    width, height = measureSpaced deviceContext, wideText, unitCount, spacing
    fail msgs.measure.noExtent\format(text, ffiWindows.describeLastError!) unless width
  else
    extent = Size!
    measured = gdi32.GetTextExtentPoint32W deviceContext, wideText, unitCount, extent
    fail msgs.measure.noExtent\format(text, ffiWindows.describeLastError!) if measured == 0
    width, height = extent.cx, extent.cy

  metrics = TextMetricW!
  reported = gdi32.GetTextMetricsW deviceContext, metrics
  fail msgs.measure.noMetrics\format(style.fontname or "", ffiWindows.describeLastError!) if reported == 0
  descent, extlead = metrics.tmDescent, metrics.tmExternalLeading

  release!

  horizontalScale = (style.scale_x or 100) / 100
  verticalScale = (style.scale_y or 100) / 100

  scaledWidth = horizontalScale * width / MEASUREMENT_SCALE
  scaledHeight = verticalScale * height / MEASUREMENT_SCALE
  scaledDescent = verticalScale * descent / MEASUREMENT_SCALE
  scaledExtlead = verticalScale * extlead / MEASUREMENT_SCALE

  return scaledWidth, scaledHeight, scaledDescent, scaledExtlead

---Aegisub-compatible text measurement through GDI, for installing as the text-extents backend.
---@class AegisubTextExtentsGdi
---@field isAvailable boolean Whether gdi32 loaded, so whether `measure` can be called.
---@field measure AegisubTextExtentsBackend Measures a run of text; raises when GDI refuses the request.
return {
  ---@type boolean
  isAvailable: ffiGdi.isAvailable

  ---@type AegisubTextExtentsBackend
  measure: measure
}
