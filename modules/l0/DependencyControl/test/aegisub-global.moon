-- Pins the parts of the faux `aegisub` global that carry a contract of their own, rather than standing
-- in for something Aegisub computes. Inside Aegisub the global is the real API, so these run only
-- against the stand-in.
-- Called from test.moon as: (controls\requireTest "aegisub-global")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"
  AssScript = require "l0.AssParser.AssScript"

  STYLE_SAMPLE = haveShims and shims.Ass.createStyle {fontname: "Arial", fontsize: 40}

  SOURCE = table.concat {
    "[Script Info]"
    "Title: Fixture"
    ""
    "[Events]"
    "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"
    "Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,first"
    "Dialogue: 0,0:00:05.00,0:00:10.00,Default,,0,0,0,,second"
    ""
  }, "\n"

  ---Sets a new parse of the fixture as the script and registers a macro, so no test sees another test's
  ---edits.
  ---@param name string The macro's name.
  ---@param processor function The macro's processing function.
  ---@param validator? function The macro's validation function.
  ---@return AssScript script The installed script.
  installWithMacro = (name, processor, validator) ->
    script = assert AssScript.parse SOURCE
    shims.setScript script
    aegisub.register_macro name, "a test macro", processor, validator
    script

  {
    _description: "The faux aegisub global's own contracts: its text-extents backend hook, and
      setting a script to run registered macros on."
    _condition: -> haveShims, "l0.AegisubShims isn't loaded (#{tostring shims})"

    ---@param ut UnitTest
    _setup: (ut) -> {restore: shims.getTextExtentsBackend!}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      shims.setTextExtentsBackend ctx.restore if ctx

    -- font metrics need a font engine, so measuring raises until a harness supplies one; inventing
    -- numbers would let a layout script produce plausible, wrong coordinates
    textExtents_raisesWhileNoBackendIsInstalled: (ut) ->
      shims.setTextExtentsBackend nil
      ut\assertNil shims.getTextExtentsBackend!
      ut\assertError aegisub.text_extents, STYLE_SAMPLE, "measure me"

    textExtents_handsTheStyleAndTextToTheBackend: (ut) ->
      seen = nil
      shims.setTextExtentsBackend (style, text) ->
        seen = {:style, :text}
        return 12, 34, 5, 6

      width, height, descent, extlead = aegisub.text_extents STYLE_SAMPLE, "measure me"
      ut\assertEquals {width, height, descent, extlead}, {12, 34, 5, 6}
      ut\assertIs seen.style, STYLE_SAMPLE
      ut\assertEquals seen.text, "measure me"

    -- Aegisub takes these through get_bool_field, which raises on a non-boolean, so a numeric weight
    -- never reaches its measurement. Zero is truthy in Lua, so silently accepting one here would
    -- measure a style that asked for no weight at all as bold.
    textExtents_rejectsANonBooleanWhereAegisubWouldRaise: (ut) ->
      shims.setTextExtentsBackend -> 1, 1, 1, 1
      for field in *{"bold", "italic", "underline", "strikeout"}
        for value in *{0, 700, "yes"}
          _, err = pcall aegisub.text_extents, shims.Ass.createStyle({[field]: value}), "measure me"
          ut\assertMatches err, "'#{field}' %(expected boolean%)"

    -- Aegisub checks every field of a style before measuring, so it refuses one missing a field its
    -- own measurement never reads. A partial style passing here would fail the moment it ran there.
    textExtents_rejectsAStyleAegisubWouldRefuse: (ut) ->
      shims.setTextExtentsBackend -> 7, 7, 7, 7
      _, noClass = pcall aegisub.text_extents, {fontname: "Arial", fontsize: 40}, "measure me"
      ut\assertMatches noClass, "has to state its class"

      partial = shims.Ass.createStyle!
      partial.margin_r = nil
      _, missing = pcall aegisub.text_extents, partial, "measure me"
      ut\assertMatches missing, "'margin_r' %(expected number%)"

      -- every field at fault is named, so a style built by hand is repaired in one pass
      partial.fontname = nil
      _, both = pcall aegisub.text_extents, partial, "measure me"
      ut\assertMatches both, "'fontname' %(expected string%)"
      ut\assertMatches both, "'margin_r' %(expected number%)"

    setTextExtentsBackend_returnsThePreviousOne: (ut) ->
      first = -> 1, 1, 1, 1
      shims.setTextExtentsBackend first
      ut\assertIs shims.setTextExtentsBackend(-> 2, 2, 2, 2), first
      ut\assertIsNot shims.getTextExtentsBackend!, first

    setTextExtentsBackend_nilLeavesMeasuringUnavailable: (ut) ->
      shims.setTextExtentsBackend -> 1, 1, 1, 1
      shims.setTextExtentsBackend nil
      ut\assertNil shims.getTextExtentsBackend!
      ut\assertError aegisub.text_extents, STYLE_SAMPLE, "measure me"

    setTextExtentsBackend_rejectsANonFunction: (ut) ->
      ut\assertError shims.setTextExtentsBackend, 42
      ut\assertError shims.setTextExtentsBackend, {}
      ut\assertError shims.setTextExtentsBackend, "nope"

    setScript_rejectsWhatIsNotAScript: (ut) ->
      ut\assertError shims.setScript, 42
      ut\assertError shims.setScript, {}
      ut\assertError shims.setScript, nil

    -- The macro's edits change the script that was set, and its undo points can be read after it returns.
    runMacro_runsTheMacroAgainstTheInstalledScript: (ut) ->
      script = installWithMacro "Test/Edit", (subtitles, selected, active) ->
        line = subtitles[selected[1]]
        line.text = "EDITED"
        subtitles[selected[1]] = line
        aegisub.set_undo_point "the edit"
        return {active}, active
      ut\assertIs shims.getScript!, script

      selected, active = shims.runMacro "Test/Edit", {3}, 3
      ut\assertEquals selected, {3}
      ut\assertEquals active, 3
      ut\assertEquals script.lines[3].text, "EDITED"
      ut\assertEquals shims.getUndoPoints!, {"the edit"}

    -- Without a selection the first dialogue line is selected, and a macro returning nothing keeps it.
    runMacro_selectsTheFirstDialogueLineByDefault: (ut) ->
      seen = nil
      installWithMacro "Test/Selection", (subtitles, selected, active) -> seen = {:selected, :active}
      selected, active = shims.runMacro "Test/Selection"
      ut\assertEquals seen.selected, {2}
      ut\assertEquals seen.active, 2
      ut\assertEquals selected, {2}
      ut\assertEquals active, 2

    -- As in Aegisub, the validation function gets a read-only object, and returning false keeps the
    -- macro from running.
    runMacro_passesTheValidatorAReadOnlyObjectAndStopsOnFalse: (ut) ->
      ran = false
      editable = nil
      processor = -> ran = true
      validator = (subtitles) ->
        editable = pcall -> subtitles[1] = nil
        false
      installWithMacro "Test/Refused", processor, validator
      ut\assertError shims.runMacro, "Test/Refused"
      ut\assertFalse ran
      ut\assertFalse editable

    runMacro_throwsForAMacroNobodyRegistered: (ut) ->
      shims.setScript assert AssScript.parse SOURCE
      ut\assertError shims.runMacro, "Test/Nonexistent"

    -- As in Aegisub, only a macro's processing function may set an undo point.
    setUndoPoint_throwsOutsideAMacro: (ut) ->
      ut\assertError aegisub.set_undo_point, "nothing is running"

    setScript_clearsTheUndoPointsOfTheLastScript: (ut) ->
      installWithMacro "Test/Undo", -> aegisub.set_undo_point "kept until the next script"
      shims.runMacro "Test/Undo"
      ut\assertEquals #shims.getUndoPoints!, 1
      shims.setScript assert AssScript.parse SOURCE
      ut\assertEquals #shims.getUndoPoints!, 0
  }
