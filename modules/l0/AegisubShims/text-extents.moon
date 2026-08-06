-- What the text-extents backends in text-extents-backends/ share: the contracts they can measure by,
-- the constants their arithmetic is expressed in, and the selection that picks one.
--
-- The backends require this module for those, so nothing here may require a backend while this file
-- is being loaded. `selectBackend` builds its candidate list on first call instead, by which point
-- this module has returned and a backend requiring it back finds it complete.

Enum = require "l0.DependencyControl.Enum"

msgs = {
  selectBackend: {
    noBackend: "No backend for that metric contract could load its libraries here."
  }
}

-- Aegisub measures at this multiple of the style's font size and divides the four results back down,
-- which buys six binary digits of resolution the whole-pixel metrics would otherwise round away.
MEASUREMENT_SCALE = 64

-- A point is a 72nd of an inch, so a DPI over this is the factor taking a size asked for in points
-- onto the pixels a measurement comes back in.
POINTS_PER_INCH = 72

-- The resolution a desktop reports unless it has been configured otherwise, which Windows, X11 and
-- Pango all take as their default. Only the AegisubLinux contract reads it, where it scales the
-- spacing term.
DEFAULT_DPI = 96

---Which of Aegisub's disagreeing metric contracts to measure by.
---@alias TextExtentsMetricMode
---| 1 # AegisubWindows: the OS/2 Windows cell, derived as GDI derives TEXTMETRIC, which is also what libass renders by
---| 2 # AegisubLinux: what Aegisub reports on Linux, where wxGTK exposes only the typographic metrics through Pango
MetricMode = Enum "TextExtentsMetricMode", {
  AegisubWindows: 1
  AegisubLinux: 2
}

---How a backend built by a `createBackend` should measure.
---@class TextExtentsOptions
---@field metricMode? TextExtentsMetricMode Which contract to measure by, `AegisubWindows` by default. Read only by backends offering more than one.
---@field kerning? boolean Whether to apply the face's kern table to text set solid; defaults to what the mode implies.
---@field dpi? number DPI the `AegisubLinux` contract measures at, 96 by default. Only a style setting `spacing` reads it, and the `AegisubWindows` contract never does.

-- The candidates for each contract, best first, built on first use so that requiring a backend here
-- cannot race this module's own loading. Every backend probes its libraries by loading them through
-- the FFI at require time, so availability reflects what this process can actually call.
local candidatesByMode

buildCandidates = ->
  gdi = require "l0.AegisubShims.text-extents-backends.gdi"
  coretext = require "l0.AegisubShims.text-extents-backends.coretext"
  freetype = require "l0.AegisubShims.text-extents-backends.freetype"
  pango = require "l0.AegisubShims.text-extents-backends.pango"
  return {
    [MetricMode.AegisubWindows]: {
      {name: "GDI", module: gdi, build: -> gdi.measure}
      {name: "CoreText", module: coretext, build: -> coretext.measure}
      {name: "FreeType/AegisubWindows", module: freetype, build: -> freetype.measure}
    }
    [MetricMode.AegisubLinux]: {
      {name: "Pango", module: pango, build: -> pango.measure}
      {name: "FreeType/AegisubLinux", module: freetype, build: ->
        freetype.createBackend {metricMode: MetricMode.AegisubLinux}}
    }
  }

---Picks the best available text-measurement backend for a metric contract.
---
---The default contract is AegisubWindows on every platform, deliberately parting from what Aegisub
---itself reports off Windows: it is the one Aegisub implementation libass and VSFilter agree with,
---so a measurement predicts what the subtitle renderer will draw, and it makes a script measure the
---same numbers everywhere. AegisubLinux instead reproduces what a script would measure in Aegisub
---on Linux.
---@param metricMode? TextExtentsMetricMode The contract to measure by, AegisubWindows by default.
---@return AegisubTextExtentsBackend? measure Nil when no backend for the contract can load its libraries here.
---@return string nameOrErr Name of the backend picked, or why none could be.
selectBackend = (metricMode = MetricMode.AegisubWindows) ->
  valid, modeErr = MetricMode\validate metricMode, "metricMode"
  assert valid, modeErr

  candidatesByMode or= buildCandidates!
  for candidate in *candidatesByMode[metricMode]
    if candidate.module.isAvailable
      -- built once, so repeated selection hands back the same function a caller can compare against
      candidate.measure or= candidate.build!
      return candidate.measure, candidate.name
  return nil, msgs.selectBackend.noBackend

---The metric contracts the text-extents backends measure by, and the selection between them.
---@class AegisubTextExtents
---@field MetricMode Enum The contracts on offer, as a TextExtentsMetricMode enum.
---@field selectBackend fun(metricMode?: TextExtentsMetricMode): AegisubTextExtentsBackend?, string Picks the best available backend for a contract.
---@field MEASUREMENT_SCALE integer What Aegisub multiplies a font size by before measuring.
---@field POINTS_PER_INCH integer Points in an inch, which converts a DPI to a point-to-pixel factor.
---@field DEFAULT_DPI integer The resolution a desktop reports unless configured otherwise.
return {
  MetricMode: MetricMode
  selectBackend: selectBackend

  MEASUREMENT_SCALE: MEASUREMENT_SCALE
  POINTS_PER_INCH: POINTS_PER_INCH
  DEFAULT_DPI: DEFAULT_DPI
}
