-- Pins `aegisub.parse_karaoke_data`, which the faux global stands in for. What a line splits into is
-- the AssParser karaoke suite's subject. What this asserts is the shim's own half of the contract: that
-- it reads in Aegisub's dialect rather than a renderer's, and that it takes the lines Aegisub takes and
-- refuses the rest instead of reporting a failure a script would have to test for.
-- Called from test.moon as: (controls\requireTest "aegisub-karaoke")!
--
-- Which lines are taken and which refused was observed rather than derived:
-- `ass-investigation/observe-karaoke-refusals.moon` puts each of these tables to Aegisub and records
-- what came back, and `ass-investigation/check-karaoke-refusal-shim.moon` holds the verdict it gave
-- beside the shim's. The messages are ours, Aegisub's own being reproduced nowhere. A verdict changed
-- here without a run behind it is a regression test agreeing with itself.
->
  haveShims, shims = pcall require, "l0.AegisubShims"

  ---A dialogue line holding every field a dialogue line declares, plus the extradata Aegisub does not
  ---require and does not survive the absence of.
  ---@param text string The line's Text field.
  ---@return AegisubDialogueLine
  dialogueLine = (text) -> {
    class: "dialogue", comment: false, layer: 0, start_time: 0, end_time: 5000
    style: "Default", actor: "", effect: "", margin_l: 0, margin_r: 0, margin_t: 0, :text, extra: {}
  }

  ---The message a call threw, with the source position `error` prefixes stripped off, so an assertion
  ---reads against the message text alone.
  ---@param line any What to pass to the parser.
  ---@return string message
  refusalOf = (line) ->
    _, err = pcall aegisub.parse_karaoke_data, line
    (tostring err)\gsub "^.-%.moon:%d+: ", ""

  {
    _description: "The faux aegisub global's karaoke reading: Aegisub's dialect, and Aegisub's refusals."
    _condition: -> haveShims, "l0.AegisubShims isn't loaded (#{tostring shims})"

    -- Aegisub has kept an empty syllable at index 0 since 2.1.x, so `#result` counts the real ones
    parseKaraokeData_keepsTheIndexZeroFiller: (ut) ->
      syllables = aegisub.parse_karaoke_data dialogueLine "{\\k50}ab"
      ut\assertNotNil syllables[0]
      ut\assertEquals syllables[0].text, ""
      ut\assertEquals #syllables, 1

    parseKaraokeData_reportsOneSyllableWithoutAnyKaraokeTag: (ut) ->
      syllables = aegisub.parse_karaoke_data dialogueLine "plain text"
      ut\assertEquals #syllables, 1
      ut\assertEquals syllables[1].text_stripped, "plain text"

    -- Aegisub opens a syllable per karaoke tag and compares no appearance, where both renderers end
    -- one wherever a tag moves what is drawn. Asking for the wrong dialect here would report three.
    parseKaraokeData_readsInTheAegisubDialect: (ut) ->
      syllables = aegisub.parse_karaoke_data dialogueLine "{\\k50}a{\\b1}b{\\k50}c"
      ut\assertEquals #syllables, 2

    -- Aegisub reads every field through a check that coerces, so it takes a line this library's own
    -- shapes refuse, and converts the text the way Aegisub converts it before splitting it.
    parseKaraokeData_takesACoercibleFieldValue: (ut) ->
      numericText = dialogueLine 4200
      ut\assertEquals aegisub.parse_karaoke_data(numericText)[1].text_stripped, "4200"
      ut\assertNil shims.Ass.validateLine numericText, shims.Ass.LineClass.Dialogue

      numericLayer = dialogueLine "{\\k50}ab"
      numericLayer.layer = "3"
      ut\assertEquals #aegisub.parse_karaoke_data(numericLayer), 1

    -- the class is lowercased before it is matched, so a line naming it either way is accepted
    parseKaraokeData_takesTheClassInAnyCase: (ut) ->
      capitalized = dialogueLine "{\\k50}ab"
      capitalized.class = "Dialogue"
      ut\assertEquals #aegisub.parse_karaoke_data(capitalized), 1

    -- The class is what a line of the wrong one is refused for, whatever else is also wrong with it.
    -- Aegisub reads the other class's fields first and reports one of those, which is not reproduced:
    -- the class is the answer a caller asking for a dialogue line needs.
    parseKaraokeData_rejectsAnotherClass: (ut) ->
      style = shims.Ass.createStyle name: "Default"
      style.class = "style"
      ut\assertMatches refusalOf(style), "Expected a 'dialogue' line, got a 'style' one"

      style.fontname = nil
      ut\assertMatches refusalOf(style), "Expected a 'dialogue' line, got a 'style' one"

    parseKaraokeData_rejectsATableItCannotRead: (ut) ->
      ut\assertMatches refusalOf("not a line"), "has to be a table"
      ut\assertMatches refusalOf(42), "has to be a table"
      ut\assertMatches refusalOf(nil), "has to be a table"
      ut\assertMatches refusalOf({}), "has to state its class"

      unknown = dialogueLine "{\\k50}ab"
      unknown.class = "comment"
      ut\assertMatches refusalOf(unknown), "'comment' is not a subtitle line class"

    -- Aegisub checks every field of a line before reading any of it, so it refuses one missing a field
    -- the karaoke split never reads. A partial line passing here would fail the moment it ran there.
    parseKaraokeData_rejectsALineAegisubWouldRefuse: (ut) ->
      missingText = dialogueLine "{\\k50}ab"
      missingText.text = nil
      ut\assertMatches refusalOf(missingText), "'text' %(expected string%)"

      wrongType = dialogueLine "{\\k50}ab"
      wrongType.comment = 0
      ut\assertMatches refusalOf(wrongType), "'comment' %(expected boolean%)"

      -- every field at fault is named at once, in the order a line declares them
      bothMissing = dialogueLine "{\\k50}ab"
      bothMissing.text, bothMissing.margin_r = nil, nil
      ut\assertMatches refusalOf(bothMissing), "'margin_r' %(expected number%), 'text' %(expected string%)"

    -- Extradata is the field Aegisub reads without requiring, and before 3.5.0 the one it does not
    -- survive: it drops the value again only where it found a table, so a line without one leaves the
    -- stack holding it and Aegisub crashes. Refusing one is what keeps a script clear of that.
    parseKaraokeData_rejectsUnusableExtradata: (ut) ->
      withExtra = dialogueLine "{\\k50}ab"
      withExtra.extra = {note: "kept"}
      ut\assertEquals #aegisub.parse_karaoke_data(withExtra), 1

      badExtra = dialogueLine "{\\k50}ab"
      badExtra.extra = "not a table"
      ut\assertMatches refusalOf(badExtra), "extradata has to be a table"

      -- the library takes a line without one, extradata being optional to everything but Aegisub
      noExtra = dialogueLine "{\\k50}ab"
      noExtra.extra = nil
      ut\assertTrue shims.Ass.validateLine noExtra, shims.Ass.LineClass.Dialogue
      ut\assertMatches refusalOf(noExtra), "crashes on one without it"
  }
