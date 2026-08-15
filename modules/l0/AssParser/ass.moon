-- cspell:ignore HAABBGGRR -- the ASS color template, whose letters spell out its byte order

-- The shapes Aegisub's automation API hands subtitle lines over in, and the checks it applies before
-- it will take one back. The fields, their defaults and the checks are transcribed from `AssEntryToLua`,
-- `LuaToAssEntry` and the AssStyle constructor in Aegisub's own source, so a table built or validated
-- here behaves the same way inside Aegisub as it does headlessly.

Enum = require "l0.DependencyControl.Enum"

msgs = {
  validateStyle: {
    notAStyle: "Not a style entry"
    badField: "Invalid or missing field '%s' in 'style' class subtitle line (expected %s)"
  }
}

---The line classes Aegisub, libass and VSFilter support. Aegisub discards every other kind of line
---as it reads — the multimedia events SSA v4.00+ defines among them — so such a line neither
---survives a save nor reaches an automation script.
---
---As of 2026-08-15 the [Aegisub online documentation](https://aegisub.org/docs/latest/automation/lua/subtitle_file_interface/#unknown-class)
---mentions a fourth, `unknown`, which neither Aegisub nor any renderer implements.
---@alias AssLineClass string
---| "dialogue" # Dialogue: a rendered event, or a commented-out one
---| "style" # Style: an entry of the styles section
---| "info" # Info: a key and value from the script's header
LineClass = Enum "AssLineClass", {
  Dialogue: "dialogue"
  Style: "style"
  Info: "info"
}

---How a style asks for its text to be set off from the picture behind it. The specification names only
---the first two; the third is a libass extension, which Aegisub's style editor offers and labels as
---such, and which VSFilter draws as a plain outline because it reads every value but the opaque box
---as one. The numbering skips 2, and the format has never given it a meaning.
---@alias AssBorderStyle integer
---| 1 # Outline: an outline around each glyph, with a drop shadow behind it
---| 3 # OpaqueBox: a filled box behind the text, standing in for the outline
---| 4 # ShadowBox: a filled box behind the whole line, drawn without the drop shadow. libass alone.
BorderStyle = Enum "AssBorderStyle", {
  Outline: 1
  OpaqueBox: 3
  ShadowBox: 4
}

---How a line too wide for the frame is broken into multiple lines.
---Also decides whether `\n` breaks a line or becomes a space.
---
---A script states it in its Script Info and `\q` overrides it for a line, from where it stands
---onwards.
---@alias AssWrapStyle integer
---| 0 # SmartTopWider: broken on width and the lines balanced, leaving the upper one wider
---| 1 # EndOfLine: broken on width at the end of a line, with no balancing
---| 2 # NoWordWrap: never broken on width, and the one style under which `\n` breaks a line
---| 3 # SmartBottomWider: balanced as `SmartTopWider` is, leaving the lower one wider
WrapStyle = Enum "AssWrapStyle", {
  SmartTopWider: 0
  EndOfLine: 1
  NoWordWrap: 2
  SmartBottomWider: 3
}

---Stroke thickness a font is requested at. The mapper picks the nearest weight the face actually
---provides, so a value between two of these does not fail.
---@alias AssFontWeight
---| 0 # DontCare: leaves the weight to the font mapper
---| 100 # Thin: the lightest weight on the scale
---| 200 # ExtraLight: also called "UltraLight"
---| 300 # Light
---| 400 # Normal: the upright weight of a regular face, also called "Regular"
---| 500 # Medium
---| 600 # SemiBold: also called "DemiBold"
---| 700 # Bold: what an ASS style's bold flag asks for
---| 800 # ExtraBold: also called "UltraBold"
---| 900 # Heavy: the darkest weight on the scale, also called "Black"
FontWeight = Enum "AssFontWeight", {
  DontCare: 0
  Thin: 100
  ExtraLight: 200
  Light: 300
  Normal: 400
  Medium: 500
  SemiBold: 600
  Bold: 700
  ExtraBold: 800
  Heavy: 900
}

---The three shapes of the VB hexadecimal notation for color and alpha values, as the count of hex
---digits that shape holds. Styles use combined fields for a color and its alpha; override tags
---allow them to be changed separately, so `\1c` writes the color alone and `\1a` the alpha alone.
---@alias AssColorNotation integer
---| 8 # ColorAndAlpha: what a style's `color1` through `color4` hold, the alpha in the top byte
---| 6 # Color: what a color tag such as `\1c` or `\c` writes
---| 2 # Alpha: what an alpha tag such as `\1a` or `\alpha` writes
ColorNotation = Enum "AssColorNotation", {
  ColorAndAlpha: 8
  Color: 6
  Alpha: 2
}

---Reads the VB hexadecimal notation used both in a style's colors and in the color and
---alpha tags. Returns one packed integer, so a style's value holds its alpha in the top byte where
---a tag's holds only either the color or the alpha.
---@param text string The value as the file or the tag wrote it, with or without its `&H` and closing `&`.
---@return integer value The packed RGB or RGBA value, with the alpha in the top byte where present. Zero in case parsing fails.
parseColor = (text) ->
  ---Both renderers skip over a leading run of any sequence consisting of only `&` and `H`, so a
  ---literal missing one of them, or including multiple, still yields the digits behind it.
  ---However, the skip is case-sensitive, so a lowercase `&h` retains the `h` as the start of the value,
  ---which fails to parse and yields zero.
  digits = text\gsub "^[&H]+", ""

  -- Both renderers skip the prefix by hand and hand the rest to `strtoll` at base 16, which is why
  -- signed numbers and the `0x` notation are accepted despite the ASS format docs not mentioning them.
  sign, value = digits\match "^%s*([+-]?)0[xX](%x+)"
  sign, value = digits\match "^%s*([+-]?)(%x+)" unless value
  return 0 unless value
  value = tonumber value, 16
  sign == "-" and -value or value

---Writes a packed numeric value back into VB hexadecimal notation.
---Padded with leading zeroes to fill the shape requested, so passing in an RGB color for an RGBA
---shape writes the alpha as zero/opaque.
---@param value integer The packed RGB/RGBA value.
---@param notation? AssColorNotation Which shape to write, RGBA by default.
---@return string text The value as a style or tag would write it, with the `&H` prefix and closing `&`.
emitColor = (value, notation = ColorNotation.ColorAndAlpha) -> "&H%0#{notation}X&"\format value

---Splits a style's packed numeric color value into its RGB and alpha components.
---@param value integer An RGBA style color as `parseColor` returned it.
---@return integer color The three RGB color bytes.
---@return integer alpha The alpha byte.
splitStyleColor = (value) -> value % 0x1000000, math.floor value / 0x1000000

---Puts the two back together the way a style names them.
---@param color integer The three color bytes.
---@param alpha? integer The top byte, fully opaque where absent.
---@return integer value
packStyleColor = (color, alpha = 0) -> alpha * 0x1000000 + color

-- The Script Info key stating the wrap style, and what a script stating none is read as.
WRAP_STYLE_INFO_KEY = "WrapStyle"
DEFAULT_WRAP_STYLE = WrapStyle.SmartTopWider

---Where a legacy alignment number originates from.
---Affects rendering for numbers the legacy format does not define.
---@alias AssAlignmentSource
---| 1 # StyleField: a style's own `Alignment`, as an SSA `[V4 Styles]` section numbers it
---| 2 # OverrideTag: an `\a` argument
AlignmentSource = Enum "AssAlignmentSource", {
  StyleField: 1
  OverrideTag: 2
}

-- SSA numbers 1 to 3 along the bottom, adds 4 for the top and 8 for the middle, and defines neither 4
-- nor 8. Both renderers agree on what each source draws, and the two sources part on exactly those two
-- undefined numbers: written as a style's `Alignment` they draw bottom-right and middle-right, written
-- as `\a` they both draw top-left. Nothing outside 1 through 11 is listed, since the renderers part
-- there and `\a` puts the style's own alignment back for one.
keypadByLegacyAlignment = {
  [AlignmentSource.StyleField]: {1, 2, 3, 6, 7, 8, 9, 3, 4, 5, 6}
  [AlignmentSource.OverrideTag]: {1, 2, 3, 7, 7, 8, 9, 7, 4, 5, 6}
}

---A field of a parsed line, under the name Aegisub's automation API reports it by
---@alias AegisubLineField string
---| "name" # Name: a style's name
---| "fontname" # FontName
---| "fontsize" # FontSize
---| "color1" # PrimaryColor
---| "color2" # SecondaryColor
---| "color3" # OutlineColor
---| "color4" # BackColor
---| "bold" # Bold
---| "italic" # Italic
---| "underline" # Underline
---| "strikeout" # StrikeOut
---| "scale_x" # ScaleX
---| "scale_y" # ScaleY
---| "spacing" # Spacing
---| "angle" # Angle
---| "borderstyle" # BorderStyle
---| "outline" # Outline
---| "shadow" # Shadow
---| "align" # Alignment: keypad numbering, whatever the section wrote it in
---| "encoding" # Encoding: the character set a style asks to be laid out in
---| "layer" # Layer
---| "start_time" # StartTime: milliseconds
---| "end_time" # EndTime: milliseconds
---| "style" # Style: the style an event is set in
---| "actor" # Actor: the `Name` field, which Aegisub reports under this name
---| "effect" # Effect
---| "text" # Text: the one field that keeps the whitespace around it
---| "margin_l" # MarginLeft
---| "margin_r" # MarginRight
---| "margin_t" # MarginTop: what `MarginV` states, which `margin_b` is set to alongside
LineField = Enum "AegisubLineField", {
  Name: "name"
  FontName: "fontname"
  FontSize: "fontsize"
  PrimaryColor: "color1"
  SecondaryColor: "color2"
  OutlineColor: "color3"
  BackColor: "color4"
  Bold: "bold"
  Italic: "italic"
  Underline: "underline"
  StrikeOut: "strikeout"
  ScaleX: "scale_x"
  ScaleY: "scale_y"
  Spacing: "spacing"
  Angle: "angle"
  BorderStyle: "borderstyle"
  Outline: "outline"
  Shadow: "shadow"
  Alignment: "align"
  Encoding: "encoding"
  Layer: "layer"
  StartTime: "start_time"
  EndTime: "end_time"
  Style: "style"
  Actor: "actor"
  Effect: "effect"
  Text: "text"
  MarginLeft: "margin_l"
  MarginRight: "margin_r"
  MarginTop: "margin_t"
}

---The fields every line table holds, regardless of what kind it is.
---@class AegisubLine
---@field class AssLineClass Which kind of line the table is.
---@field section string The section header for the line's `class`. Aegisub fills it in from the class
---  alone rather than from the heading the line was parsed under, and never reads it back, so a style
---  out of a legacy `[V4 Styles]` script still reports `[V4+ Styles]`.
---@field raw string The line as it appears in the file. Written on the way out, ignored on the way in.

---A key and value from the script's header, one per line of the section.
---@class AegisubInfoLine: AegisubLine
---@field class "info"
---@field key string Text before the first colon, which is the setting's name.
---@field value string Text after it, with leading whitespace trimmed.

---A style line as Aegisub's automation API hands it over, from a subtitles object or to
---`aegisub.text_extents`. The fields mirror Aegisub's representation of a style, which diverges from
---the ASS file format's own field names.
---@class AegisubStyleLine: AegisubLine
---@field class "style"
---@field name string Name the dialogue lines refer to this style by.
---@field fontname string Family name the style asks for.
---@field fontsize number Size in pixels, which asks for a cell height rather than an em.
---@field color1 string Fill color, in VB hexadecimal as "&HAABBGGRR&".
---@field color2 string Pre-karaoke fill color, in the same form.
---@field color3 string Border color, in the same form.
---@field color4 string Shadow color, in the same form.
---@field bold boolean Whether the face is set bold. Aegisub carries this as a boolean from the file it parsed through to measurement, and refuses a non-boolean where it reads a style back out of Lua, so a numeric weight never reaches a style however the file spelled it.
---@field italic boolean
---@field underline boolean
---@field strikeout boolean
---@field scale_x number Horizontal scaling, in percent.
---@field scale_y number Vertical scaling, in percent.
---@field spacing number Extra advance between characters, always a whole number.
---@field angle number Rotation about the z axis, in degrees.
---@field borderstyle AssBorderStyle|number How the text is set off from the picture behind it. Aegisub reads
---  whatever integer the file held and writes it back unchanged, so a value outside `BorderStyle`
---  is formally accepted; renderers generally draw unknown border styles as an outline, but differ on whether
---  the number or its effect is used to compare run state (see `AssRunComparison.foldsBorderStyle`).
---@field outline number Width of the outline.
---@field shadow number Distance between the shadow and the text.
---@field align number Alignment on the numeric keypad layout, 1 through 9.
---@field margin_l number Left margin, in pixels.
---@field margin_r number Right margin, in pixels.
---@field margin_t number Top margin, in pixels.
---@field margin_b number Bottom margin, in pixels. Aegisub fills it from the same value as `margin_t` and never reads it back, so the two always agree however the file was written.
---@field encoding number Font encoding, from the Windows character set constants in `GdiCharSet`.
---@field relative_to number What the margins are measured against; Aegisub reports 2 for every style.

-- What a style starts out as, taken from the member initializers on Aegisub's AssStyle and the margin
-- its constructor fills in.
defaultStyle = {
  class: LineClass.Style
  section: "[V4+ Styles]"
  name: "Default"
  fontname: "Arial"
  fontsize: 48
  color1: emitColor 0x00FFFFFF
  color2: emitColor 0x000000FF
  color3: emitColor 0x00000000
  color4: emitColor 0x00000000
  bold: false
  italic: false
  underline: false
  strikeout: false
  scale_x: 100
  scale_y: 100
  spacing: 0
  angle: 0
  borderstyle: BorderStyle.Outline
  outline: 2
  shadow: 2
  align: 2
  margin_l: 10
  margin_r: 10
  margin_t: 10
  margin_b: 10
  encoding: 1
  relative_to: 2
}

-- `margin_b` and `relative_to` are absent because Aegisub writes them out but never reads them back
styleFields = {
  {LineField.Name, "string"}
  {LineField.FontName, "string"}
  {LineField.FontSize, "number"}
  {LineField.PrimaryColor, "string"}
  {LineField.SecondaryColor, "string"}
  {LineField.OutlineColor, "string"}
  {LineField.BackColor, "string"}
  {LineField.Bold, "boolean"}
  {LineField.Italic, "boolean"}
  {LineField.Underline, "boolean"}
  {LineField.StrikeOut, "boolean"}
  {LineField.ScaleX, "number"}
  {LineField.ScaleY, "number"}
  {LineField.Spacing, "number"}
  {LineField.Angle, "number"}
  {LineField.BorderStyle, "number"}
  {LineField.Outline, "number"}
  {LineField.Shadow, "number"}
  {LineField.Alignment, "number"}
  {LineField.MarginLeft, "number"}
  {LineField.MarginRight, "number"}
  {LineField.MarginTop, "number"}
  {LineField.Encoding, "number"}
}

---A dialogue line, as `subtitles[i]` hands one over and as `subtitles[i] = line` takes one back.
---
---The two directions are not the same shape. A line coming out holds every field below; on the way
---back in Aegisub reads all of them except `margin_b`, and requires each one it reads to be present
---and of the right type, with the exception of `extra`, which is the sole optional field.
---@class AegisubDialogueLine: AegisubLine
---@field class "dialogue"
---@field comment boolean Whether the line is a comment rather than a rendered event.
---@field layer integer Layer the line draws on, higher over lower.
---@field start_time integer Start, in milliseconds.
---@field end_time integer End, in milliseconds.
---@field style string Name of the style the line uses.
---@field actor string The Name field, which Aegisub labels Actor.
---@field effect string The Effect field, which karaoke templaters and Aegisub's own banner and scroll effects read.
---@field margin_l integer Left margin in pixels, or 0 to take the style's.
---@field margin_r integer Right margin in pixels, or 0 to take the style's.
---@field margin_t integer Vertical margin in pixels, or 0 to take the style's. Also the top margin where the two differ.
---@field margin_b integer Bottom margin. Written on the way out, ignored on the way in, and always equal to `margin_t`.
---@field text string The line's text, with its override blocks.
---@field extra? table<string, string> Extradata, keyed by name. The one optional field: a line read from `subtitles` always carries it, and one built by hand need not.

---The shapes Aegisub's automation API carries subtitle lines in, and the checks it applies to them.
---@class Ass
---@field defaultStyle AegisubStyleLine The values a style starts out as, as Aegisub's AssStyle does. Read-only; copy it with `createStyle` rather than mutating it.
---@field defaultWrapStyle AssWrapStyle What a script stating no `WrapStyle` is read as.
Ass = {
  LineClass: LineClass
  FontWeight: FontWeight
  LineField: LineField
  AlignmentSource: AlignmentSource
  styleFields: styleFields

  ---Reads a legacy alignment number as the keypad number `\an` and a V4+ style write.
  ---@param legacy integer The number as it was written in an `\a` tag or an SSA V4 style.
  ---@param source AssAlignmentSource Where it was written, which decides what 4 and 8 draw as.
  ---@return integer? keypad 1 through 9, nil for a number outside 1 through 11. A `\a` holding one of
  ---  those leaves the style's own alignment standing; a style field holding one is drawn differently
  ---  by each renderer, so neither has a reading to report.
  getKeypadAlignment: (legacy, source) ->
    assert AlignmentSource\validate source, "source"
    keypadByLegacyAlignment[source][legacy]
  BorderStyle: BorderStyle
  WrapStyle: WrapStyle
  ColorNotation: ColorNotation
  parseColor: parseColor
  emitColor: emitColor
  splitStyleColor: splitStyleColor
  packStyleColor: packStyleColor
  defaultStyle: defaultStyle
  defaultWrapStyle: DEFAULT_WRAP_STYLE

  ---The wrap style a script states in its Script Info, which decides whether `\n` breaks a line where
  ---no `\q` has overridden it. The value is not range-checked, since no renderer checks it either, but
  ---a number above the declared range yields different results between libass and VSFilter.
  ---@param lines table Line tables in file order, such as a subtitles object or a plain array.
  ---@return AssWrapStyle wrapStyle The last value the header states, the format's own where it states none.
  getWrapStyle: (lines) ->
    stated = nil
    for index = 1, #lines
      line = lines[index]
      -- a later line of the same key overwrites an earlier one, so the scan keeps the last
      stated = line.value if line.class == LineClass.Info and line.key == WRAP_STYLE_INFO_KEY
    return DEFAULT_WRAP_STYLE if stated == nil
    tonumber(tostring(stated)\match "^%s*[-+]?%d+") or DEFAULT_WRAP_STYLE

  ---Builds a complete style table, so it passes the checks Aegisub applies before it will measure or
  ---commit one. Handy for a test wanting a valid style it can vary one field of, and for code building
  ---styles to write into a file.
  ---@param overrides? table<string, any> Fields to set instead of the default the same key carries.
  ---@return AegisubStyleLine style A fresh table, sharing nothing with the defaults or with `overrides`.
  createStyle: (overrides) ->
    style = {key, value for key, value in pairs defaultStyle}
    style[key] = value for key, value in pairs overrides or {}
    return style

  ---Checks a style table the way Aegisub checks one before measuring or committing it, so a table this
  ---accepts is one Aegisub will take. It reads a field it never writes back, `margin_b` among them, so
  ---a table built by hand needs more than the fields a measurement happens to consult.
  ---@param style table The table to check.
  ---@return boolean? valid True where Aegisub would accept it, nil where it would raise.
  ---@return string? err The message Aegisub would raise, worded as Aegisub words it.
  validateStyle: (style) ->
    return nil, msgs.validateStyle.notAStyle unless "table" == type style
    return nil, msgs.validateStyle.notAStyle unless LineClass.Style == tostring(style.class)\lower!

    for {field, kind} in *styleFields
      value = style[field]
      accepted = switch kind
        when "string" then "string" == type(value) or "number" == type value
        when "number" then nil != tonumber value
        when "boolean" then "boolean" == type value
      return nil, msgs.validateStyle.badField\format field, kind unless accepted

    return true
}

return Ass
