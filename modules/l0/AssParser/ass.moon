-- cspell:ignore HAABBGGRR -- the ASS color template, whose letters spell out its byte order

-- The shapes Aegisub's automation API hands subtitle lines over in, and the checks it applies before
-- it will take one back. The fields, their defaults and the checks are transcribed from `AssEntryToLua`,
-- `LuaToAssEntry` and the AssStyle constructor in Aegisub's own source, so a table built or validated
-- here behaves the same way inside Aegisub as it does headlessly.

Enum = require "l0.DependencyControl.Enum"

msgs = {
  validateLine: {
    notATable: "A subtitle line has to be a table, not a %s."
    noClassField: "A subtitle line has to state its class."
    unknownClass: "'%s' is not a subtitle line class."
    wrongClass: "Expected a '%s' line, got a '%s' one."
    badFields: "A '%s' line is missing or misstates %s."
    badField: "'%s' (expected %s)"
    extraNotATable: "A line's extradata has to be a table, not a %s."
  }
}

---The line classes Aegisub, libass and VSFilter support. Aegisub discards every other kind of line
---as it reads — the multimedia events SSA v4.00+ defines among them — so such a line neither
---survives a save nor is passed to an automation script.
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
---| 3 # OpaqueBox: a filled box behind the text, drawn instead of the outline
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
---@param allowPrefix? boolean Whether a leading `&H` is skipped before the digits are read, true by
---  default. Only intended to be set to false for parenthesized color and alpha values when the
--- `honorsColorPrefixInParentheses` ASS dialect option is false.
---@return integer value The packed RGB or RGBA value, with the alpha in the top byte where present. Zero in case parsing fails.
parseColor = (text, allowPrefix = true) ->
  ---A skipped prefix is a leading run of any sequence consisting of only `&` and `H`, so a literal
  ---missing one of them, or including multiple, still yields the digits behind it.
  ---However, the skip is case-sensitive, so a lowercase `&h` retains the `h` as the start of the value,
  ---which fails to parse and yields zero.
  digits = text
  digits = text\gsub "^[&H]+", "" if allowPrefix

  -- Both renderers skip the prefix by hand and hand the rest to `strtoll` at base 16, which is why
  -- signed numbers and the `0x` notation are accepted despite the ASS format docs not mentioning them.
  sign, value = digits\match "^%s*([+-]?)0[xX](%x+)"
  sign, value = digits\match "^%s*([+-]?)(%x+)" unless value
  return 0 unless value
  value = tonumber value, 16
  sign == "-" and -value or value

---Reads the hex digits out of a color or alpha literal, so `&H20&` gives "20". Useful for telling a
---well-formed literal from a malformed one.
---
---Only the exact `&H…&` shape is accepted, uppercase `H` and both ampersands included, whereas
---`parseColor` reproduces the renderers' leniency and returns a cleaned packed integer either way.
---@param text string The value as a tag or a style wrote it.
---@return string? digits Nil where the literal is written any other way.
readColorLiteralDigits = (text) -> text\match "^&H(%x+)&$"

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

-- The Script Info key stating the wrap style.
---@type string
WRAP_STYLE_INFO_KEY = "WrapStyle"
---The wrap style used where a script doesn't specify one.
---@type AssWrapStyle
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

---A field of a parsed line, under the name Aegisub's automation API reports it by. `margin_b` and
---`relative_to` have no member here: Aegisub reports both on a line but ignores them in a line it is
---given, so neither is ever read back or validated.
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
---| "actor" # Actor: the `Name` field
---| "effect" # Effect
---| "text" # Text: the one field that keeps the whitespace around it
---| "margin_l" # MarginLeft
---| "margin_r" # MarginRight
---| "margin_t" # MarginTop: the `MarginV` field
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
  Comment: "comment"
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
  Extra: "extra"
  Key: "key"
  Value: "value"
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
---@field bold boolean Whether the face is set bold. Aegisub keeps this as a boolean from the file it
---  parsed through to measurement, and refuses a non-boolean where it reads a style back out of Lua, so
---  a numeric weight never reaches a style however the file spelled it.
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
---@field margin_b number Bottom margin, in pixels. Aegisub fills it from the same value as `margin_t`
---  and never reads it back, so the two always agree however the file was written.
---@field encoding number Font encoding, from the Windows character set constants in `GdiCharSet`.
---@field relative_to number What the margins are measured against; Aegisub reports 2 for every style.

---The style used when the one specified in a line's `style` field has no matching declaration in the script's style section.
---@type string
DEFAULT_STYLE_NAME = "Default"

-- The heading Aegisub reports a line under, which comes from the line's class and not from the section
-- it was read out of, and the order Aegisub hands the classes over in.
sectionByClass = {
  [LineClass.Info]: "[Script Info]"
  [LineClass.Style]: "[V4+ Styles]"
  [LineClass.Dialogue]: "[Events]"
}
lineClassOrder = {LineClass.Info, LineClass.Style, LineClass.Dialogue}

---The values a style starts out with, taken from the member initializers on Aegisub's AssStyle and the margin
---its constructor fills in. Read-only; copy it with `createStyle` rather than mutating it.
---@type AegisubStyleLine
defaultStyle = {
  class: LineClass.Style
  section: "[V4+ Styles]"
  name: DEFAULT_STYLE_NAME
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

---Builds a complete style table to be used with Aegisub's subtitle file interface.
---@param overrides? table<string, any> Fields to set instead of the one the same key holds in the base.
---@param baseStyle? AegisubStyleLine What every other field is taken from, the values a style starts
---  out as by default. Name another complete style to state a variation of that one instead.
---@return AegisubStyleLine style A fresh table, sharing nothing with the base or with `overrides`.
createStyle = (overrides, baseStyle = defaultStyle) ->
  style = {key, value for key, value in pairs baseStyle}
  style[key] = value for key, value in pairs overrides or {}
  return style

---Normalizes a style name for looking it up among the script's declared styles.
---Leading whitespace and stars are stripped, but trailing ones are not.
---@param name string A name as a style declares it or a line's style field holds it.
---@return string reachable The normalized name.
getReachableStyleName = (name) -> name\match "^%s*%**(.*)$"

---Finds the declaration a name reaches, by the renderers' own matching rather than by a plain lookup.
---@param stylesByName table<string, AegisubStyleLine> Every style the script declares, keyed as declared.
---@param resolvedStyleName string A style name already reduced by `getReachableStyleName`.
---@return string? declaredStyleName The name as the script declares it, nil where the name reaches none.
---@return AegisubStyleLine? style The declared style, nil where the name reaches none.
findDeclaredStyle = (stylesByName, resolvedStyleName) ->
  declared = stylesByName[resolvedStyleName]
  return resolvedStyleName, declared if declared
  -- Only a script that declares a style with stars gets this far, and `pairs` has no defined order, so
  -- two declarations reducing to one name are separated arbitrarily.
  for name, style in pairs stylesByName
    return name, style if getReachableStyleName(name) == resolvedStyleName
  return nil

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

-- `margin_b` is absent because Aegisub writes it out but never reads it back, and `extra` because it
-- is the one optional field, checked after these.
mandatoryDialogueFields = {
  {LineField.Comment, "boolean"}
  {LineField.Layer, "number"}
  {LineField.StartTime, "number"}
  {LineField.EndTime, "number"}
  {LineField.Style, "string"}
  {LineField.Actor, "string"}
  {LineField.MarginLeft, "number"}
  {LineField.MarginRight, "number"}
  {LineField.MarginTop, "number"}
  {LineField.Effect, "string"}
  {LineField.Text, "string"}
}

infoFields = {
  {LineField.Key, "string"}
  {LineField.Value, "string"}
}

fieldsByLineClass = {
  [LineClass.Info]: infoFields
  [LineClass.Style]: styleFields
  [LineClass.Dialogue]: mandatoryDialogueFields
}

---How strictly a field's value is held to the type its line class declares for it.
---@alias AssFieldTyping
---| 1 # Declared: the value has to be of the type its field declares
---| 2 # Coerced: a string field takes a number too and a number field a numeric string, as Aegisub reads them
FieldTyping = Enum "AssFieldTyping", {
  Declared: 1
  Coerced: 2
}

-- A value is held to its declared type by default. Aegisub reads every field through a check that
-- coerces, so a shim in its place accepts the wider set and converts what it reads.
acceptsByTyping = {
  [FieldTyping.Declared]: {
    string: (value) -> "string" == type value
    number: (value) -> "number" == type value
    boolean: (value) -> "boolean" == type value
  }
  [FieldTyping.Coerced]: {
    string: (value) -> "string" == type(value) or "number" == type value
    number: (value) -> nil != tonumber value
    boolean: (value) -> "boolean" == type value
  }
}

---A dialogue line, as `subtitles[i]` hands one over and as `subtitles[i] = line` takes one back.
---
---The two directions are not the same shape. A line coming out holds every field below; on the way
---back in Aegisub reads all of them except `margin_b`, and requires each one it reads to be present
---and of the right type.
---@class AegisubDialogueLine: AegisubLine
---@field class "dialogue"
---@field comment boolean Whether the line is a comment rather than a rendered event.
---@field layer integer Layer the line draws on, higher over lower.
---@field start_time integer Start, in milliseconds.
---@field end_time integer End, in milliseconds.
---@field style string Name of the style the line uses.
---@field actor string The event's `Name` field.
---@field effect string The Effect field. A `Banner` or `Scroll` value here moves the line as it renders.
---@field margin_l integer Left margin in pixels, or 0 to take the style's.
---@field margin_r integer Right margin in pixels, or 0 to take the style's.
---@field margin_t integer Vertical margin in pixels, or 0 to take the style's. Also the top margin where the two differ.
---@field margin_b integer Bottom margin. Written on the way out, ignored on the way in, and always equal to `margin_t`.
---@field text string The line's text, with its override blocks.
---@field extra? table<string, string> Extradata, keyed by name. A line read from `subtitles` always
---  states it. Aegisub before 3.5.0 crashes on a line built by hand without one, so state at least an
---  empty table for anything the automation API will see.

---One field a line does not hold in the type its class declares for it.
---@class AssLineFieldFault
---@field field string The field's name, as a line table keys it.
---@field kind "string"|"number"|"boolean" The type that field is declared as.

---Collects every field a line class declares that the table does not hold in an accepted type.
---@param line table The table to check.
---@param fields {[1]: string, [2]: string}[] The fields that class declares, and the type each wants.
---@param typing AssFieldTyping How strictly to hold a value to its declared type.
---@return AssLineFieldFault[]? faults In the order the fields are declared, nil where there are none.
findUnusableFields = (line, fields, typing) ->
  accepts = acceptsByTyping[typing]
  local faults
  for {field, kind} in *fields
    continue if accepts[kind] line[field]
    -- allocated on first fault, so a line with none costs nothing but the walk
    faults or= {}
    faults[#faults + 1] = {:field, :kind}
  faults

---Checks that a line declares a class and holds every field that class declares.
---@param line any The value to check.
---@param expectedClass? AssLineClass The class it has to be of, any declared one where absent.
---@param typing? AssFieldTyping How strictly to hold each value to its declared type, `Declared` by default.
---@return boolean? valid True where the line is valid, nil where it is not.
---@return string? err What is wrong with it, listing every offending field at once.
---@return AssLineFieldFault[]? faults The offending fields, for a caller reporting them its own way.
---  Absent where the line was refused for something other than its fields.
validateLine = (line, expectedClass, typing = FieldTyping.Declared) ->
  return nil, msgs.validateLine.notATable\format type line unless "table" == type line
  declared = line.class
  return nil, msgs.validateLine.noClassField unless "string" == type(declared) or "number" == type declared

  lineClass = tostring(declared)\lower!
  fields = fieldsByLineClass[lineClass]
  return nil, msgs.validateLine.unknownClass\format lineClass unless fields

  if expectedClass and expectedClass != lineClass
    return nil, msgs.validateLine.wrongClass\format expectedClass, lineClass

  if faults = findUnusableFields line, fields, typing
    named = [msgs.validateLine.badField\format fault.field, fault.kind for fault in *faults]
    return nil, msgs.validateLine.badFields\format(lineClass, table.concat named, ", "), faults

  -- Extradata is the one optional field, so it is checked apart from those a class always declares.
  extra = line[LineField.Extra]
  return nil, msgs.validateLine.extraNotATable\format type extra unless extra == nil or "table" == type extra

  return true

---The shapes Aegisub's automation API uses for subtitle lines, and the checks it applies to them.
---@class Ass
Ass = {
  LineClass: LineClass
  FontWeight: FontWeight
  LineField: LineField
  AlignmentSource: AlignmentSource
  styleFields: styleFields
  mandatoryDialogueFields: mandatoryDialogueFields

  ---Reads a legacy alignment number as the keypad number `\an` and a V4+ style write.
  ---@param legacy integer The number as it was written in an `\a` tag or an SSA V4 style.
  ---@param source AssAlignmentSource Where it was written, which decides what 4 and 8 draw as.
  ---@return integer? keypad 1 through 9, nil for a number outside 1 through 11. A `\a` holding one of
  ---  those leaves the style's own alignment standing; a style field holding one is drawn differently
  ---  by each renderer, so neither has a reading to report.
  getKeypadAlignment: (legacy, source) ->
    assert AlignmentSource\validate source, "source"
    keypadByLegacyAlignment[source][legacy]

  ---Determines the style a line is drawn in based on the line's style field and the script's style declarations:
  --- - Style name matching ignores leading whitespace and stars in the line's style field.
  --- - If the line's style is "Default" in any case (e.g. "default", "DEFAULT"), it *only* reaches the declaration written "Default".
  --- - If the normalized name doesn't match any of the declared styles, the style with the "Default" name is used.
  --- - If that also doesn't exist, the dialect-specific `fallbackStyle` is used.
  ---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, keyed as declared.
  ---@param lineStyleName? string The style name the line's style field holds.
  ---@param fallbackStyle? AegisubStyleLine The style to return where the script declares nothing the line
  ---  reaches, a style's own defaults where absent. Each renderer keeps one of its own and they part, so
  ---  pass the `fallbackStyle` of the dialect being read for to learn what that renderer would draw.
  ---@return AegisubStyleLine style Never nil, so a line always has values to be read against.
  ---@return string declaredStyleName The style's name as the script declares it, or `Default` where the
  ---  style is `fallbackStyle`. Write this into a document that names the style, not the name asked for.
  ---@return boolean declarationFound Whether the name found a declaration of its own, false where the
  ---  style returned is the fallback instead.
  resolveStyle: (stylesByName, lineStyleName, fallbackStyle = defaultStyle) ->
    return fallbackStyle, DEFAULT_STYLE_NAME, false unless stylesByName
    resolvedStyleName = "string" == type(lineStyleName) and getReachableStyleName(lineStyleName) or ""
    resolvedStyleName = DEFAULT_STYLE_NAME if resolvedStyleName\lower! == "default"
    declaredStyleName, style = findDeclaredStyle stylesByName, resolvedStyleName
    return style, declaredStyleName, true if style
    declaredStyleName, style = findDeclaredStyle stylesByName, DEFAULT_STYLE_NAME
    return style, declaredStyleName, false if style
    return fallbackStyle, DEFAULT_STYLE_NAME, false


  ---Reads the wrap style a script states in its Script Info, which decides whether `\n` breaks a line where
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

  :BorderStyle
  :ColorNotation
  :createStyle
  :DEFAULT_STYLE_NAME
  :sectionByClass
  :lineClassOrder
  :DEFAULT_WRAP_STYLE
  :defaultStyle
  :emitColor
  :FieldTyping
  :packStyleColor
  :parseColor
  :readColorLiteralDigits
  :splitStyleColor
  :validateLine
  :WrapStyle
}

return Ass
