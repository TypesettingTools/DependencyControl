-- Tests `AegisubSubtitles` against Aegisub's subtitle file interface. The expectations are taken from
-- Aegisub's `auto4_lua_assfile.cpp`, which differs from the online documentation in two ways: section
-- headings are not lines, with each line's `section` set from its class instead, and there is no
-- writable `unknown` class.
-- Called from test.moon as: (controls\requireTest "AegisubSubtitles")!
->
  AegisubSubtitles = require "l0.AssParser.AegisubSubtitles"
  AssScript = require "l0.AssParser.AssScript"
  Ass = require "l0.AssParser.ass"

  SOURCE = table.concat {
    "[Script Info]"
    "; a comment no edit should disturb"
    "Title: Fixture"
    "PlayResX: 640"
    ""
    "[V4+ Styles]"
    -- cspell:disable-next-line -- the format's own field names, exempted by VOC3
    "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding"
    "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1"
    ""
    "[Events]"
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
    "Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,first"
    "Comment: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,second"
    ""
  }, "\n"

  ---Creates a subtitles object over a new parse of the fixture, so no test sees another test's edits.
  ---@param options? table Options for the constructor.
  ---@return AegisubSubtitles subtitles The new object.
  ---@return AssScript script The script it wraps.
  openFixture = (options) ->
    script = assert AssScript.parse SOURCE
    AegisubSubtitles(script, options), script

  ---Creates a dialogue line with every field Aegisub requires.
  ---@param text string The line's text.
  ---@return AegisubDialogueLine line
  makeDialogue = (text) ->
    {class: "dialogue", comment: false, layer: 0, start_time: 0, end_time: 1000, style: "Default",
     actor: "", effect: "", margin_l: 0, margin_r: 0, margin_t: 0, :text, extra: {}}

  {
    _description: "The subtitle file interface handed to an automation script"

    -- Aegisub groups the lines by class, info lines first, then styles, then dialogue lines.
    new_ordersTheLinesByGroupRatherThanByFilePosition: (ut) ->
      object = openFixture!
      ut\assertEquals #object, 5
      ut\assertEquals object.n, 5
      ut\assertItemsEqual [object[index].class for index = 1, #object],
        {"info", "info", "style", "dialogue", "dialogue"}

    -- `section` is set from the line's class, whatever heading the file used.
    index_reportsTheGroupsHeadingRatherThanTheSectionTheLineWasReadFrom: (ut) ->
      object = openFixture!
      ut\assertEquals object[1].section, "[Script Info]"
      ut\assertEquals object[3].section, "[V4+ Styles]"
      ut\assertEquals object[4].section, "[Events]"

    index_readsTheFieldsAegisubDoes: (ut) ->
      object = openFixture!
      ut\assertEquals object[2].key, "PlayResX"
      ut\assertEquals object[2].value, "640"
      ut\assertEquals object[3].name, "Default"
      ut\assertEquals object[4].text, "first"
      ut\assertFalse object[4].comment
      ut\assertTrue object[5].comment
      ut\assertMatches object[4].raw, "^Dialogue: "

    -- Each read returns a new table, so changing it has no effect until it is assigned back.
    index_returnsACopyOfTheLine: (ut) ->
      object = openFixture!
      held = object[4]
      held.text = "changed"
      ut\assertEquals object[4].text, "first"
      object[4] = held
      ut\assertEquals object[4].text, "changed"

    append_addsAfterTheLastLineOfItsClass: (ut) ->
      object = openFixture!
      object.append Ass.createStyle name: "Added"
      ut\assertEquals #object, 6
      -- after the existing style and before both dialogue lines
      ut\assertEquals object[4].class, "style"
      ut\assertEquals object[4].name, "Added"
      ut\assertEquals object[5].class, "dialogue"

    append_worksThroughIndexZeroAsWell: (ut) ->
      object = openFixture!
      object[0] = makeDialogue "appended"
      ut\assertEquals #object, 6
      ut\assertEquals object[6].text, "appended"

    insert_addsBeforeTheIndexGiven: (ut) ->
      object = openFixture!
      object.insert 1, {class: "info", key: "Inserted", value: "yes"}
      ut\assertEquals #object, 6
      ut\assertEquals object[1].key, "Inserted"
      ut\assertEquals object[2].key, "Title"

    insert_worksThroughANegativeIndexAsWell: (ut) ->
      object = openFixture!
      object[-1] = {class: "info", key: "Inserted", value: "yes"}
      ut\assertEquals object[1].key, "Inserted"

    delete_takesIndexVarargsOrATable: (ut) ->
      calls = {
        (object) -> object.delete 1, 2
        (object) -> object.delete {1, 2}
      }
      for deleting in *calls
        object = openFixture!
        deleting object
        ut\assertEquals #object, 3
        ut\assertEquals object[1].class, "style"

      object = openFixture!
      object[1] = nil
      ut\assertEquals #object, 4
      ut\assertEquals object[1].key, "PlayResX"

    -- `delete` throws on an index out of range, while `deleterange` clamps it.
    delete_refusesAnOutOfRangeIndexWhereDeleterangeClampsIt: (ut) ->
      object = openFixture!
      ut\assertError -> object.delete 99
      object.deleterange 4, 99
      ut\assertEquals #object, 3

    new_refusesEveryEditWhereReadOnly: (ut) ->
      object = openFixture readOnly: true
      ut\assertEquals #object, 5
      ut\assertError -> object.append makeDialogue "no"
      ut\assertError -> object.delete 1
      ut\assertError -> object[1] = nil

    index_refusesAKeyItDoesNotKnow: (ut) ->
      object = openFixture!
      ut\assertError -> object.nonsense
      ut\assertError -> object[99]
      ut\assertError -> object[{}]

    -- As in Aegisub, a line missing a field its class requires throws and nothing is stored.
    assign_refusesALineMissingAField: (ut) ->
      object = openFixture!
      ut\assertError -> object[4] = {class: "dialogue", text: "no timings"}
      ut\assertError -> object.append {class: "nonsense"}
      ut\assertEquals #object, 5

    scriptResolution_readsWhatAegisubWouldAssume: (ut) ->
      -- the fixture sets only the width, so the height is derived at 4:3
      object = openFixture!
      width, height = object.script_resolution!
      ut\assertEquals width, 640
      ut\assertEquals height, 480

      stated = AssScript.parse "[Script Info]\nPlayResX: 1280\n"
      ut\assertItemsEqual {stated.subtitles.script_resolution!}, {1280, 1024}

      neither = AssScript.parse "[Script Info]\nTitle: none\n"
      ut\assertItemsEqual {neither.subtitles.script_resolution!}, {384, 288}

    -- Writing the script back changes only the edited line. Every other line is kept as read, comments
    -- and blank lines included.
    assign_writesTheEditBackWithoutDisturbingTheRest: (ut) ->
      object, script = openFixture!
      line = object[4]
      line.text = "EDITED"
      object[4] = line

      emitted = script\emit!
      ut\assertContains emitted, "; a comment no edit should disturb"
      ut\assertContains emitted, "Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,EDITED"
      ut\assertContains emitted, "Comment: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,second"
      ut\assertNotContains emitted, ",,first"
  }
