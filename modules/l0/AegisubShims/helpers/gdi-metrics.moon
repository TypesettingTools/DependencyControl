sfnt = require "l0.AegisubShims.helpers.sfnt"

---Multiplies then divides in one rounded step.
---Matches FT_MulDiv over the whole range a face and a font size can reach.
---@param value number The value to scale, non-negative.
---@param numerator number The scale's numerator, non-negative.
---@param denominator number The scale's denominator, positive.
---@return integer scaled The scaled value, rounded to the nearest integer.
mulDivRound = (value, numerator, denominator) ->
  return math.floor value * numerator / denominator + 0.5

---Derives the height of the cell a face is laid out in, as TEXTMETRIC's tmHeight.
---@param os2 ParsedOs2Table The table stating the face's Windows ascent and descent.
---@return integer height The cell height, in design units; zero or less for a face declaring none usable.
getCellHeight = (os2) -> os2.winAscent + os2.winDescent

---Derives the leading beyond a face's cell, as TEXTMETRIC's tmExternalLeading.
---@param hhea ParsedHheaTable The header stating the line gap and the typographic span.
---@param cellHeight integer Height of the OS/2 Windows cell, in design units.
---@param hasCffOutlines boolean Whether the face describes its glyphs as PostScript outlines.
---@return integer leading The leading, in design units; never negative, and zero for PostScript outlines.
getExternalLeading = (hhea, cellHeight, hasCffOutlines) ->
  -- GDI reads no line gap at all off a face with PostScript outlines, reporting zero external
  -- leading however much gap the hhea table asks for. That much is measured, not written down.
  -- Left in, a CJK face declaring a full em of gap would measure a whole extra line of leading
  -- GDI never reports.
  return 0 if hasCffOutlines

  -- Only the part of the line height the Windows cell does not already cover is still leading.
  -- Arial's cell matches its typographic span so its whole gap survives, while Calibri's is taller
  -- by exactly its line gap and none of it does.
  return math.max 0, sfnt.getLineHeight(hhea) - cellHeight

---The vertical metrics GDI reports for a face realized into a requested cell height, with the scaling
---the advances of that same realization take.
---@class GdiTextMetrics
---@field ppem integer The em the face is realized at, in device units.
---@field descent integer Depth below the baseline, in device units.
---@field extlead integer Leading beyond the cell, in device units.
---@field toDeviceUnits fun(designUnits: number): integer Takes one design value onto the realized em.

---Derives the metrics for a face realized into a requested cell height, as GDI derives TEXTMETRIC.
---
---The descent scales by the requested height directly, never reaching the rasterizer, while the
---leading and the advances scale by the realized integer em GDI rasterizes at. The two look
---interchangeable and are not; one rule for all three misses by a device unit on some sizes.
---@param resolved ResolvedFace The face's design values.
---@param fontSize integer Requested cell height, already multiplied by the measurement scale.
---@return GdiTextMetrics derived Values in device units, still carrying the measurement scale.
deriveTextMetrics = (resolved, fontSize) ->
  {:os2, :hhea, :unitsPerEm, :cellHeight, :hasCffOutlines} = resolved
  ppem = mulDivRound fontSize, unitsPerEm, cellHeight
  toDeviceUnits = (designUnits) -> mulDivRound designUnits, ppem, unitsPerEm

  return {
    :ppem
    :toDeviceUnits
    descent: mulDivRound os2.winDescent, fontSize, cellHeight
    extlead: toDeviceUnits getExternalLeading hhea, cellHeight, hasCffOutlines
  }

---Derives the TEXTMETRIC values GDI reports for a face from the face's own OS/2 and hhea tables, so a
---backend can reproduce the AegisubWindows contract on a platform with no GDI to ask.
---@class AegisubShimsGdiMetrics
GdiMetrics = {
  :getCellHeight
  :getExternalLeading
  :deriveTextMetrics
}

UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
return UnitTestSuite\withTestExports GdiMetrics, {:mulDivRound}
