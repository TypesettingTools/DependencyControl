-- cspell:ignore Colour -- the format's own field names, matched verbatim against a `Format:` line
-- cspell:ignore HAABBGGRR -- the ASS color template
--
-- Every method that adds, removes or replaces a line has to update `lines`, `entries` and
-- `__entryByLine` together. `emit` walks `entries`, while the line methods find a line's entry through
-- `__entryByLine`.

ffi = require "ffi"
Accessors = require "l0.DependencyControl.Accessors"
Enum = require "l0.DependencyControl.Enum"
Unicode = require "l0.DependencyControl.unicode"
AegisubSubtitles = require "l0.AssParser.AegisubSubtitles"
Ass = require "l0.AssParser.ass"
Scanner = require "l0.AssParser.Scanner"
{:TagName, :TokenKind, :dialects} = require "l0.AssParser.dialects"

LineClass = Ass.LineClass
LineField = Ass.LineField

msgs = {
  parse: {
    notText: "Expected the script's text as a string, got a %s."
  }
  fromSubtitles: {
    notSubtitles: "Expected a subtitles object, got a %s."
  }
  writeFile: {
    openFailed: "Could not open '%s' for writing: %s"
    writeFailed: "Could not write '%s': %s"
  }
  fromFile: {
    openFailed: "Could not open '%s': %s"
  }
  line: {
    notATable: "A subtitle line has to be a table, not a %s."
    outOfRange: "Out of range line index: %s."
  }
}

Encoding = Unicode.Encoding

---The kind of line an entry represents. Only `Line` entries are added to `lines`, since Aegisub's
---automation API has no representation for the others.
---@alias AssFileEntryKind string
---| "line" # Line: a dialogue, style or info line, parsed into the Aegisub shape
---| "section" # Section: a bracketed section heading
---| "format" # Format: a section's `Format:` line, listing the fields of the section's lines in order
---| "other" # Other: a blank line, a comment, or any other line the parser does not recognize
EntryKind = Enum "AssFileEntryKind", {
  Line: "line"
  Section: "section"
  Format: "format"
  Other: "other"
}

---The key at the start of a `Format:`, style or event line, which determines how the parser reads the
---rest of the line. A Script Info line starts with the name of its setting instead.
---@alias AssFileLinePrefix string
---| "Format" # Format: lists the fields of its section's lines in order
---| "Style" # Style: a style definition
---| "Dialogue" # Dialogue: an event that is rendered
---| "Comment" # Comment: an event that is not rendered, otherwise written like a dialogue line
LinePrefix = Enum "AssFileLinePrefix", {
  Format: "Format"
  Style: "Style"
  Dialogue: "Dialogue"
  Comment: "Comment"
}

-- Matches a key and its value, the form Script Info settings share with `Format`, `Style`, `Dialogue`
-- and `Comment` lines.
INFO_PATTERN = "^(%a[%w_ ]-)%s*:%s*(.*)$"

DEFAULT_EOL = "\r\n"
EVENTS_SECTION = "[Events]"
SCRIPT_INFO_SECTION = "[Script Info]"
STYLES_SECTION = "[V4+ Styles]"

-- Maps each field name a V4+ `Format:` line can list to the key Aegisub reports the field under.
styleFieldByFormatName = {
  Name: LineField.Name
  Fontname: LineField.FontName
  Fontsize: LineField.FontSize
  PrimaryColour: LineField.PrimaryColor
  SecondaryColour: LineField.SecondaryColor
  OutlineColour: LineField.OutlineColor
  BackColour: LineField.BackColor
  Bold: LineField.Bold
  Italic: LineField.Italic
  Underline: LineField.Underline
  StrikeOut: LineField.StrikeOut
  ScaleX: LineField.ScaleX
  ScaleY: LineField.ScaleY
  Spacing: LineField.Spacing
  Angle: LineField.Angle
  BorderStyle: LineField.BorderStyle
  Outline: LineField.Outline
  Shadow: LineField.Shadow
  Alignment: LineField.Alignment
  MarginL: LineField.MarginLeft
  MarginR: LineField.MarginRight
  MarginV: LineField.MarginTop
  Encoding: LineField.Encoding
}

eventFieldByFormatName = {
  Layer: LineField.Layer
  Start: LineField.StartTime
  End: LineField.EndTime
  Style: LineField.Style
  Name: LineField.Actor
  MarginL: LineField.MarginLeft
  MarginR: LineField.MarginRight
  MarginV: LineField.MarginTop
  Effect: LineField.Effect
  Text: LineField.Text
}

-- The V4+ field order, used for a section without a `Format:` line and written into every section the
-- script creates.
defaultStyleFormat = {
  "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "OutlineColour", "BackColour"
  "Bold", "Italic", "Underline", "StrikeOut", "ScaleX", "ScaleY", "Spacing", "Angle", "BorderStyle"
  "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV", "Encoding"
}

defaultEventFormat = {
  "Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"
}

-- Each line class's position in Aegisub's group order, used to place a new section and to check whether
-- `lines` is already in that order.
classRank = {name, index for index, name in ipairs Ass.lineClassOrder}

-- a scanner per dialect, created the first time a `\r` tag has to be read
local resetScanners

---Returns the key a style name is matched by: the name lowercased, without leading stars or surrounding
---whitespace. This ignores at least as much as any renderer's own style matching, so two names a
---renderer treats as the same style always get the same key.
---@param name string A style's name, or a style name from a line's style field or a `\r` tag.
---@return string key The normalized name.
getStyleKey = (name) -> name\match("^[%s%*]*(.-)%s*$")\lower!

---Adds the key of the style every `\r` tag in a text resets to, scanning the text as each dialect
---reads it.
---@param text string A dialogue line's text.
---@param keys table<string, true> The set of keys to add to.
addResetStyleKeys = (text, keys) ->
  return unless text\find "\\r", 1, true
  resetScanners or= [Scanner name for name in pairs dialects]
  visit = (tokens) ->
    for token in *tokens
      isReset = token.kind == TokenKind.Tag and token.name == TagName.Reset
      name = isReset and token.arguments and token.arguments[1]
      keys[getStyleKey name] = true if "string" == type name
      visit token.children if token.children
  visit scanner\scan text for scanner in *resetScanners

---Checks whether xy-VSFilter reads a line of the file as a dialogue line. It recognizes one by its
---`Dialogue` key alone, in any section and in any letter case.
---@param text string The line's text.
---@return boolean isDialogue True if xy-VSFilter renders the line as an event.
isReadAsDialogueByVsfilter = (text) ->
  -- Only the section part is observed: xy-VSFilter's unknown-style dialog showed the style of a line
  -- under `[Script Info]`. That it ignores letter case and whitespace is taken from its source.
  key = text\match "^%s*([^:]-)%s*:"
  key != nil and key\lower! == "dialogue"

SSA_STYLES_SECTION = "[V4 Styles]"
SSA_ALPHA_FORMAT_NAME = "AlphaLevel"
-- An SSA style sets one alpha for all its colors, but both renderers use this alpha for the back color
-- whatever the style sets. libass marks this as VSFilter compatibility.
SSA_BACK_ALPHA = 0x80

---Returns a style color with its alpha replaced.
---@param text string A color value from a style field.
---@param alpha integer The alpha byte to set.
---@return string color The color in `&HAABBGGRR&` notation.
withAlpha = (text, alpha) ->
  color = Ass.splitStyleColor Ass.parseColor text or ""
  return Ass.emitColor Ass.packStyleColor(color, alpha), Ass.ColorNotation.ColorAndAlpha

---Converts a style read from an SSA script into its V4+ equivalent, in place. The six V4+ fields SSA
---lacks get the renderers' defaults, and the alignment is converted to a keypad number. `TertiaryColour`
---is discarded, since SSA draws the outline in the back color, and `AlphaLevel` becomes the alpha of the
---other three colors.
---@param style AegisubStyleLine The style to convert.
---@param alphaLevel? number The style's `AlphaLevel` value, if its section's format has that field.
applySsaStyleDefaults = (style, alphaLevel) ->
  style.scale_x = 100 if style.scale_x == nil
  style.scale_y = 100 if style.scale_y == nil
  style.spacing = 0 if style.spacing == nil
  style.angle = 0 if style.angle == nil
  style.underline = false if style.underline == nil
  style.strikeout = false if style.strikeout == nil

  -- Renderers disagree on alignment numbers outside SSA's range of 1 to 11, so those stay unconverted.
  if style.align
    style.align = Ass.getKeypadAlignment(style.align, Ass.AlignmentSource.StyleField) or style.align

  style.color3 = style.color4

  return unless alphaLevel
  front = math.max 0, math.min alphaLevel, 0xFF
  style.color1 = withAlpha style.color1, front
  style.color2 = withAlpha style.color2, front
  style.color3 = withAlpha style.color3, front
  style.color4 = withAlpha style.color4, SSA_BACK_ALPHA

booleanStyleFields = {field, true for {field, kind} in *Ass.styleFields when kind == "boolean"}
numericStyleFields = {field, true for {field, kind} in *Ass.styleFields when kind == "number"}

---Parses an `H:MM:SS.CC` timestamp into milliseconds.
---@param text string A timestamp field's text.
---@return integer? milliseconds Nil if the text is not a timestamp.
parseTime = (text) ->
  hours, minutes, seconds, centiseconds = text\match "^%s*(%d+):(%d+):(%d+)%.(%d+)%s*$"
  return nil unless hours
  -- the digits after the point are a decimal fraction of a second, however many there are
  fraction = tonumber("0." .. centiseconds) or 0
  return (tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)) * 1000 + math.floor fraction * 1000 + 0.5

---Formats a time as an `H:MM:SS.CC` timestamp, dropping anything below a hundredth of a second.
---@param milliseconds integer The time to format.
---@return string text The timestamp. A negative time is written as zero.
emitTime = (milliseconds) ->
  total = math.max 0, math.floor milliseconds
  centiseconds = math.floor total / 10 % 100
  seconds = math.floor(total / 1000) % 60
  minutes = math.floor(total / 60000) % 60
  hours = math.floor total / 3600000
  return "%d:%02d:%02d.%02d"\format hours, minutes, seconds, centiseconds

---Splits a style or event line's values on commas into at most the given number of fields. The last
---field gets the rest of the line, commas included.
---@param text string The line's text after its key and colon.
---@param count integer The number of fields in the section's format.
---@return string[] values The field texts in order, fewer than `count` if the line has fewer commas.
splitFields = (text, count) ->
  values = {}
  position = 1
  while #values < count - 1
    comma = text\find ",", position, true
    break unless comma
    values[#values + 1] = text\sub position, comma - 1
    position = comma + 1
  values[#values + 1] = text\sub position
  return values

---Parses the field names of a `Format:` line.
---@param text string The line's text after `Format:`.
---@return string[] names The names in order, with surrounding whitespace trimmed.
parseFormat = (text) ->
  names = {}
  for name in text\gmatch "[^,]+"
    names[#names + 1] = name\match "^%s*(.-)%s*$"
  return names

---Converts a style field's text into the value Aegisub reports for the field.
---@param field string The Aegisub key the field is reported under.
---@param text string The field's text.
---@return boolean|number|string value A boolean for a switch, a number for a numeric field, and the
---  trimmed text otherwise. Text that is not a number reads as zero in a numeric field.
readStyleValue = (field, text) ->
  return text\match("^%s*(.-)%s*$") != "0" if booleanStyleFields[field]
  return tonumber(text) or 0 if numericStyleFields[field]
  return text\match "^%s*(.-)%s*$"

---Converts an event field's text into the value Aegisub reports for the field.
---@param field string The Aegisub key the field is reported under.
---@param text string The field's text.
---@return integer|string value Milliseconds for a timestamp, an integer for a layer or margin, and the
---  trimmed text otherwise. The `text` field is returned untrimmed, since its whitespace is rendered.
readEventValue = (field, text) ->
  switch field
    when LineField.StartTime, LineField.EndTime then parseTime(text) or 0
    when LineField.Layer, LineField.MarginLeft, LineField.MarginRight, LineField.MarginTop then math.floor tonumber(text) or 0
    when LineField.Text then text
    else text\match "^%s*(.-)%s*$"

---Serializes a line from its fields in the given field order, ignoring its `raw`.
---@param line AegisubLine The line to serialize.
---@param format? string[] The field names of the line's section in order, V4+ order by default.
---@return string? text The line as a file holds it, without a line ending. Nil for an unknown class.
serializeLine = (line, format) ->
  switch line.class
    when LineClass.Info
      "%s: %s"\format line.key, line.value

    when LineClass.Style
      values = for name in *format or defaultStyleFormat
        field = styleFieldByFormatName[name]
        value = field and line[field]
        if booleanStyleFields[field]
          value and "-1" or "0"
        elseif value == nil
          ""
        else tostring value
      "Style: %s"\format table.concat values, ","

    when LineClass.Dialogue
      values = for name in *format or defaultEventFormat
        field = eventFieldByFormatName[name]
        value = field and line[field]
        switch field
          when LineField.StartTime, LineField.EndTime then emitTime value or 0
          else value == nil and "" or tostring value
      "%s: %s"\format line.comment and LinePrefix.Comment or LinePrefix.Dialogue, table.concat values, ","

---Serializes an entry, reusing the original text of every field whose value has not changed. This
---preserves how the file wrote each value, such as a margin written `0000`, a font size written `48.0`
---or a time with more digits than hundredths. Only the fields whose value changed are serialized afresh.
---@param entry AssFileEntry The entry to serialize. One without a parsed line is returned as its `raw`.
---@param format? string[] The field names of the entry's section in order, V4+ order by default.
---@return string text The entry as a line of the file, without its line ending.
serializeEntry = (entry, format) ->
  line = entry.line
  return entry.raw unless line

  if line.class == LineClass.Info
    return "%s: %s"\format line.key, line.value unless entry.raw
    key, value = entry.raw\match INFO_PATTERN
    return key == line.key and value == line.value and entry.raw or
      "%s: %s"\format line.key, line.value

  return serializeLine line, format unless entry.values

  isStyle = line.class == LineClass.Style
  names = format or (isStyle and defaultStyleFormat or defaultEventFormat)
  read = isStyle and readStyleValue or readEventValue

  values = for index, name in ipairs names
    field = isStyle and styleFieldByFormatName[name] or eventFieldByFormatName[name]
    written = entry.values[index]
    if not field or written == nil
      written or ""
    elseif read(field, written) == line[field]
      written
    elseif field == LineField.StartTime or field == LineField.EndTime
      emitTime line[field] or 0
    elseif booleanStyleFields[field] and isStyle
      line[field] and "-1" or "0"
    else tostring line[field]

  return "%s: %s"\format entry.prefix, table.concat values, ","

---A line of the file, of any kind.
---@class AssFileEntry
---@field kind AssFileEntryKind The kind of line.
---@field raw? string The line's text as read, without its line ending. Absent for a line added or
---  replaced through the script, which `emit` then serializes from its fields.
---@field eol string The line ending that followed the line, empty for a last line without one.
---@field line? AegisubLine The parsed line, present only when `kind` is `"line"`.
---@field values? string[] The field texts of a style or event line as read. A field whose value has not
---  changed is written back from this text rather than serialized afresh.
---@field prefix? string The key a style or event line was read with, such as `Comment`.
---@field fields? string[] The field names of a `Format:` line, present only when `kind` is `"format"`.

---An ASS subtitle script, holding every line of its file along with the dialogue, style and info lines
---parsed into the shape Aegisub's automation API uses. Create one with `fromFile` or `parse`, or with
---`fromSubtitles` from the subtitles object Aegisub passes to a macro.
---@class AssScript
---@field entries AssFileEntry[] Every line of the file in order, including section headings, `Format:`
---  lines, blank lines and comments.
---@field lines AegisubLine[] The parsed dialogue, style and info lines, in file order. Editing one of
---  these tables edits the script, but `emit` goes on writing the entry's `raw` until it is cleared.
---  Editing through `subtitles` clears it.
---@field styleFormat string[] The field names of the styles section's `Format:` line, in order.
---@field eventFormat string[] The field names of the events section's `Format:` line, in order.
---@field eol string The file's most common line ending, used for lines added to the script.
---@field encoding? UnicodeEncoding The encoding the file was read in, which `emit` writes by default.
---  Absent for a script parsed from text.
---@field subtitles AegisubSubtitles The script's lines behind Aegisub's subtitle file interface, as a
---  macro receives them. Each read of this field creates a new object over `lines`, so an edit made
---  through either one shows in both. Read-only.
class AssScript
  @Encoding = Encoding
  @EntryKind = EntryKind
  @LineField = LineField
  @LinePrefix = LinePrefix
  @parseTime = parseTime
  @emitTime = emitTime
  @serializeLine = serializeLine
  @serializeEntry = serializeEntry

  ---Decodes a file's bytes into UTF-8 text, transcoding UTF-16 and stripping any byte-order mark. Bytes
  ---without a mark are returned unchanged, so a script in a legacy 8-bit encoding keeps its bytes.
  ---@param bytes string The file's contents, read in binary mode.
  ---@return string text The decoded text.
  ---@return UnicodeEncoding encoding The encoding the byte-order mark indicates, `Utf8` for no mark.
  @decode = (bytes) -> Unicode.decodeToUtf8 bytes

  ---Parses a script's text. Dialogue, style and info lines are parsed into the shape Aegisub's
  ---automation API uses, and every line is kept as an entry.
  ---@param text string The script's decoded text.
  ---@return AssScript? script Nil if the text is not a string.
  ---@return string? err The reason no script was returned.
  @parse = (text) ->
    return nil, msgs.parse.notText\format type text unless "string" == type text

    entries, lines = {}, {}
    section = ""
    styleFormat, eventFormat = defaultStyleFormat, defaultEventFormat
    crlfCount, lfCount = 0, 0

    position = 1
    while position <= #text
      breakAt = text\find "\n", position, true
      raw = breakAt and text\sub(position, breakAt - 1) or text\sub position
      eol = breakAt and "\n" or ""
      if raw\sub(-1) == "\r"
        raw = raw\sub 1, -2
        eol = "\r\n"
      if eol == "\r\n" then crlfCount += 1 elseif eol == "\n" then lfCount += 1
      position = breakAt and breakAt + 1 or #text + 1

      entry = {kind: EntryKind.Other, :raw, :eol}
      heading = raw\match "^%s*(%[.*%])%s*$"
      key, value = raw\match INFO_PATTERN

      if heading
        section = heading
        entry.kind = EntryKind.Section

      elseif key == LinePrefix.Format and section != SCRIPT_INFO_SECTION
        entry.kind = EntryKind.Format
        entry.fields = parseFormat value
        if section == EVENTS_SECTION then eventFormat = entry.fields else styleFormat = entry.fields

      elseif key == LinePrefix.Style and section != EVENTS_SECTION
        line = {class: LineClass.Style, section: STYLES_SECTION, :raw}
        values = splitFields value, #styleFormat
        alphaLevel = nil
        for index, name in ipairs styleFormat
          alphaLevel = tonumber(values[index]) if name == SSA_ALPHA_FORMAT_NAME
          field = styleFieldByFormatName[name]
          continue unless field
          line[field] = readStyleValue field, values[index] or ""
        applySsaStyleDefaults line, alphaLevel if section == SSA_STYLES_SECTION
        line.margin_b = line.margin_t
        line.relative_to = 2
        entry.kind, entry.line, entry.values, entry.prefix = EntryKind.Line, line, values, key
        lines[#lines + 1] = line

      elseif (key == LinePrefix.Dialogue or key == LinePrefix.Comment) and section == EVENTS_SECTION
        line = {class: LineClass.Dialogue, section: EVENTS_SECTION, :raw, comment: key == LinePrefix.Comment}
        values = splitFields value, #eventFormat
        for index, name in ipairs eventFormat
          field = eventFieldByFormatName[name]
          continue unless field
          line[field] = readEventValue field, values[index] or ""
        line.margin_b = line.margin_t
        entry.kind, entry.line, entry.values, entry.prefix = EntryKind.Line, line, values, key
        lines[#lines + 1] = line

      elseif key and section == SCRIPT_INFO_SECTION
        line = {class: LineClass.Info, section: SCRIPT_INFO_SECTION, :raw, :key, :value}
        entry.kind, entry.line = EntryKind.Line, line
        lines[#lines + 1] = line

      entries[#entries + 1] = entry

    AssScript {:entries, :lines, :styleFormat, :eventFormat, eol: lfCount > crlfCount and "\n" or DEFAULT_EOL}

  ---Reads and parses a script file. The file is read in binary mode, so its line endings are kept.
  ---@param path string The file's path.
  ---@return AssScript? script Nil if the file could not be read or parsed. The encoding it was read in
  ---  is on the script's `encoding` field.
  ---@return string? err The reason no script was returned.
  @fromFile = (path) ->
    handle, err = io.open path, "rb"
    return nil, msgs.fromFile.openFailed\format path, tostring err unless handle
    bytes = handle\read "*a"
    handle\close!
    text, encoding = Unicode.decodeToUtf8 bytes
    script, parseErr = AssScript.parse text
    return nil, parseErr unless script
    script.encoding = encoding
    return script

  ---Creates a script from the subtitles object Aegisub passes to a macro, or from any object implementing
  ---that interface. The script is laid out as Aegisub saves a file: a section per line class under
  ---Aegisub's heading, `Format:` lines in V4+ order, the platform's line ending, and UTF-8 with a
  ---byte-order mark. The interface exposes no comments, blank lines or unknown sections, so the script
  ---has none.
  ---@param subtitles AegisubSubtitles The subtitles object to read.
  ---@return AssScript script A new script holding copies of the lines.
  @fromSubtitles = (subtitles) ->
    error msgs.fromSubtitles.notSubtitles\format(type subtitles), 2 unless "table" == type(subtitles) or "userdata" == type(subtitles)

    byClass = {}
    byClass[name] = {} for name in *Ass.lineClassOrder
    for index = 1, #subtitles
      line = subtitles[index]
      bucket = byClass[line.class]
      bucket[#bucket + 1] = line if bucket

    eol = ffi.os == "Windows" and "\r\n" or "\n"
    entries, lines = {}, {}
    add = (entry) -> entries[#entries + 1] = entry
    for name in *Ass.lineClassOrder
      held = byClass[name]
      continue if #held == 0
      add {kind: EntryKind.Other, raw: "", :eol} if #entries > 0
      add {kind: EntryKind.Section, raw: Ass.sectionByClass[name], :eol}
      format = if name == LineClass.Style then defaultStyleFormat
      elseif name == LineClass.Dialogue then defaultEventFormat
      add {kind: EntryKind.Format, raw: "Format: " .. table.concat(format, ", "), :eol, fields: format} if format
      for line in *held
        stored = {key, value for key, value in pairs line}
        stored.section = Ass.sectionByClass[name]
        lines[#lines + 1] = stored
        add {kind: EntryKind.Line, raw: line.raw, :eol, line: stored}

    AssScript {:entries, :lines, :eol, encoding: Encoding.Utf8Bom}

  ---@param fields {entries?: AssFileEntry[], lines?: AegisubLine[], styleFormat?: string[], eventFormat?: string[], eol?: string, encoding?: UnicodeEncoding}
  ---  The script's contents, as `parse` and `fromSubtitles` build them. An absent field starts out empty
  ---  or at its default.
  new: (fields = {}) =>
    {:entries, :lines, :styleFormat, :eventFormat, :eol, :encoding} = fields
    @entries = entries or {}
    @lines = lines or {}
    @styleFormat = styleFormat or defaultStyleFormat
    @eventFormat = eventFormat or defaultEventFormat
    @eol = eol or DEFAULT_EOL
    @encoding = encoding
    @__entryByLine = {}
    @__entryByLine[entry.line] = entry for entry in *@entries when entry.line
    @__grouped = @__isGrouped!

  subtitles: Accessors.property get: => AegisubSubtitles @

  ---Serializes the script. An unchanged script is reproduced byte for byte, and an entry whose `raw` was
  ---cleared is serialized from its fields.
  ---
  ---With a line filter, only the dialogue lines the filter accepts are written, along with the styles
  ---those lines use. A style is kept where a kept line's style field or one of its `\r` tags reaches it,
  ---ignoring case, leading stars and surrounding whitespace. `Default` is kept as well where a kept
  ---line's style field reaches no style. Lines xy-VSFilter reads as dialogue but the parser does
  ---not, such as a `Dialogue:` line under `[Script Info]`, are dropped. All other entries are written
  ---unchanged.
  ---@param lineFilter? fun(line: AegisubDialogueLine, index: integer): boolean Called for each dialogue
  ---  line in file order, commented ones included, with the line and its index in `lines`. Return true to
  ---  keep the line. Without a filter, every line is kept.
  ---@param encoding? UnicodeEncoding The encoding to write, the script's own by default.
  ---@return string bytes The file's contents in the given encoding, including its byte-order mark if the
  ---  encoding has one.
  emit: (lineFilter, encoding = @encoding) =>
    selection = lineFilter and @__selectLines lineFilter
    parts = {}
    for entry in *@entries
      line = entry.line
      isDialogue = line != nil and line.class == LineClass.Dialogue
      if selection and line
        continue if isDialogue and not selection.lines[line]
        continue if line.class == LineClass.Style and not selection.styleKeys[getStyleKey line.name]
      written = entry.raw or line and serializeEntry(entry, @__formatFor line) or ""
      continue if selection and not isDialogue and isReadAsDialogueByVsfilter written
      parts[#parts + 1] = written .. entry.eol
    return Unicode.encodeFromUtf8 table.concat(parts), encoding

  ---Writes the script to a file. The file is opened in binary mode, so the script's line endings are
  ---written unchanged.
  ---@param path string The file's path.
  ---@param encoding? UnicodeEncoding The encoding to write, the script's own by default.
  ---@return boolean? written True on success, nil where the file could not be opened or written.
  ---@return string? err Why it failed.
  writeFile: (path, encoding) =>
    handle, err = io.open path, "wb"
    return nil, msgs.writeFile.openFailed\format path, tostring err unless handle
    written, writeErr = handle\write @emit nil, encoding
    handle\close!
    return nil, msgs.writeFile.writeFailed\format path, tostring writeErr unless written
    true

  ---Computes the order Aegisub presents the lines in, grouped by class.
  ---@return integer[]? order Indices into `lines` in that order. Nil if `lines` is already in that
  ---  order, as it is for every well-formed file.
  getGroupOrder: =>
    return nil if @__grouped
    byClass = {}
    byClass[name] = {} for name in *Ass.lineClassOrder
    for index, line in ipairs @lines
      bucket = byClass[line.class]
      bucket[#bucket + 1] = index if bucket
    order = {}
    for name in *Ass.lineClassOrder
      order[#order + 1] = index for index in *byClass[name]
    order

  ---Serializes the line at the given index the way `emit` would write it.
  ---@param index integer An index into `lines`.
  ---@return string text The line without its line ending.
  serializeLineAt: (index) =>
    line = @lines[index]
    entry = @__entryByLine[line]
    entry.raw or serializeEntry entry, @__formatFor line

  ---Adds a copy of a line after the last line of its class, creating a section for the class if the
  ---script has none. Throws if a field the class requires is missing or has the wrong type, as Aegisub
  ---does.
  ---@param line AegisubLine The line to add.
  addLine: (line) =>
    line = @__prepareLine line
    lastOfClass = nil
    lastOfClass = index for index, held in ipairs @lines when held.class == line.class
    if lastOfClass
      after = @__positionOfEntry @__entryByLine[@lines[lastOfClass]]
      @__insertLine lastOfClass + 1, line, after + 1
      return

    -- The new section goes before the first section of a class that comes later in Aegisub's order, or
    -- at the end of the file if there is no such section.
    rank = classRank[line.class]
    firstLater = nil
    for index, held in ipairs @lines
      if (classRank[held.class] or 0) > rank
        firstLater = index
        break

    format = @__formatFor line
    heading = {kind: EntryKind.Section, raw: Ass.sectionByClass[line.class], eol: @eol}
    formatEntry = format and {kind: EntryKind.Format, raw: "Format: " .. table.concat(format, ", "), eol: @eol, fields: format}

    if firstLater
      -- before that section's heading, or before its first line if it has no heading
      position = @__positionOfEntry @__entryByLine[@lines[firstLater]]
      for at = position - 1, 1, -1
        continue unless @entries[at].kind == EntryKind.Section
        position = at
        break
      block = {heading, formatEntry, @__entryFor(line), {kind: EntryKind.Other, raw: "", eol: @eol}}
      @__insertEntries position, block
      table.insert @lines, firstLater, line
    else
      @__endLineAt #@entries
      block = {{kind: EntryKind.Other, raw: "", eol: @eol}, heading, formatEntry, @__entryFor line}
      @__insertEntries #@entries + 1, block
      @lines[#@lines + 1] = line

  ---Inserts a copy of a line before the line at the given index of `lines`. An index one past the last
  ---line adds it after the last line of its class instead, as Aegisub's `insert` does. Throws on an
  ---index out of range or an invalid line.
  ---@param index integer An index into `lines`, from 1 to one past the last line.
  ---@param line AegisubLine The line to insert.
  insertLineBefore: (index, line) =>
    inRange = "number" == type(index) and index >= 1 and index <= #@lines + 1
    error msgs.line.outOfRange\format(tostring index), 2 unless inRange
    return @addLine line if index == #@lines + 1
    line = @__prepareLine line
    at = @__positionOfEntry @__entryByLine[@lines[index]]
    @__insertLine index, line, at
    @__grouped = @__isGrouped! if @__grouped

  ---Removes the line at the given index of `lines` from the script. Throws on an index out of range.
  ---@param index integer An index into `lines`.
  removeLineAt: (index) =>
    inRange = "number" == type(index) and index >= 1 and index <= #@lines
    error msgs.line.outOfRange\format(tostring index), 2 unless inRange
    line = table.remove @lines, index
    entry = @__entryByLine[line]
    @__entryByLine[line] = nil
    table.remove @entries, @__positionOfEntry entry
    @__grouped = @__isGrouped! unless @__grouped

  ---Replaces the line at the given index of `lines` with a copy of the given line. The old line's text as
  ---read is discarded, so `emit` serializes the new line from its fields. Throws on an index out of range
  ---or an invalid line.
  ---@param index integer An index into `lines`.
  ---@param line AegisubLine The replacement line.
  replaceLineAt: (index, line) =>
    inRange = "number" == type(index) and index >= 1 and index <= #@lines
    error msgs.line.outOfRange\format(tostring index), 2 unless inRange
    line = @__prepareLine line
    old = @lines[index]
    entry = @__entryByLine[old]
    @__entryByLine[old] = nil
    @lines[index] = line
    entry.line, entry.raw, entry.values, entry.prefix = line, nil, nil, nil
    @__entryByLine[line] = entry
    @__grouped = @__isGrouped! if old.class != line.class

  ---Runs a line filter over the dialogue lines, collecting the lines it keeps and the key of every style
  ---those lines use.
  ---@private
  ---@param lineFilter fun(line: AegisubDialogueLine, index: integer): boolean The filter `emit` was given.
  ---@return {lines: table<AegisubDialogueLine, true>, styleKeys: table<string, true>} selection The kept
  ---  lines and their style keys, both as sets.
  __selectLines: (lineFilter) =>
    stylesByName = {line.name, line for line in *@lines when line.class == LineClass.Style}
    lines, styleKeys = {}, {}
    for index, line in ipairs @lines
      continue unless line.class == LineClass.Dialogue and lineFilter line, index
      lines[line] = true
      styleName = "string" == type(line.style) and line.style or ""
      styleKeys[getStyleKey styleName] = true
      _, _, declarationFound = Ass.resolveStyle stylesByName, styleName
      styleKeys[getStyleKey Ass.DEFAULT_STYLE_NAME] = true unless declarationFound
      addResetStyleKeys line.text, styleKeys if "string" == type line.text
    {:lines, :styleKeys}

  ---Checks whether `lines` is in Aegisub's group order.
  ---@private
  ---@return boolean grouped True if no line comes before a line of a class earlier in that order.
  __isGrouped: =>
    highest = 0
    for line in *@lines
      rank = classRank[line.class] or 0
      return false if rank < highest
      highest = rank
    true

  ---Returns the field names of a line's section.
  ---@private
  ---@param line AegisubLine The line whose section to look up.
  ---@return string[]? format The field names in order. Nil for an info line.
  __formatFor: (line) =>
    switch line.class
      when LineClass.Style then @styleFormat
      when LineClass.Dialogue then @eventFormat

  ---Copies and validates a line for storing in the script, the way Aegisub validates a line it is
  ---given. Throws if the line is not a table, or a field is missing or has the wrong type.
  ---@private
  ---@param line AegisubLine The line to copy.
  ---@return AegisubLine copy The validated copy.
  __prepareLine: (line) =>
    error msgs.line.notATable\format(type line), 3 unless "table" == type line
    copy = {key, value for key, value in pairs line}
    copy.class = tostring(copy.class)\lower! if copy.class != nil
    -- Aegisub reports these two fields on every line, but ignores them on a line it is given
    copy.margin_b = copy.margin_t if copy.margin_t != nil
    copy.relative_to = 2 if copy.class == LineClass.Style
    valid, err = Ass.validateLine copy, nil, Ass.FieldTyping.Coerced
    error err, 0 unless valid
    copy.section = Ass.sectionByClass[copy.class]
    copy.raw = nil
    copy

  ---Creates the entry for a line added to the script.
  ---@private
  ---@param line AegisubLine A line returned by `__prepareLine`.
  ---@return AssFileEntry entry An entry without `raw`, so `emit` serializes the line from its fields.
  __entryFor: (line) => {kind: EntryKind.Line, eol: @eol, :line}

  ---Finds an entry's index in `entries`.
  ---@private
  ---@param entry AssFileEntry The entry to find.
  ---@return integer? position The entry's index, nil if it is not in `entries`.
  __positionOfEntry: (entry) =>
    return index for index, held in ipairs @entries when held == entry

  ---Adds a line ending to the entry at the given position if it has none, so a line inserted after it
  ---starts on a line of its own. Only the last line of a file can lack a line ending.
  ---@private
  ---@param position integer An index into `entries`.
  __endLineAt: (position) =>
    held = @entries[position]
    held.eol = @eol if held and held.eol == ""

  ---Inserts entries into `entries` at the given position, adding a line ending to the entry before them
  ---if it lacks one.
  ---@private
  ---@param position integer The index the first entry is inserted at.
  ---@param block (AssFileEntry|false)[] The entries to insert, in order. A false element is skipped.
  __insertEntries: (position, block) =>
    @__endLineAt position - 1
    for entry in *block
      continue unless entry
      table.insert @entries, position, entry
      @__entryByLine[entry.line] = entry if entry.line
      position += 1

  ---Inserts a line into `lines` and a new entry for it into `entries`.
  ---@private
  ---@param lineIndex integer The line's index in `lines`.
  ---@param line AegisubLine A line returned by `__prepareLine`.
  ---@param position integer The entry's index in `entries`.
  __insertLine: (lineIndex, line, position) =>
    table.insert @lines, lineIndex, line
    @__insertEntries position, {@__entryFor line}

return Accessors.install AssScript
