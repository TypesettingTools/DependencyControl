  -- cspell:ignore AABBGGRR, HBBGGRR, HAABBGGRR
utils = require "l0.DependencyControl.utils"

msgs = {
  hsvToRgb: {
    badSector: "The hue sector must fall in [0, 6), got %s."
  }
}

-- Aegisub guards these entry points with an argument-type check, so a caller passing the wrong type
-- fails at the boundary and names the argument instead of erroring somewhere inside the call.
assertArgType = utils.assertArgType

formatAssColor = (r, g, b) -> "&H%02X%02X%02X&"\format b, g, r

formatAssAlpha = (a) -> "&H%02X&"\format a

extractColor = (str) ->
  assertArgType str, 1, "string"

  -- a style definition packs all four components as AABBGGRR and ends without an ampersand
  a, b, g, r = str\match "&H(%x%x)(%x%x)(%x%x)(%x%x)"
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), tonumber(a, 16) if a

  b, g, r = str\match "&H(%x%x)(%x%x)(%x%x)&"
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16), 0 if b

  a = str\match "&H(%x%x)&"
  return 0, 0, 0, tonumber(a, 16) if a

  -- an HTML color may drop its trailing components, which read as absent rather than zero
  r, g, b, a = str\match "#(%x%x)(%x?%x?)(%x?%x?)(%x?%x?)"
  return tonumber(r, 16), tonumber(g, 16) or 0, tonumber(b, 16) or 0, tonumber(a, 16) or 0 if r

clamp = (value, min, max) ->
  return min if value < min
  return max if value > max
  return value

interpolate = (pct, min, max) ->
  return min if pct <= 0
  return max if pct >= 1
  return pct * (max - min) + min

splitHeadTail = (str) ->
  matched, _, head, tail = str\find "(.-)%s+(.*)"
  return head, tail if matched
  return str, ""

-- scales a 0-1 color component to a rounded 0-255 channel value
toUint8 = (value) -> math.floor value * 255 + 0.5

---Headless stand-in for Aegisub's `aegisub.util` module, reached under that require id once
---l0.AegisubShims has claimed it, so a script requiring it loads and can be tested outside Aegisub.
---
---The surface tracks Aegisub's, quirks included, so a script behaves the same either way: the exports
---keep their snake_case names, `trim` yields gsub's replacement count as a second value,
---`extract_color` returns nothing for a string it doesn't recognize, and `HSV_to_RGB` produces
---unrounded floats where `HSL_to_RGB` rounds to integers.
---@class AegisubUtil
Util = {
  ---Shallow-copies a table.
  ---@param tbl table The table to copy.
  ---@return table copy The copied table.
  copy: (tbl) ->
    assertArgType tbl, 1, "table"
    return utils.copy tbl

  ---Deep-copies a table recursively, preserving circular references and shared table identities.
  ---@param tbl table The table to deep-copy.
  ---@return table copy The deep-copied table.
  deep_copy: (tbl) ->
    assertArgType tbl, 1, "table"
    return utils.deepCopy tbl

  ---Formats RGB components as an ASS color override (`&HBBGGRR&`).
  ---@param r number Red component, 0-255.
  ---@param g number Green component, 0-255.
  ---@param b number Blue component, 0-255.
  ---@return string color The ASS color override code.
  ass_color: formatAssColor

  ---Formats an alpha component as an ASS alpha override (`&HAA&`).
  ---@param a number Alpha component, 0-255.
  ---@return string alpha The ASS alpha override code.
  ass_alpha: formatAssAlpha

  ---Formats RGBA components as a style-definition color (`&HAABBGGRR`, with no trailing ampersand).
  ---@param r number Red component, 0-255.
  ---@param g number Green component, 0-255.
  ---@param b number Blue component, 0-255.
  ---@param a number Alpha component, 0-255.
  ---@return string color The style-definition color code.
  ass_style_color: (r, g, b, a) -> "&H%02X%02X%02X%02X"\format a, b, g, r

  ---Splits an ASS color into its components, accepting a style definition, a color or alpha override,
  ---or an HTML color. Components the notation omits come back as 0.
  ---@param str string The color to split.
  ---@return number? r Red component, or no values at all when the string isn't a recognized color.
  ---@return number? g Green component.
  ---@return number? b Blue component.
  ---@return number? a Alpha component.
  extract_color: extractColor

  ---Builds an ASS alpha override from a style definition's color.
  ---@param styleColor string The style-definition color to read the alpha from.
  ---@return string alpha The ASS alpha override code.
  alpha_from_style: (styleColor) -> formatAssAlpha select 4, extractColor styleColor

  ---Builds an ASS color override from a style definition's color, dropping its alpha.
  ---@param styleColor string The style-definition color to read the components from.
  ---@return string color The ASS color override code.
  color_from_style: (styleColor) ->
    r, g, b = extractColor styleColor
    return formatAssColor r or 0, g or 0, b or 0

  ---Converts an HSV color to RGB.
  ---@param hue number Hue in degrees; folded by absolute value into [0, 360), so -150 reads as 150.
  ---@param saturation number Saturation, 0-1.
  ---@param value number Value, 0-1.
  ---@return number r Red component, 0-255 and unrounded.
  ---@return number g Green component, 0-255 and unrounded.
  ---@return number b Blue component, 0-255 and unrounded.
  HSV_to_RGB: (hue, saturation, value) ->
    if saturation == 0
      grey = clamp value * 255, 0, 255
      return grey, grey, grey

    hue = math.abs(hue) % 360
    sector = math.floor hue / 60
    offset = hue / 60.0 - sector

    -- across a 60° sector, one channel holds the peak (V) and another the minimum (p), while the third
    -- crosses between them. Even sectors ramp it up (t) and odd sectors ramp it down (q), with the
    -- offset placing the hue along that ramp.
    peak = value * 255.0 -- V
    minimum = value * (1 - saturation) * 255.0 -- p
    falling = value * (1 - offset * saturation) * 255.0 -- q
    rising = value * (1 - (1 - offset) * saturation) * 255.0 -- t

    switch sector
      when 0 then return peak, rising, minimum
      when 1 then return falling, peak, minimum
      when 2 then return minimum, peak, rising
      when 3 then return minimum, falling, peak
      when 4 then return rising, minimum, peak
      when 5 then return peak, minimum, falling

    -- the sector comes from a hue already folded into [0, 360), so only a non-finite hue lands outside
    -- the six cases: a NaN survives the fold, and an infinity turns into one
    error msgs.hsvToRgb.badSector\format tostring sector

  ---Converts an HSL color to RGB.
  ---@param hue number Hue in degrees; folded by absolute value into [0, 360), so -150 reads as 150.
  ---@param saturation number Saturation, clamped to 0-1.
  ---@param luminance number Luminance, clamped to 0-1.
  ---@return number r Red component, 0-255 and rounded.
  ---@return number g Green component, 0-255 and rounded.
  ---@return number b Blue component, 0-255 and rounded.
  HSL_to_RGB: (hue, saturation, luminance) ->
    hue = math.abs(hue) % 360
    saturation = clamp saturation, 0, 1
    luminance = clamp luminance, 0, 1

    if saturation == 0
      grey = toUint8 luminance
      return grey, grey, grey

    -- the brightest (Q) and dimmest (P) levels the channels move between
    peak = luminance < 0.5 and luminance * (1.0 + saturation) or luminance + saturation - luminance * saturation
    minimum = 2.0 * luminance - peak

    -- each channel reads the hue circle a third of a turn from the next, so its own position on that
    -- circle decides where in the minimum-to-peak ramp it lands. Hk and Tr/Tg/Tb in the formulation.
    huePosition = hue / 360 -- Hk
    local redPhase, greenPhase, bluePhase -- Tr, Tg, Tb
    if huePosition < 1/3
      redPhase, greenPhase, bluePhase = huePosition + 1/3, huePosition, huePosition + 2/3
    elseif huePosition > 2/3
      redPhase, greenPhase, bluePhase = huePosition - 2/3, huePosition, huePosition - 1/3
    else
      redPhase, greenPhase, bluePhase = huePosition + 1/3, huePosition, huePosition - 1/3

    -- a phase walks four spans of the circle: a ramp up over the first sixth, a hold at the peak to
    -- the half turn, a ramp down to two thirds, then a hold at the minimum
    getComponent = (phase) ->
      return minimum + (peak - minimum) * 6.0 * phase if phase < 1/6
      return peak if phase < 1/2
      return minimum + (peak - minimum) * (2/3 - phase) * 6.0 if phase < 2/3
      return minimum

    return toUint8(getComponent redPhase), toUint8(getComponent greenPhase), toUint8(getComponent bluePhase)

  ---Strips leading and trailing whitespace from a string.
  ---@param str string The string to trim.
  ---@return string trimmed The trimmed string.
  ---@return number replacements The gsub replacement count, carried through as Aegisub's module does.
  trim: (str) -> str\gsub "^%s*(.-)%s*$", "%1"

  ---Splits a string into its first whitespace-separated word and the remainder.
  ---@param str string The string to split.
  ---@return string head The first word, or the whole string when it holds no whitespace.
  ---@return string tail Everything after the whitespace, or an empty string.
  headtail: splitHeadTail

  ---Iterates the whitespace-separated words of a string.
  ---@param str string The string to walk.
  ---@return fun(): string? iterator Yields each word in turn, then nil.
  words: (str) ->
    return ->
      return if str == ""
      head, tail = splitHeadTail str
      str = tail
      return head

  ---Clamps a number to a range.
  ---@param value number The number to clamp.
  ---@param min number Lower bound.
  ---@param max number Upper bound.
  ---@return number clamped The bounded value.
  clamp: clamp

  ---Interpolates linearly between two numbers.
  ---@param pct number Position between the bounds; values outside 0-1 return the nearer bound.
  ---@param min number Value at 0.
  ---@param max number Value at 1.
  ---@return number value The interpolated value.
  interpolate: interpolate

  ---Interpolates between two ASS colors, in either style-definition or override notation.
  ---@param pct number Position between the colors, 0-1.
  ---@param first string The color at 0.
  ---@param last string The color at 1.
  ---@return string color The interpolated color, as an ASS color override.
  interpolate_color: (pct, first, last) ->
    r1, g1, b1 = extractColor first
    r2, g2, b2 = extractColor last
    return formatAssColor interpolate(pct, r1, r2), interpolate(pct, g1, g2), interpolate(pct, b1, b2)

  ---Interpolates between the alpha components of two ASS colors, in either notation.
  ---@param pct number Position between the alphas, 0-1.
  ---@param first string The color at 0.
  ---@param last string The color at 1.
  ---@return string alpha The interpolated alpha, as an ASS alpha override.
  interpolate_alpha: (pct, first, last) ->
    return formatAssAlpha interpolate pct, (select 4, extractColor first), (select 4, extractColor last)
}

return Util
