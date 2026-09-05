-- cspell:ignore Colour -- the format's own field names, written out in the `Format:` fixture below
--
-- Tests reading, editing and writing scripts with `AssScript`. Most tests check that a file is written
-- back unchanged, since scripts in the wild write their values in many forms and serializing an unedited
-- value afresh would change a line nobody edited. The others check that an edited field is written from
-- its new value.
-- Called from test.moon as: (controls\requireTest "AssScript")!
->
  ffi = require "ffi"
  AssScript = require "l0.AssParser.AssScript"
  unicode = require "l0.DependencyControl.unicode"
  {:Encoding, :EntryKind, :decode, :emitTime, :parse, :parseTime, :serializeEntry} = AssScript

  ---Joins lines into a script with CRLF line endings.
  ---@param lines string[] The lines, without their endings.
  ---@return string text The script's text.
  buildScript = (lines) -> table.concat(lines, "\r\n") .. "\r\n"

  STYLE_FORMAT_LINE = "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
  EVENT_FORMAT_LINE = "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"

  HEADER = {
    "[Script Info]"
    "Title: A script"
    "WrapStyle: 0"
    ""
    "[V4+ Styles]"
    STYLE_FORMAT_LINE
    "Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1"
    ""
    "[Events]"
    EVENT_FORMAT_LINE
  }

  ---Builds a script with a styles section containing the given line.
  ---@param styleLine string A `Style:` line.
  ---@return string text The script's text.
  scriptWithStyle = (styleLine) -> buildScript {"[V4+ Styles]", STYLE_FORMAT_LINE, styleLine}

  ---Builds a script from the shared header followed by the given events.
  ---@param events string[] Dialogue and comment lines.
  ---@return string text The script's text.
  scriptWith = (events) ->
    lines = [line for line in *HEADER]
    lines[#lines + 1] = event for event in *events
    buildScript lines

  ---Creates a dialogue line with every field Aegisub requires.
  ---@param text string The line's text.
  ---@return AegisubDialogueLine line
  makeDialogue = (text) ->
    {class: "dialogue", comment: false, layer: 0, start_time: 0, end_time: 1000, style: "Default",
     actor: "", effect: "", margin_l: 0, margin_r: 0, margin_t: 0, :text, extra: {}}

  ---Returns a `Style:` line for a style with the given name.
  ---@param name string The style's name.
  ---@return string styleLine The line, without a line ending.
  styleNamed = (name) ->
    "Style: #{name},Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1"

  -- A script for the line filter tests: a stray dialogue line in the header, five styles, and three
  -- events, one of them a comment.
  FILTER_FIXTURE = buildScript {
    "[Script Info]"
    "Title: A script"
    "Dialogue: 0,0:00:00.00,0:00:01.00,Stray,,0,0,0,,pasted into the header"
    ""
    "[V4+ Styles]"
    STYLE_FORMAT_LINE
    styleNamed "Default"
    styleNamed "Sign"
    styleNamed "sign"
    styleNamed "Alt"
    styleNamed "Unused"
    ""
    "[Events]"
    EVENT_FORMAT_LINE
    "Dialogue: 0,0:00:01.00,0:00:02.00,Sign,,0,0,0,,{\\rAlt}signed"
    "Dialogue: 0,0:00:02.00,0:00:03.00,Missing,,0,0,0,,unstyled"
    "Comment: 0,0:00:03.00,0:00:04.00,Unused,,0,0,0,,commented"
  }

  {
    _description: "ASS file reading and writing"

    parse_reportsOnlyAegisubLineClasses: (ut) ->
      script = parse scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,hello"}
      ut\assertEquals #script.lines, 4 -- two info, one style, one dialogue
      classes = [line.class for line in *script.lines]
      ut\assertEquals table.concat(classes, " "), "info info style dialogue"

      -- section headings, `Format:` lines and blank lines are entries but not lines
      kinds = {}
      kinds[entry.kind] = (kinds[entry.kind] or 0) + 1 for entry in *script.entries
      ut\assertEquals kinds[EntryKind.Section], 3
      ut\assertEquals kinds[EntryKind.Format], 2

    parse_readsDialogueFieldsIntoTheAegisubShape: (ut) ->
      script = parse scriptWith {"Comment: 3,0:00:01.50,0:01:02.25,Sign,Actor,11,22,33,fx,{\\b1}text"}
      line = script.lines[#script.lines]
      ut\assertTrue line.comment
      ut\assertEquals line.layer, 3
      ut\assertEquals line.start_time, 1500
      ut\assertEquals line.end_time, 62250
      ut\assertEquals line.style, "Sign"
      ut\assertEquals line.actor, "Actor"
      ut\assertEquals line.effect, "fx"
      ut\assertEquals line.margin_l, 11
      ut\assertEquals line.margin_r, 22
      ut\assertEquals line.margin_t, 33
      ut\assertEquals line.text, "{\\b1}text"

    -- The text field gets every remaining comma, so commas in a tag's arguments are kept.
    parse_keepsCommasInTheTextField: (ut) ->
      text = "{\\move(10,20,30,40)}a, b, c"
      script = parse scriptWith {"Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,#{text}"}
      ut\assertEquals script.lines[#script.lines].text, text

    -- Scripts in the wild list their fields in orders other than V4+'s.
    parse_honorsTheFormatLineOrder: (ut) ->
      script = parse buildScript {
        "[Events]"
        "Format: Start, End, Text"
        "Dialogue: 0:00:02.00,0:00:04.00,the text"
      }
      line = script.lines[1]
      ut\assertEquals line.start_time, 2000
      ut\assertEquals line.end_time, 4000
      ut\assertEquals line.text, "the text"

    emit_reproducesTheFileItParsed: (ut) ->
      text = scriptWith {
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"
        "Comment: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,second"
      }
      ut\assertEquals parse(text)\emit!, text

    -- `decode` strips the byte-order mark, and `emit` writes it back for the encoding the script
    -- records, without the encoding being passed again.
    emit_putsBackTheByteOrderMarkTheScriptWasReadWith: (ut) ->
      text = scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"}
      bytes = "\239\187\191" .. text
      decoded, encoding = decode bytes
      script = parse decoded
      script.encoding = encoding
      ut\assertEquals script\emit!, bytes
      -- a script parsed from text records no encoding, so no mark is written
      ut\assertEquals parse(text)\emit!, text

    -- A UTF-16 file is written back in UTF-16 with its byte-order mark. Both byte orders are tested,
    -- since only the mark tells them apart.
    emit_writesAUtf16FileBackAsItWasRead: (ut) ->
      text = scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"}
      units = unicode.encodeUtf16 unicode.decodeUtf8 text
      for {marker, encoding, littleEndian} in *{
          {"\255\254", Encoding.Utf16Le, true}
          {"\254\255", Encoding.Utf16Be, false}
        }
        bytes = marker .. unicode.packUtf16Units units, littleEndian
        decoded, read = decode bytes
        ut\assertEquals read, encoding
        script = parse decoded
        script.encoding = read
        ut\assertEquals script\emit!, bytes

    -- A missing final line ending is not added, since that would change the file.
    emit_keepsAFinalLineWithNoEnding: (ut) ->
      text = "[Script Info]\r\nTitle: A script"
      ut\assertEquals parse(text)\emit!, text

    emit_keepsMixedLineEndings: (ut) ->
      text = "[Script Info]\nTitle: A script\r\nWrapStyle: 0\n"
      ut\assertEquals parse(text)\emit!, text

    -- These lines write their values in forms that differ from how they would be serialized, so
    -- serializing them afresh would change lines nobody edited.
    serializeEntry_keepsTheTextOfAnUnchangedField: (ut) ->
      for written in *{
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,text"
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,, 0 , 0 , 0 ,,text"
      }
        script = parse scriptWith {written}
        entry = script.entries[#script.entries]
        ut\assertEquals serializeEntry(entry, script.eventFormat), written

      -- a `Style:` line in the events section is not parsed as a style, so it gets a script of its own
      written = "Style: Default,Arial,48.0,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,2,2,0000,0000,0000,1"
      script = parse scriptWithStyle written
      entry = script.entries[#script.entries]
      ut\assertEquals serializeEntry(entry, script.styleFormat), written

    -- An unchanged info line keeps its spacing for the same reason.
    serializeEntry_keepsAnInfoLineSpacing: (ut) ->
      script = parse "[Script Info]\r\nTitle:    Default Aegisub file\r\n"
      entry = script.entries[2]
      ut\assertEquals entry.line.key, "Title"
      ut\assertEquals entry.line.value, "Default Aegisub file"
      ut\assertEquals serializeEntry(entry), "Title:    Default Aegisub file"

    serializeEntry_writesAnEditedFieldAfresh: (ut) ->
      script = parse scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,before"}
      entry = script.entries[#script.entries]
      entry.line.text = "after"
      entry.line.start_time = 90
      -- only the edited fields change, and the padded margins stay as they were
      ut\assertEquals serializeEntry(entry, script.eventFormat),
        "Dialogue: 0,0:00:00.09,0:00:02.00,Default,,0000,0000,0000,,after"

    -- `emit` writes an entry's `raw` while it has one, so a direct edit to a line is only written once
    -- `raw` is cleared.
    emit_writesAnEditedLineOnceItsRawIsCleared: (ut) ->
      script = parse scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,before"}
      entry = script.entries[#script.entries]
      entry.line.text = "after"
      ut\assertNil script\emit!\match "after"

      entry.raw = nil
      ut\assertNotNil script\emit!\match "after"

    decode_stripsAUtf8ByteOrderMark: (ut) ->
      text, encoding = decode "\239\187\191[Script Info]\r\n"
      ut\assertEquals text, "[Script Info]\r\n"
      ut\assertEquals encoding, Encoding.Utf8Bom

    decode_transcodesUtf16: (ut) ->
      -- "[A]" as UTF-16, both ways round
      little = "\255\254" .. "\91\0\65\0\93\0"
      big = "\254\255" .. "\0\91\0\65\0\93"
      text, encoding = decode little
      ut\assertEquals text, "[A]"
      ut\assertEquals encoding, Encoding.Utf16Le
      text, encoding = decode big
      ut\assertEquals text, "[A]"
      ut\assertEquals encoding, Encoding.Utf16Be

    -- Bytes without a mark are kept as they are, since guessing a legacy 8-bit encoding could corrupt them.
    decode_leavesUnmarkedBytesAlone: (ut) ->
      bytes = "[Script Info]\r\nTitle: \164\226\168\233\r\n"
      text, encoding = decode bytes
      ut\assertEquals text, bytes
      ut\assertEquals encoding, Encoding.Utf8

    parseTime_readsTheFormatsOwnShape: (ut) ->
      ut\assertEquals parseTime("0:00:00.00"), 0
      ut\assertEquals parseTime("1:02:03.04"), 3723040
      ut\assertEquals parseTime("0:00:01.5"), 1500
      ut\assertNil parseTime "not a time"

    emitTime_writesWhatParseTimeReads: (ut) ->
      for written in *{"0:00:00.00", "0:00:01.50", "1:02:03.04", "9:59:59.99"}
        ut\assertEquals emitTime(parseTime written), written

    parse_refusesWhatIsNotText: (ut) ->
      script, err = parse 42
      ut\assertNil script
      ut\assertNotNil err

    -- `subtitles` works on the script's own lines, so an edit through it changes the script.
    subtitles_isBuiltOverTheScriptsOwnLines: (ut) ->
      script = parse scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"}
      object = script.subtitles
      ut\assertEquals #object, #script.lines
      ut\assertEquals object[4].text, script.lines[4].text

      line = object[4]
      line.text = "EDITED"
      object[4] = line
      ut\assertEquals script.lines[4].text, "EDITED"
      ut\assertContains script\emit!, ",,EDITED"

    addLine_opensASectionWhereTheFileHoldsNone: (ut) ->
      script = parse "[Script Info]\r\nTitle: A script\r\n"
      script\addLine makeDialogue "added"
      ut\assertEquals #script.lines, 2
      emitted = script\emit!
      ut\assertContains emitted, "\r\n[Events]\r\n#{EVENT_FORMAT_LINE}\r\n"
      ut\assertContains emitted, "Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,added\r\n"

    -- A new section for a class earlier in Aegisub's order goes before the existing section.
    addLine_opensASectionAheadOfALaterOne: (ut) ->
      script = parse buildScript {
        "[Script Info]", "Title: A script", "", "[Events]", EVENT_FORMAT_LINE
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"
      }
      script\addLine {class: "style", name: "Added", fontname: "Arial", fontsize: 20, color1: "&H00FFFFFF",
        color2: "&H000000FF", color3: "&H00000000", color4: "&H00000000", bold: false, italic: false,
        underline: false, strikeout: false, scale_x: 100, scale_y: 100, spacing: 0, angle: 0,
        borderstyle: 1, outline: 2, shadow: 2, align: 2, margin_l: 10, margin_r: 10, margin_t: 10, encoding: 1}
      classes = [line.class for line in *script.lines]
      ut\assertEquals table.concat(classes, " "), "info style dialogue"
      emitted = script\emit!
      ut\assertTrue emitted\find("[V4+ Styles]", 1, true) < emitted\find("[Events]", 1, true)

    -- The script is laid out as Aegisub saves a file: a section per class, the platform's line ending
    -- and a byte-order mark. The comment line is dropped, since the interface does not expose it.
    fromSubtitles_rebuildsTheFileAegisubWouldSave: (ut) ->
      source = scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"}
      rebuilt = AssScript.fromSubtitles parse("; a comment\r\n" .. source).subtitles
      ut\assertEquals #rebuilt.lines, 4
      ut\assertEquals rebuilt.encoding, Encoding.Utf8Bom
      eol = ffi.os == "Windows" and "\r\n" or "\n"
      ut\assertEquals rebuilt.eol, eol

      emitted = rebuilt\emit!
      ut\assertMatches emitted, "^\239\187\191%[Script Info%]"
      ut\assertNotContains emitted, "; a comment"
      for heading in *{"[Script Info]", "[V4+ Styles]", "[Events]"}
        ut\assertContains emitted, heading .. eol
      ut\assertContains emitted, EVENT_FORMAT_LINE .. eol
      ut\assertContains emitted, "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first" .. eol

    emit_keepsOnlyTheDialogueLinesALineFilterSelects: (ut) ->
      script = parse FILTER_FIXTURE
      seen = {}
      emitted = script\emit (line, index) ->
        seen[#seen + 1] = index
        ut\assertIs line, script.lines[index]
        line.text == "unstyled"
      -- the filter is called for every dialogue line, the comment included, and for nothing else
      ut\assertEquals seen, {8, 9, 10}
      ut\assertContains emitted, ",,unstyled"
      ut\assertNotContains emitted, ",,{\\rAlt}signed"
      ut\assertNotContains emitted, ",,commented"
      ut\assertContains emitted, "Title: A script"
      ut\assertContains emitted, EVENT_FORMAT_LINE

    -- The styles a kept line's style field and `\r` tags reach are kept, including those whose names
    -- differ only in case. Other styles are dropped.
    emit_keepsOnlyTheStylesTheSelectedLinesUse: (ut) ->
      emitted = parse(FILTER_FIXTURE)\emit (line) -> line.text == "{\\rAlt}signed"
      ut\assertContains emitted, styleNamed "Sign"
      ut\assertContains emitted, styleNamed "sign"
      ut\assertContains emitted, styleNamed "Alt"
      ut\assertNotContains emitted, styleNamed "Unused"
      ut\assertNotContains emitted, styleNamed "Default"

    -- A line reaching no declaration is drawn in `Default`, so `Default` is kept.
    emit_keepsDefaultForALineReachingNoStyle: (ut) ->
      emitted = parse(FILTER_FIXTURE)\emit (line) -> line.text == "unstyled"
      ut\assertContains emitted, styleNamed "Default"
      for name in *{"Sign", "sign", "Alt", "Unused"}
        ut\assertNotContains emitted, styleNamed name

    -- The parser reads the stray line as an info line, so the filter never sees it. A filtered emit
    -- drops it, and an unfiltered one writes it back unchanged.
    emit_leavesOutADialogueLineOutsideTheEventsSectionWhenFiltering: (ut) ->
      script = parse FILTER_FIXTURE
      ut\assertContains script\emit(-> true), ",,unstyled"
      ut\assertNotContains script\emit(-> true), "pasted into the header"
      ut\assertEquals script\emit!, FILTER_FIXTURE
  }
