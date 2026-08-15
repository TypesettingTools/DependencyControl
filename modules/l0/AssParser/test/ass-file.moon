-- cspell:ignore Colour -- the format's own field names, written out in the `Format:` fixture below
--
-- Pins what reading a `.ass` file preserves. The contract worth holding is that a file survives being
-- read and written back unchanged, so most of these assert a round trip rather than a parsed value:
-- a wild script spells its fields however its author's tool did, and re-spelling one is an edit nobody
-- asked for. The counterpart is that an edited field *is* written afresh, which the same tests check
-- from the other side.
-- Called from test.moon as: (controls\requireTest "ass-file")!
->
  assFile = require "l0.AssParser.ass-file"
  unicode = require "l0.DependencyControl.unicode"
  {:Encoding, :EntryKind, :decode, :emit, :emitTime, :parse, :parseTime, :serializeEntry} = assFile

  ---Builds a small script, joined with CRLF as the format writes it.
  ---@param lines string[] The lines, without their endings.
  ---@return string text
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

  ---Builds a script whose styles section holds the given line.
  ---@param styleLine string A `Style:` line.
  ---@return string text
  scriptWithStyle = (styleLine) -> buildScript {"[V4+ Styles]", STYLE_FORMAT_LINE, styleLine}

  ---Builds a script whose events section holds the given lines.
  ---@param events string[] Dialogue and comment lines.
  ---@return string text
  scriptWith = (events) ->
    lines = [line for line in *HEADER]
    lines[#lines + 1] = event for event in *events
    buildScript lines

  {
    _description: "ASS file reading and writing"

    parse_reportsOnlyAegisubLineClasses: (ut) ->
      script = parse scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,hello"}
      ut\assertEquals #script.lines, 4 -- two info, one style, one dialogue
      classes = [line.class for line in *script.lines]
      ut\assertEquals table.concat(classes, " "), "info info style dialogue"

      -- section headings, the two Format lines and the blank lines stay out of the Aegisub shape
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

    -- The text field takes every comma left in the line, so a tag holding one survives the split.
    parse_keepsCommasInTheTextField: (ut) ->
      text = "{\\move(10,20,30,40)}a, b, c"
      script = parse scriptWith {"Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,#{text}"}
      ut\assertEquals script.lines[#script.lines].text, text

    -- A file states its own field order, and wild ones do vary from the order V4+ writes.
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
      ut\assertEquals emit(parse text), text

    -- The mark is stripped on the way in and belongs back on the way out, so a script that holds the
    -- encoding it was read in round trips from bytes to bytes without the caller naming it again.
    emit_putsBackTheByteOrderMarkTheScriptWasReadWith: (ut) ->
      text = scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,first"}
      bytes = "\239\187\191" .. text
      decoded, encoding = decode bytes
      script = parse decoded
      script.encoding = encoding
      ut\assertEquals emit(script), bytes
      -- a script parsed from text alone was read with no mark, so none is written
      ut\assertEquals emit(parse text), text

    -- A UTF-16 file is transcoded on the way in, so writing it back takes the reverse trip and the
    -- mark with it. Both byte orders, since only the mark tells them apart.
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
        ut\assertEquals emit(script), bytes

    -- A file ending without a newline is not given one, since that would be an edit of its own.
    emit_keepsAFinalLineWithNoEnding: (ut) ->
      text = "[Script Info]\r\nTitle: A script"
      ut\assertEquals emit(parse text), text

    emit_keepsMixedLineEndings: (ut) ->
      text = "[Script Info]\nTitle: A script\r\nWrapStyle: 0\n"
      ut\assertEquals emit(parse text), text

    -- The spellings below all read back as the same values, so re-rendering them would rewrite lines
    -- nobody edited. Zero-padded margins are what the corpus turned up first.
    serializeEntry_keepsTheSpellingOfAnUnchangedField: (ut) ->
      for written in *{
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,text"
        "Dialogue: 0,0:00:01.00,0:00:02.00,Default,, 0 , 0 , 0 ,,text"
      }
        script = parse scriptWith {written}
        entry = script.entries[#script.entries]
        ut\assertEquals serializeEntry(entry, script.eventFormat), written

      -- a style counts only inside the styles section, so its spelling is checked there
      written = "Style: Default,Arial,48.0,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,2,2,0000,0000,0000,1"
      script = parse scriptWithStyle written
      entry = script.entries[#script.entries]
      ut\assertEquals serializeEntry(entry, script.styleFormat), written

    -- Info lines keep their own spacing for the same reason: `Title:    x` is not `Title: x` on disk.
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
      -- the edited fields are rewritten and the padded margins stay as the file wrote them
      ut\assertEquals serializeEntry(entry, script.eventFormat),
        "Dialogue: 0,0:00:00.09,0:00:02.00,Default,,0000,0000,0000,,after"

    -- `emit` writes a line's `raw`, so an edit only reaches the output once that is cleared.
    emit_writesAnEditedLineOnceItsRawIsCleared: (ut) ->
      script = parse scriptWith {"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,before"}
      entry = script.entries[#script.entries]
      entry.line.text = "after"
      ut\assertNil emit(script)\match "after"

      entry.raw = nil
      ut\assertNotNil emit(script)\match "after"

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

    -- A script with no mark keeps its bytes, since guessing a legacy 8-bit charset would corrupt it.
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
  }
