-- cspell:ignore Colour -- the format's own field names, matched verbatim against a `Format:` line
-- cspell:ignore HAABBGGRR -- the ASS color template
--
-- Every structural artifact a file holds is kept as an entry of its own, so `emit` can write the text
-- back byte for byte while `script.lines` still holds only what Aegisub's automation API would report.
-- A file read as UTF-16 is transcoded on the way in and back on the way out, so `emit` returns bytes
-- rather than text wherever the encoding is not one of the UTF-8 pair.
--
-- `serializeLine` writes a line from its fields alone and `serializeEntry` from the text each field
-- arrived in, so only the second reproduces a file. Checking one against the other is what shows a
-- field reads back as what it was written as.

Enum = require "l0.DependencyControl.Enum"
Ass = require "l0.AssParser.ass"
Unicode = require "l0.DependencyControl.unicode"

LineClass = Ass.LineClass
LineField = Ass.LineField

msgs = {
  parse: {
    notText: "Expected the script's text as a string, got a %s."
  }
  readFile: {
    openFailed: "Could not open '%s': %s"
  }
}

Encoding = Unicode.Encoding

---What a line of the file stands for. Only `Line` entries reach `script.lines`, since the rest have no
---place in the shape Aegisub's automation API reports.
---@alias AssFileEntryKind string
---| "line" # Line: a dialogue, style or info line, parsed into the Aegisub shape
---| "section" # Section: a bracketed section heading
---| "format" # Format: a section's `Format:` line, which names the fields its entries are written in
---| "other" # Other: a blank line, a comment, or anything else no reading claimed
EntryKind = Enum "AssFileEntryKind", {
  Line: "line"
  Section: "section"
  Format: "format"
  Other: "other"
}

---The key a line of the file opens with, which decides how the rest of it is read. A Script Info
---setting takes its own name instead, so none of these stands for one.
---@alias AssFileLinePrefix string
---| "Format" # Format: names the fields the entries of its section are written in
---| "Style" # Style: a style definition
---| "Dialogue" # Dialogue: an event that renders
---| "Comment" # Comment: an event that does not, written in every other way as a dialogue line is
LinePrefix = Enum "AssFileLinePrefix", {
  Format: "Format"
  Style: "Style"
  Dialogue: "Dialogue"
  Comment: "Comment"
}

-- A key and the rest of its line, which every prefixed entry is written as: `Format`, `Style`,
-- `Dialogue` and `Comment` alike, and a Script Info setting.
INFO_PATTERN = "^(%a[%w_ ]-)%s*:%s*(.*)$"

DEFAULT_EOL = "\r\n"
EVENTS_SECTION = "[Events]"
SCRIPT_INFO_SECTION = "[Script Info]"
STYLES_SECTION = "[V4+ Styles]"

-- The field names V4+ writes, against the Aegisub key each one is reported under. A file states its
-- own order in a `Format:` line and wild ones do vary, so the order here is only the fallback.
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

defaultStyleFormat = {
  "Name", "Fontname", "Fontsize", "PrimaryColour", "SecondaryColour", "OutlineColour", "BackColour"
  "Bold", "Italic", "Underline", "StrikeOut", "ScaleX", "ScaleY", "Spacing", "Angle", "BorderStyle"
  "Outline", "Shadow", "Alignment", "MarginL", "MarginR", "MarginV", "Encoding"
}

defaultEventFormat = {
  "Layer", "Start", "End", "Style", "Name", "MarginL", "MarginR", "MarginV", "Effect", "Text"
}

-- SSA's own styles section, whose `Format:` names six fields fewer than V4+ does and two of its own.
SSA_STYLES_SECTION = "[V4 Styles]"
SSA_ALPHA_FORMAT_NAME = "AlphaLevel"
-- SSA states one alpha for the whole style rather than one per color, and both renderers hold the
-- back color's at this regardless of what the style says, which libass records as VSFilter compatibility.
SSA_BACK_ALPHA = 0x80

---Writes an alpha into a color a style declared, keeping the color it names.
---@param text string The color as the style wrote it.
---@param alpha integer The alpha byte to put on it.
---@return string color The color in the eight-digit `&HAABBGGRR&` notation an alpha needs.
withAlpha = (text, alpha) ->
  color = Ass.splitStyleColor Ass.parseColor text or ""
  return Ass.emitColor Ass.packStyleColor(color, alpha), Ass.ColorNotation.ColorAndAlpha

---Fills in what an SSA style leaves unsaid, so that it reads exactly as a V4+ style does. Six fields
---V4+ declares are absent from SSA's format and take the values a renderer starts
---them at; `TertiaryColour` stands where V4+ writes `OutlineColour` and is discarded rather than read,
---since SSA draws the outline in the back color; and one `AlphaLevel` stands for every color's alpha.
---@param style AegisubStyleLine The style read so far, in place.
---@param alphaLevel? number The `AlphaLevel` field, absent where the format names none.
applySsaStyleDefaults = (style, alphaLevel) ->
  style.scale_x = 100 if style.scale_x == nil
  style.scale_y = 100 if style.scale_y == nil
  style.spacing = 0 if style.spacing == nil
  style.angle = 0 if style.angle == nil
  style.underline = false if style.underline == nil
  style.strikeout = false if style.strikeout == nil

  -- A number outside SSA's own 1 through 11 is drawn differently by each renderer, so there is no
  -- keypad number to report and the field is left holding what the style wrote.
  if style.align
    style.align = Ass.getKeypadAlignment(style.align, Ass.AlignmentSource.StyleField) or style.align

  -- the outline is drawn in the back color, which is what makes `TertiaryColour` unread
  style.color3 = style.color4

  return unless alphaLevel
  front = math.max 0, math.min alphaLevel, 0xFF
  style.color1 = withAlpha style.color1, front
  style.color2 = withAlpha style.color2, front
  style.color3 = withAlpha style.color3, front
  style.color4 = withAlpha style.color4, SSA_BACK_ALPHA

-- Derived from the one statement of what each style field holds, so a field whose type is corrected
-- there is read here as the corrected type rather than by a copy that has stopped agreeing with it.
booleanStyleFields = {field, true for {field, kind} in *Ass.styleFields when kind == "boolean"}
numericStyleFields = {field, true for {field, kind} in *Ass.styleFields when kind == "number"}

---Reads a timestamp in the `H:MM:SS.CC` form the format writes.
---@param text string The field as the file wrote it.
---@return integer? milliseconds Nil where the field does not parse as a timestamp.
parseTime = (text) ->
  hours, minutes, seconds, centiseconds = text\match "^%s*(%d+):(%d+):(%d+)%.(%d+)%s*$"
  return nil unless hours
  -- a two-digit field is hundredths, and a file writing more or fewer digits still scales from there
  fraction = tonumber("0." .. centiseconds) or 0
  return (tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)) * 1000 + math.floor fraction * 1000 + 0.5

---Writes a timestamp the way the format does, truncating below a hundredth as every implementation does.
---@param milliseconds integer The time to write.
---@return string text The timestamp in `H:MM:SS.CC` form.
emitTime = (milliseconds) ->
  total = math.max 0, math.floor milliseconds
  centiseconds = math.floor total / 10 % 100
  seconds = math.floor(total / 1000) % 60
  minutes = math.floor(total / 60000) % 60
  hours = math.floor total / 3600000
  return "%d:%02d:%02d.%02d"\format hours, minutes, seconds, centiseconds

---Splits a value list on commas, stopping so the last named field keeps every comma left in the line.
---@param text string Everything after the entry's `Dialogue:` or `Style:` prefix.
---@param count integer How many fields the section's format names.
---@return string[] values One per named field, the last holding the remainder.
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

---Reads the field names a `Format:` line states.
---@param text string Everything after the `Format:` prefix.
---@return string[] names One per field, whitespace trimmed.
parseFormat = (text) ->
  names = {}
  for name in text\gmatch "[^,]+"
    names[#names + 1] = name\match "^%s*(.-)%s*$"
  return names

---Converts a style field from the text the file holds to what Aegisub reports it as.
---@param field string The Aegisub key the field is reported under.
---@param text string The value as the file wrote it.
---@return boolean|number|string value A boolean for a switch, a number for a numeric field, and the
---  trimmed text otherwise. A numeric field holding no number reads as zero.
readStyleValue = (field, text) ->
  return text\match("^%s*(.-)%s*$") != "0" if booleanStyleFields[field]
  return tonumber(text) or 0 if numericStyleFields[field]
  return text\match "^%s*(.-)%s*$"

---Converts an event field from the text the file holds to what Aegisub reports it as.
---@param field string The Aegisub key the field is reported under.
---@param text string The value as the file wrote it.
---@return integer|string value Milliseconds for a timestamp, a whole number for a layer or margin, and
---  the trimmed text otherwise. `text` alone keeps its whitespace, which the line is drawn with.
readEventValue = (field, text) ->
  switch field
    when LineField.StartTime, LineField.EndTime then parseTime(text) or 0
    when LineField.Layer, LineField.MarginLeft, LineField.MarginRight, LineField.MarginTop then math.floor tonumber(text) or 0
    when LineField.Text then text
    else text\match "^%s*(.-)%s*$"

-- declared before the table so its own members can reach it; there is no hoisting
local AssFile

AssFile = {
  Encoding: Encoding
  EntryKind: EntryKind
  LineField: LineField
  LinePrefix: LinePrefix
  parseTime: parseTime
  emitTime: emitTime

  ---Reads a file's bytes as text, transcoding a UTF-16 one and stripping any byte-order mark. A file
  ---with no mark is handed back unchanged, so a legacy 8-bit script keeps its bytes rather than being
  ---guessed at, and the tag syntax survives either way since the scanner reads bytes.
  ---@param bytes string The file as it was read, in binary mode.
  ---@return string text The script's text, in UTF-8 where the encoding was known.
  ---@return UnicodeEncoding encoding Which encoding the bytes were read as.
  decode: (bytes) -> Unicode.decodeToUtf8 bytes

  ---Splits a script into entries in file order, parsing the dialogue, style and info lines into the
  ---shape Aegisub's automation API reports and keeping every other line as it stood.
  ---@param text string The script's text, decoded.
  ---@return AssScript? script Nil where the argument is not a string.
  ---@return string? err Why the text was refused.
  parse: (text) ->
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
          -- SSA's own alpha field, which V4+ dropped in favor of an alpha byte per color
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

    {:entries, :lines, :styleFormat, :eventFormat, eol: lfCount > crlfCount and "\n" or DEFAULT_EOL}

  ---Writes a line from its fields, in the order the format states rather than from its `raw`.
  ---@param line AegisubLine The line to write.
  ---@param format? string[] The field names its section declares, the V4+ order where absent.
  ---@return string? text The line as the format writes it, nil for a class that has no written form.
  serializeLine: (line, format) ->
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

  ---Writes a parsed entry back, keeping the text every unchanged field was written in so a file's own
  ---spelling of a value survives — a margin written `0000`, a boolean written `-1`, a time written to
  ---more digits than a hundredth. A field whose value no longer reads back as the text it came from is
  ---written afresh, so an edit reaches the output and nothing else moves.
  ---@param entry AssFileEntry The entry to write, which must hold a parsed line.
  ---@param format? string[] The field names its section declares, the V4+ order where absent.
  ---@return string text The entry as a line of the file, without its line ending.
  serializeEntry: (entry, format) ->
    line = entry.line
    return entry.raw unless line

    if line.class == LineClass.Info
      key, value = entry.raw\match INFO_PATTERN
      return key == line.key and value == line.value and entry.raw or
        "%s: %s"\format line.key, line.value

    return AssFile.serializeLine line, format unless entry.values

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

  ---Writes the script back out, reproducing the file it was parsed from byte for byte where nothing
  ---was changed. An entry whose `raw` was cleared is written from its fields instead.
  ---@param script AssScript The parsed script.
  ---@param encoding? UnicodeEncoding Which encoding to write, the script's own by default.
  ---@return string bytes The script as a file holds it, transcoded and marked to match the encoding.
  emit: (script, encoding = script.encoding) ->
    parts = {}
    for entry in *script.entries
      format = if entry.line and entry.line.class == LineClass.Style
        script.styleFormat
      elseif entry.line and entry.line.class == LineClass.Dialogue
        script.eventFormat
      written = entry.raw
      written or= entry.line and AssFile.serializeEntry(entry, format) or ""
      parts[#parts + 1] = written .. entry.eol
    return Unicode.encodeFromUtf8 table.concat(parts), encoding

  ---Reads a script off disk, in binary mode so no line ending is rewritten on the way in.
  ---@param path string Where the file is.
  ---@return AssScript? script Nil where the file could not be read or parsed.
  ---@return string|UnicodeEncoding err Why it failed, or the encoding it was read in.
  readFile: (path) ->
    handle, err = io.open path, "rb"
    return nil, msgs.readFile.openFailed\format path, tostring err unless handle
    bytes = handle\read "*a"
    handle\close!
    text, encoding = AssFile.decode bytes
    script, parseErr = AssFile.parse text
    return nil, parseErr unless script
    script.encoding = encoding
    return script, encoding
}

---A script as it was read, holding both the file's own structure and the lines Aegisub would report.
---@class AssScript
---@field entries AssFileEntry[] Every line of the file in order, structural ones included.
---@field lines AegisubLine[] The dialogue, style and info lines alone, in file order.
---@field styleFormat string[] The field names the styles section declares.
---@field eventFormat string[] The field names the events section declares.
---@field eol string The line ending the file mostly used, which a rebuilt line is written with.
---@field encoding? UnicodeEncoding Set by `readFile`, absent for a script parsed from text.

---One line of the file, whatever it stands for.
---@class AssFileEntry
---@field kind AssFileEntryKind What the line stands for.
---@field raw string The line as the file wrote it, without its line ending.
---@field eol string The line ending that followed it, empty where the file ended without one.
---@field line? AegisubLine The parsed line, present only where `kind` is `"line"`.
---@field fields? string[] The names a `Format:` line states, present only where `kind` is `"format"`.

---Reading and writing `.ass` files, in the line shapes Aegisub's automation API reports.
---@class AssFile
return AssFile
