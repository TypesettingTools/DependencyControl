Enum = require "l0.DependencyControl.Enum"
sfnt = require "l0.AegisubShims.helpers.sfnt"
textExtents = require "l0.AegisubShims.text-extents"

{:FsSelection} = sfnt
{:VerticalMetricFallbackBehavior} = textExtents

-- GDI reads OS/2's winAscent and winDescent as signed 16-bit, where the specification declares both
-- unsigned, so above 0x7FFF it lays the face out by the negative those bits make in two's complement
-- rather than by the large value the specification reads there.
SIGNED_RANGE = 0x10000
SIGNED_LIMIT = 0x8000
asSigned = (value) -> value >= SIGNED_LIMIT and value - SIGNED_RANGE or value

---Multiplies then divides in one rounded step.
---Matches FT_MulDiv over the non-negative range a face and a font size can reach.
---@param value number The value to scale.
---@param numerator number The scale's numerator, non-negative.
---@param denominator number The scale's denominator, positive.
---@return integer scaled The scaled value, rounded to the nearest integer.
mulDivRound = (value, numerator, denominator) ->
  return math.floor value * numerator / denominator + 0.5

---Which of a face's tables the cell's vertical span was taken from.
---@alias GdiCellSource
---| 1 # WindowsCell: the OS/2 winAscent and winDescent, the only span GDI itself reads
---| 2 # HorizontalHeader: the hhea ascender and descender
---| 3 # TypoMetrics: the OS/2 typoAscender and typoDescender
---| 4 # OutlineBounds: the head table's glyph bounding box
CellSource = Enum "GdiCellSource", {
  WindowsCell: 1
  HorizontalHeader: 2
  TypoMetrics: 3
  OutlineBounds: 4
}

---The vertical bounds of a face's glyph bounding box, in the head table's own terms.
---@class GdiOutlineBounds
---@field yMax integer Highest point any glyph outline reaches, in design units.
---@field yMin integer Lowest point any glyph outline reaches, negative below the baseline.

---The vertical span a requested font size is scaled against, and where it came from.
---@class GdiCell
---@field ascent integer Distance above the baseline, in design units.
---@field descent integer Distance below the baseline, in design units; negative where the face's descender points the other way.
---@field height integer The two summed.
---@field source GdiCellSource Which of the face's tables this span was taken from.
---@field emSized boolean Whether the requested height is the realized em rather than the height this span comes out at.

---Derives the vertical span a face is laid out in.
---
---Every mode reads the OS/2 Windows cell first and takes it where winAscent and winDescent, read as
---signed, sum above zero. What follows for a face summing to zero or less, and for one with no OS/2
---table at all, depends on the mode:
---
--- * `Gdi` — a face with no OS/2 table is laid out in its glyph bounding box, the requested height
---   being the realized em rather than the cell. For a face that has the table and no cell, nothing:
---   GDI refuses the file outright or fails the metric call for it, so there is no measurement to
---   reproduce.
--- * `Libass` — the typographic span, fitted to the requested height: OS/2's typo values where
---   fsSelection sets USE_TYPO_METRICS, hhea's otherwise, then those typo values, then the bounding box.
--- * `Refuse` — nothing.
---@param os2? ParsedOs2Table The face's OS/2 table, nil where the face has none.
---@param hhea? ParsedHheaTable The face's horizontal header, nil where the face has none.
---@param outlineBounds? GdiOutlineBounds The face's glyph bounding box, where the backend's library reports one.
---@param fallback? TextExtentsVerticalMetricFallbackBehavior What to read where the Windows cell is unusable, `Gdi` by default.
---@return GdiCell? cell Nil where the chosen mode finds no usable span, which this contract cannot measure.
deriveCell = (os2, hhea, outlineBounds, fallback = VerticalMetricFallbackBehavior.Gdi) ->
  ---@return GdiCell? cell Nil where the two values make no positive span, so the next source is tried.
  usableCell = (source, ascent, descent, emSized = false) ->
    height = ascent + descent
    return nil unless height > 0
    return {:ascent, :descent, :height, :source, :emSized}

  if os2
    windowsCell = usableCell CellSource.WindowsCell, asSigned(os2.winAscent), asSigned os2.winDescent
    return windowsCell if windowsCell
    -- GDI reads the bounding box only off a face with no OS/2 table at all; where the table is there
    -- and its cell sums to zero or less, GDI produces no metrics to reproduce.
    return nil if fallback == VerticalMetricFallbackBehavior.Gdi

  if fallback == VerticalMetricFallbackBehavior.Gdi
    return nil unless outlineBounds
    return usableCell CellSource.OutlineBounds, outlineBounds.yMax, -outlineBounds.yMin, true

  if fallback == VerticalMetricFallbackBehavior.Libass
    -- USE_TYPO_METRICS decides only whether hhea is read: where the bit is set libass never reads it,
    -- going from the typo values straight to the bounding box
    unless os2 and FsSelection\has os2.fsSelection, FsSelection.UseTypoMetrics
      if hhea
        headerCell = usableCell CellSource.HorizontalHeader, hhea.ascender, -hhea.descender
        return headerCell if headerCell

    if os2
      typoCell = usableCell CellSource.TypoMetrics, os2.typoAscender, -os2.typoDescender
      return typoCell if typoCell

    return outlineBounds and usableCell(CellSource.OutlineBounds, outlineBounds.yMax, -outlineBounds.yMin) or nil

  return nil

---Derives the leading beyond a face's cell, as TEXTMETRIC's tmExternalLeading.
---@param hhea? ParsedHheaTable The face's horizontal header, holding the line gap and the typographic span; nil where the face has none.
---@param cell GdiCell The vertical span the face is laid out in.
---@param hasCffOutlines boolean Whether the face describes its glyphs as PostScript outlines.
---@return integer leading The leading, in design units; never negative, and zero for PostScript outlines or a face with no horizontal header.
getExternalLeading = (hhea, cell, hasCffOutlines) ->
  return 0 unless hhea

  -- GDI reads no line gap at all off a face with PostScript outlines, reporting zero external leading
  -- however much gap hhea declares. Established by reading back `GetTextMetricsW`.
  return 0 if hasCffOutlines

  -- A span realized as an em is not one the line height has to fit inside, so the whole line gap
  -- survives with nothing deducted from it.
  return math.max 0, hhea.lineGap if cell.emSized

  -- Only the part of the line height the Windows cell does not already cover is still leading.
  -- Arial's cell matches its typographic span so its whole gap survives, while Calibri's is taller
  -- by exactly its line gap and none of it does.
  return math.max 0, sfnt.getLineHeight(hhea) - cell.height

---The vertical metrics GDI reports for a face realized at a requested height, with the scaling the
---advances of that same realization take.
---@class GdiTextMetrics
---@field ppem integer The em the face is realized at, in device units.
---@field ascent integer Height above the baseline, in device units.
---@field descent integer Depth below the baseline, in device units; never negative.
---@field extlead integer Leading beyond the cell, in device units.
---@field toDeviceUnits fun(designUnits: number): integer Takes one design value onto the realized em.

---Derives the metrics for a face realized at a requested height, as GDI derives TEXTMETRIC.
---
---Where the cell is fitted to that height, the ascent and descent scale by it directly, never reaching
---the rasterizer, while the leading and the advances scale by the realized integer em GDI rasterizes
---at. The two look interchangeable and are not; one rule for all four misses by a device unit on some
---sizes. Where the requested height is the em instead, every value scales by that em alike.
---@param resolved ResolvedFace The face's design values.
---@param cell GdiCell The vertical span to realize into, as `deriveCell` read it off the face.
---@param fontSize integer Requested height, already multiplied by the measurement scale.
---@return GdiTextMetrics derived Values in device units, still carrying the measurement scale.
deriveTextMetrics = (resolved, cell, fontSize) ->
  {:hhea, :unitsPerEm, :hasCffOutlines} = resolved
  ppem = cell.emSized and fontSize or mulDivRound fontSize, unitsPerEm, cell.height
  toDeviceUnits = (designUnits) -> mulDivRound designUnits, ppem, unitsPerEm

  local ascent, descent
  if cell.emSized
    ascent, descent = toDeviceUnits(cell.ascent), toDeviceUnits cell.descent
  else
    ascent = mulDivRound cell.ascent, fontSize, cell.height
    descent = mulDivRound cell.descent, fontSize, cell.height

  return {
    :ppem
    :ascent
    :toDeviceUnits
    -- GDI clamps descenders above the baseline to zero
    descent: math.max 0, descent
    extlead: toDeviceUnits getExternalLeading hhea, cell, hasCffOutlines
  }

---Derives the TEXTMETRIC values GDI reports for a face from the face's own OS/2 and hhea tables, so a
---backend can reproduce the AegisubWindows contract on a platform with no GDI to ask.
---@class AegisubShimsGdiMetrics
GdiMetrics = {
  :CellSource
  :deriveCell
  :getExternalLeading
  :deriveTextMetrics
}

UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
return UnitTestSuite\withTestExports GdiMetrics, {:mulDivRound}
