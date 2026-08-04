-- The shapes Aegisub's automation API hands subtitle lines over in, and the checks it applies before
-- it will take one back. The fields, their defaults and the checks are transcribed from `AssEntryToLua`,
-- `LuaToAssEntry` and the AssStyle constructor in Aegisub's own source, so a table built or validated
-- here behaves the same way inside Aegisub as it does headlessly.

msgs = {
  validateStyle: {
    notAStyle: "Not a style entry"
    badField: "Invalid or missing field '%s' in 'style' class subtitle line (expected %s)"
  }
}

-- cspell:ignore HAABBGGRR -- the ASS color template, whose letters spell out its byte order
---A style line as Aegisub's automation API hands it over, from a subtitles object or to
---`aegisub.text_extents`. The fields mirror `AssEntryToLua` in Aegisub's `auto4_lua_assfile.cpp`,
---which is what builds the table, rather than the ASS file format's own field names.
---@class AegisubStyle
---@field class string Always "style" for this shape.
---@field section string Section the line sits in, nil for a line before the first section heading.
---@field raw string The line as it appears in the file, regenerated from the fields below when needed.
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
---@field borderstyle number 1 for an outline with a drop shadow, 3 for an opaque box.
---@field outline number Width of the outline.
---@field shadow number Distance between the shadow and the text.
---@field align number Alignment on the numeric keypad layout, 1 through 9.
---@field margin_l number Left margin, in pixels.
---@field margin_r number Right margin, in pixels.
---@field margin_t number Top margin, in pixels.
---@field margin_b number Bottom margin, in pixels. Aegisub fills it from the same value as `margin_t` and never reads it back, so the two always agree however the file was written.
---@field encoding number Font encoding, from the Windows character set constants that `GdiCharSet` names.
---@field relative_to number What the margins are measured against; Aegisub reports 2 for every style.

-- What a style starts out as, taken from the member initializers on Aegisub's AssStyle and the margin
-- its constructor fills in. The colors are those defaults written the way Aegisub reports them.
DEFAULT_STYLE = {
  class: "style"
  section: "[V4+ Styles]"
  name: "Default"
  fontname: "Arial"
  fontsize: 48
  color1: "&H00FFFFFF&"
  color2: "&H000000FF&"
  color3: "&H00000000&"
  color4: "&H00000000&"
  bold: false
  italic: false
  underline: false
  strikeout: false
  scale_x: 100
  scale_y: 100
  spacing: 0
  angle: 0
  borderstyle: 1
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
STYLE_FIELDS = {
  {"name", "string"}
  {"fontname", "string"}
  {"fontsize", "number"}
  {"color1", "string"}
  {"color2", "string"}
  {"color3", "string"}
  {"color4", "string"}
  {"bold", "boolean"}
  {"italic", "boolean"}
  {"underline", "boolean"}
  {"strikeout", "boolean"}
  {"scale_x", "number"}
  {"scale_y", "number"}
  {"spacing", "number"}
  {"angle", "number"}
  {"borderstyle", "number"}
  {"outline", "number"}
  {"shadow", "number"}
  {"align", "number"}
  {"margin_l", "number"}
  {"margin_r", "number"}
  {"margin_t", "number"}
  {"encoding", "number"}
}

---The shapes Aegisub's automation API carries subtitle lines in, and the checks it applies to them.
---@class Ass
---@field DEFAULT_STYLE AegisubStyle The values a style starts out as, as Aegisub's AssStyle does. Read-only; copy it with `createStyle` rather than mutating it.
Ass = {
  DEFAULT_STYLE: DEFAULT_STYLE

  ---Builds a complete style table, so it passes the checks Aegisub applies before it will measure or
  ---commit one. Handy for a test wanting a valid style it can vary one field of, and for code building
  ---styles to write into a file.
  ---@param overrides? table<string, any> Fields to set instead of the default the same key carries.
  ---@return AegisubStyle style A fresh table, sharing nothing with the defaults or with `overrides`.
  createStyle: (overrides) ->
    style = {key, value for key, value in pairs DEFAULT_STYLE}
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
    return nil, msgs.validateStyle.notAStyle unless "style" == tostring(style.class)\lower!

    for {field, kind} in *STYLE_FIELDS
      value = style[field]
      accepted = switch kind
        when "string" then "string" == type(value) or "number" == type value
        when "number" then nil != tonumber value
        when "boolean" then "boolean" == type value
      return nil, msgs.validateStyle.badField\format field, kind unless accepted

    return true
}

return Ass
