-- Pins the karaoke reader in all three dialects. Aegisub's reading is what the shim installs, so the
-- reported shape is asserted against it: the index-zero filler, the `\K` rename, and the dropping of
-- an empty syllable mid-line but not at the end. The other two are asserted on where a syllable ends,
-- which is the whole of what separates them from Aegisub and from each other.
-- Called from test.moon as: (controls\requireTest "karaoke")!
--
-- Every expectation in `segmentationCases` was observed by rendering, not derived: each was put to
-- libass and VSFilter as a karaoke probe, where the sweep color says whether the text after a tag is
-- sung with what precedes it or waits for the next syllable. The probes live in
-- `ass-investigation/observe-in-libass.moon` and its VSFilter counterpart. A row changed here without
-- a probe to back it is a regression test agreeing with itself.
->
  karaoke = require "l0.AssParser.karaoke"
  {:LineClass, :WrapStyle, :createStyle} = require "l0.AssParser.ass"
  {:DialectName, :TagName, :getOverrideTag} = require "l0.AssParser.dialects"

  readers = {name, karaoke.Reader name for name in *DialectName.values}

  ---Builds the one shape `parseKaraokeData` accepts.
  ---@param text string The line's Text field.
  ---@return AegisubDialogueLine
  dialogueLine = (text) -> {class: LineClass.Dialogue, :text}

  ---What one dialect reports a line as, which is where an empty leading syllable has been folded away.
  ---`splitSyllables` is the raw split and keeps the span a line opens under before its first karaoke
  ---tag, so a count taken from it is one higher wherever that span survives.
  ---@param dialect AssDialectName
  ---@param text string The line's Text field.
  ---@return AegisubKaraokeData
  syllablesOf = (dialect, text) -> assert readers[dialect]\parseKaraokeData dialogueLine text

  ---The karaoke tag opening each syllable, joined, which is what a timing assertion reads against.
  ---@param syllables AegisubKaraokeData
  ---@return string
  describeTags = (syllables) ->
    table.concat [syllables[index].tag for index = 1, #syllables], " "

  ---The start and duration of every syllable, as `start+duration` pairs.
  ---@param syllables AegisubKaraokeData
  ---@return string
  describeTimes = (syllables) ->
    table.concat ["#{syllables[index].start_time}+#{syllables[index].duration}" for index = 1, #syllables], " "

  -- How many syllables each renderer splits a line into, every row observed by probing both. The
  -- style is the format's default: Arial 48, not bold, not italic, a 2px border, encoding 1, no blur.
  -- A tag writing one of those values back moves nothing, which is what leaves a syllable open.
  segmentationCases = {
    -- the karaoke tags' own rules, which do not consult the appearance at all
    {name: "zeroDurationUnderTheSameType", text: "{\\k50}a{\\k0}b", libass: 1, vsfilter: 1}
    {name: "zeroDurationUnderAnotherType", text: "{\\k50}a{\\kf0}b", libass: 2, vsfilter: 2}
    {name: "absoluteTagEndsNoSyllable", text: "{\\k50}a{\\kt100}b", libass: 1, vsfilter: 1}

    -- Neither renderer compares a drawing scale, so a `\p` pair with nothing between them moves
    -- nothing. What a drawing itself does to a syllable is asserted by timing rather than counted
    -- here, since the span it is reported in draws nothing a sweep can show.
    {name: "emptyDrawingModePairEndsNothing", text: "{\\k50}a{\\p1}{\\p0}b", libass: 1, vsfilter: 1}

    -- a tag writing the value already in force leaves the syllable open
    {name: "weightAlreadyInForce", text: "{\\k50}a{\\b0}b", libass: 1, vsfilter: 1}
    {name: "weightThatMoves", text: "{\\k50}a{\\b1}b", libass: 2, vsfilter: 2}
    {name: "sizeAlreadyInForce", text: "{\\k50}a{\\fs48}b", libass: 1, vsfilter: 1}
    {name: "sizeThatMoves", text: "{\\k50}a{\\fs60}b", libass: 2, vsfilter: 2}
    -- A signed argument scales the size in force by a tenth of what it names rather than naming one,
    -- so `\fs+10` doubles the style's 48 and the explicit 96 after it writes the value already set.
    -- Aegisub never sees this: it declares `\fs+` and `\fs-` as names of their own.
    {name: "signedSizeScalesRatherThanSets", text: "{\\k50}{\\fs+10}a{\\fs96}b", libass: 1, vsfilter: 1}
    {name: "signedSizeIsNotTheNumberItNames", text: "{\\k50}{\\fs+10}a{\\fs10}b", libass: 2, vsfilter: 2}
    {name: "signedSizeOfZeroScalesByOne", text: "{\\k50}a{\\fs+0}b", libass: 1, vsfilter: 1}
    -- A size landing at or below zero puts the style's own back rather than being held at zero, which
    -- is a restore and not a clamp. The check is on the result, so a scale that falls to zero restores
    -- as surely as a zero written outright.
    {name: "zeroSizeRestoresTheStyleSize", text: "{\\k50}a{\\fs0}b", libass: 1, vsfilter: 1}
    {name: "scalingToZeroRestoresTheStyleSize", text: "{\\k50}a{\\fs-10}b", libass: 1, vsfilter: 1}
    -- and one that lands above zero is taken, so the rule is not swallowing every signed size
    {name: "scalingHalfwayIsTaken", text: "{\\k50}a{\\fs-5}b", libass: 2, vsfilter: 2}
    {name: "slantAlreadyInForce", text: "{\\k50}a{\\i0}b", libass: 1, vsfilter: 1}
    {name: "scaleAlreadyInForce", text: "{\\k50}a{\\fscx100}b", libass: 1, vsfilter: 1}
    {name: "borderAlreadyInForce", text: "{\\k50}a{\\bord2}b", libass: 1, vsfilter: 1}
    {name: "faceAlreadyInForce", text: "{\\k50}a{\\fnArial}b", libass: 1, vsfilter: 1}
    {name: "anotherFace", text: "{\\k50}a{\\fnComic Sans MS}b", libass: 2, vsfilter: 2}
    {name: "shadowColorThatMoves", text: "{\\k50}a{\\4c&H0000FF&}b", libass: 2, vsfilter: 2}

    -- a bare tag puts the style's value back, which moves nothing from a fresh state
    {name: "bareTagRestoresTheStyleSize", text: "{\\k50}a{\\fs}b", libass: 1, vsfilter: 1}
    {name: "bareTagRestoresFromAChangedSize", text: "{\\k50}{\\fs60}a{\\fs}b", libass: 2, vsfilter: 2}
    {name: "fontNameZeroRestoresTheStyleFace", text: "{\\k50}{\\fnComic Sans MS}a{\\fn0}b", libass: 2, vsfilter: 2}

    -- A value outside what a tag accepts puts the style's back rather than reading as true. `\b` takes
    -- 0, 1 or 100 upwards and the three switches take 0 or 1, with both bounds of the weight probed.
    {name: "weightBelowTheAcceptedRange", text: "{\\k50}a{\\b50}b", libass: 1, vsfilter: 1}
    {name: "weightRefusesTwo", text: "{\\k50}a{\\b2}b", libass: 1, vsfilter: 1}
    {name: "weightRefusesNinetyNine", text: "{\\k50}a{\\b99}b", libass: 1, vsfilter: 1}
    {name: "weightTakesOneHundred", text: "{\\k50}a{\\b100}b", libass: 2, vsfilter: 2}
    {name: "flagOutsideZeroAndOne", text: "{\\k50}a{\\i5}b", libass: 1, vsfilter: 1}
    {name: "flagRefusesANegative", text: "{\\k50}a{\\i-1}b", libass: 1, vsfilter: 1}
    -- an argument is read as a whole number, so 1.5 switches the underline on rather than being refused
    {name: "flagReadsAWholeNumberOnly", text: "{\\k50}a{\\u1.5}b", libass: 2, vsfilter: 2}

    -- `\r` reseeds every field from a style
    {name: "resetToTheStyleInForce", text: "{\\k50}a{\\r}b", libass: 1, vsfilter: 1}
    {name: "resetUndoingATag", text: "{\\k50}{\\b1}a{\\r}b", libass: 2, vsfilter: 2}

    -- neither renderer lets these go below zero, so a clamped value is the one already in force
    {name: "negativeBlurClamps", text: "{\\k50}a{\\blur-5}b", libass: 1, vsfilter: 1}
    {name: "negativeBorderClampsAwayFromTheStyle", text: "{\\k50}a{\\bord-2}b", libass: 2, vsfilter: 2}
    {name: "negativeBorderClampsOntoZero", text: "{\\k50}{\\bord0}a{\\bord-2}b", libass: 1, vsfilter: 1}
    {name: "negativeShadowClamps", text: "{\\k50}{\\shad0}a{\\shad-2}b", libass: 1, vsfilter: 1}
    -- one axis of the same field, which both leave alone where they clamp `\shad`
    {name: "negativeShadowAxisDoesNotClamp", text: "{\\k50}{\\xshad0}a{\\xshad-2}b", libass: 2, vsfilter: 2}

    -- `\t` ends a syllable exactly where the tag it animates would have. The style's shadow color is
    -- already black, so the second animates to the value in force and moves nothing.
    {name: "transformOfAComparedField", text: "{\\k50}a{\\t(0,100,\\4c&H0000FF&)}b", libass: 2, vsfilter: 2}
    {name: "transformToTheValueInForce", text: "{\\k50}a{\\t(0,100,\\4c&H000000&)}b", libass: 1, vsfilter: 1}
    {name: "transformWithoutTimes", text: "{\\k50}a{\\t(\\4c&H0000FF&)}b", libass: 2, vsfilter: 2}
    {name: "transformOfAScaleToTheValueInForce", text: "{\\k50}a{\\t(0,100,\\fscx100)}b", libass: 1, vsfilter: 1}
    -- no comparison reads a clip, so animating one ends nothing however far it has moved
    {name: "transformOfAFieldNoComparisonReads", text: "{\\k50}a{\\t(0,100,\\clip(0,0,9,9))}b", libass: 1, vsfilter: 1}

    -- A run ends where the line actually breaks rather than where the break is written, so `\N`
    -- always ends a syllable and `\n` ends one only under wrap style 2. A `\q` moves the style from
    -- where it stands onwards, so one written after a break does not reach back to it, and a bare one
    -- puts the script's own back.
    {name: "hardBreak", text: "{\\k50}aa\\Nbb", libass: 2, vsfilter: 2}
    {name: "hardBreakUnderASweep", text: "{\\kf100}aa\\Nbb", libass: 2, vsfilter: 2}
    {name: "softBreakUnderWrapStyleTwo", text: "{\\q2}{\\k50}aa\\nbb", libass: 2, vsfilter: 2}
    {name: "softBreakUnderSmartWrapping", text: "{\\q0}{\\k50}aa\\nbb", libass: 1, vsfilter: 1}
    {name: "softBreakWithNoWrapStyleStated", text: "{\\k50}aa\\nbb", libass: 1, vsfilter: 1}
    {name: "softBreakUnderTheScriptsWrapStyle", text: "{\\k50}aa\\nbb", wrapStyle: 2, libass: 2, vsfilter: 2}
    {name: "wrapStyleAfterTheBreak", text: "{\\k50}aa\\nbb{\\q2}", libass: 1, vsfilter: 1}
    {name: "bareWrapStyleRestoresTheScripts", text: "{\\q2}{\\k50}aa\\nbb{\\q}cc\\ndd", libass: 2, vsfilter: 2}
    -- asked against a script stating 2, since under the default 0 restoring the script's value and
    -- keeping 9 both read as "not 2" and render alike
    {name: "outOfRangeWrapStyleRestoresTheScripts", text: "{\\q0}{\\k50}aa\\nbb{\\q9}cc\\ndd", wrapStyle: 2, libass: 2, vsfilter: 2}
    -- The one place the two part over a break. libass asks whether the style is the no-wrap one, so
    -- nothing else breaks; VSFilter asks whether it is one of the three that wrap, so everything else
    -- does. Neither range-checks what a script states, and only a script stating above 3 gets here.
    {name: "scriptWrapStyleAboveTheDeclaredOnes", text: "{\\k50}aa\\nbb", wrapStyle: 9, libass: 1, vsfilter: 2}
    -- an argument holding no number converts to zero rather than restoring the script's style
    {name: "junkWrapStyleArgumentReadsAsZero", text: "{\\qabc}{\\k50}aa\\nbb", wrapStyle: 2, libass: 1, vsfilter: 1}

    -- where the two comparisons themselves differ
    {name: "characterSet", text: "{\\k50}a{\\fe0}b", libass: 1, vsfilter: 2}
    {name: "weightAgainstAnExplicitWeight", text: "{\\k50}{\\b1}a{\\b700}b", libass: 2, vsfilter: 1}
    {name: "blurEdgesRounding", text: "{\\k50}{\\be1}a{\\be0.6}b", libass: 1, vsfilter: 2}
    {name: "blurEdgesRoundingDown", text: "{\\k50}{\\be1}a{\\be1.4}b", libass: 1, vsfilter: 2}
    {name: "negativeBlurEdges", text: "{\\k50}a{\\be-3}b", libass: 1, vsfilter: 2}
  }

  -- What Aegisub splits the same shapes into, which never consults the appearance: a syllable runs
  -- from one karaoke tag to the next and no other tag ends one.
  aegisubCases = {
    {name: "everyKaraokeTagOpensASyllable", text: "{\\k50}a{\\k0}b", count: 2}
    {name: "anAppearanceTagOpensNone", text: "{\\k50}a{\\b1}b", count: 1}
    {name: "aColorTagOpensNone", text: "{\\k50}a{\\4c&H0000FF&}b", count: 1}
    {name: "textWithoutKaraokeIsOneSyllable", text: "plain text", count: 1}
    -- Aegisub compares no runs, so a break is text like any other and its report keeps it verbatim
    {name: "aLineBreakOpensNoSyllable", text: "{\\k50}a\\Nb", count: 1}
    -- `\kt` is unknown to Aegisub, so its scan falls back onto `\k` and it does open one
    {name: "absoluteTagFallsBackToKaraoke", text: "{\\k50}a{\\kt100}b", count: 2}
  }

  tests = {
    _description: "The karaoke reader in all three dialects: Aegisub's reported shape, and where each
      of the two renderers ends a syllable."

    new_defaultsToAegisub: (ut) ->
      ut\assertEquals karaoke.Reader!.dialect, DialectName.Aegisub

    -- a class is a callable table rather than a function, so the construction is wrapped in one
    new_rejectsAnUnknownDialect: (ut) ->
      ut\assertError -> karaoke.Reader "noSuchDialect"

    -- an enum key where its value belongs is the likely mistake, and the error has to say so rather
    -- than report a declared dialect whose karaoke model is missing
    new_rejectsADialectKeyWhereItsValueBelongs: (ut) ->
      ut\assertErrorMsgMatches (-> karaoke.Reader "Libass"), {}, "AssDialectName"

    new_buildsOneForEveryDeclaredDialect: (ut) ->
      missing = [name for name in *DialectName.values when not pcall karaoke.Reader, name]
      ut\assertEquals table.concat(missing, " "), ""

    parseKaraokeData_rejectsANonDialogueLine: (ut) ->
      syllables, err = karaoke.parseKaraokeData {class: LineClass.Style}
      ut\assertNil syllables
      ut\assertString err

    parseKaraokeData_rejectsANonTable: (ut) ->
      syllables, err = karaoke.parseKaraokeData "not a line"
      ut\assertNil syllables
      ut\assertString err

    -- Aegisub has kept an empty syllable at index 0 since 2.1.x, so `#result` counts the real ones
    parseKaraokeData_keepsTheIndexZeroFiller: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k50}ab"
      ut\assertNotNil syllables[0]
      ut\assertEquals syllables[0].text, ""
      ut\assertEquals syllables[0].duration, 0
      ut\assertEquals #syllables, 1

    parseKaraokeData_reportsOneSyllableWithoutAnyKaraokeTag: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "plain text"
      ut\assertEquals #syllables, 1
      ut\assertEquals syllables[1].text_stripped, "plain text"
      ut\assertEquals syllables[1].duration, 0

    parseKaraokeData_timesRunFromTheLineStart: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k50}a{\\k30}b{\\k20}c"
      ut\assertEquals describeTimes(syllables), "0+500 500+300 800+200"
      ut\assertEquals syllables[3].end_time, 1000

    -- nothing is normalized against the line's end, so a syllable may run past it
    parseKaraokeData_doesNotNormalizeAgainstTheLineEnd: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k9999}a"
      ut\assertEquals syllables[1].duration, 99990

    parseKaraokeData_reportsLegacyFillUnderTheNewerName: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\K50}ab"
      ut\assertEquals syllables[1].tag, getOverrideTag TagName.KaraokeFill

    parseKaraokeData_reportsEachKaraokeTagAsItWasWritten: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k50}a{\\kf30}b{\\ko20}c"
      ut\assertEquals describeTags(syllables), "\\k \\kf \\ko"

    -- a syllable holding no text and no duration is dropped, but only where one follows it
    parseKaraokeData_dropsAnEmptySyllableMidLine: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k0}{\\k30}ab"
      ut\assertEquals #syllables, 1
      ut\assertEquals syllables[1].text_stripped, "ab"

    parseKaraokeData_keepsAnEmptySyllableAtTheEnd: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k30}ab{\\k0}"
      ut\assertEquals #syllables, 2
      ut\assertEquals syllables[2].text_stripped, ""

    parseKaraokeData_keepsAnEmptySyllableThatHoldsADuration: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k50}{\\k30}ab"
      ut\assertEquals describeTimes(syllables), "0+500 500+300"

    -- the overrides of a dropped syllable belong to whatever follows it
    parseKaraokeData_carriesOverridesOutOfADroppedSyllable: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k0\\b1}{\\k30}ab"
      ut\assertEquals #syllables, 1
      ut\assertEquals syllables[1].text_stripped, "ab"
      ut\assertNotNil syllables[1].text\find "\\b1", 1, true

    parseKaraokeData_splicesOverridesBackIntoTheText: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k50}a{\\b1}b"
      ut\assertEquals syllables[1].text, "a{\\b1}b"
      ut\assertEquals syllables[1].text_stripped, "ab"

    -- A drawing is sung on the timing of the syllable it falls in, and the text after it opens the
    -- next one. Under one `\k` covering two shapes and a tail, the first shape is sung on that `\k`
    -- and everything after it waits, which is what the tail's start time records here. Observed by
    -- eye in both renderers: the first shape whitens at 2s, the second and the tail together at 4s.
    splitSyllables_aDrawingTakesItsSyllablesTiming: (ut) ->
      shape = "{\\p1}m 0 0 l 40 0 l 40 40 l 0 40{\\p0}"
      bigger = "{\\p2}m 0 0 l 40 0 l 40 40 l 0 40{\\p0}"
      line = "{\\k200}AA {\\k200}#{shape}#{bigger} ZZ"

      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        spans = karaoke.Reader(dialectName)\splitSyllables line
        ut\assertEquals #spans, 4
        ut\assertEquals spans[1].text, "AA "
        ut\assertEquals spans[1].startTime, 0
        ut\assertEquals spans[1].duration, 2000
        -- the first shape takes that `\k` whole, so the second one and the tail both wait on it
        ut\assertEquals spans[2].startTime, 2000
        ut\assertEquals spans[2].duration, 2000
        ut\assertEquals spans[3].startTime, 4000
        ut\assertEquals spans[4].text, " ZZ"
        ut\assertEquals spans[4].startTime, 4000

      -- Aegisub splits on karaoke tags alone, so the tail is sung on the second `\k` at 2s
      aegisub = karaoke.Reader(DialectName.Aegisub)\splitSyllables line
      ut\assertEquals aegisub[#aegisub].startTime, 2000

    -- The drawing splits away from text before it, but keeps a syllable a karaoke tag has only just
    -- opened. Both were needed: sharing with the leading text would sing this shape at 0s, and always
    -- opening its own would push the shape in `aDrawingTakesItsSyllablesTiming` out to 4s. Observed by
    -- eye in both renderers, where the shape and the tail whiten together at 2s.
    splitSyllables_aDrawingSplitsFromTheTextBeforeIt: (ut) ->
      line = "{\\k200}AA{\\p1}m 0 0 l 40 0 l 40 40 l 0 40{\\p0} ZZ"

      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        spans = karaoke.Reader(dialectName)\splitSyllables line
        ut\assertEquals #spans, 3
        ut\assertEquals spans[1].text, "AA"
        ut\assertEquals spans[1].duration, 2000
        -- the shape is not sung with `AA`, so it and the tail both start where `AA` ended
        ut\assertEquals spans[2].startTime, 2000
        ut\assertEquals spans[3].text, " ZZ"
        ut\assertEquals spans[3].startTime, 2000

    -- A drawing ends the syllable it falls in, never the `\p` that opened drawing mode. Observed as a
    -- sweep in both renderers, where `a` is sung at 0 and `b` at 500ms. The shape is degenerate so that
    -- only the karaoke differs, which is also why no sweep can show the span it is reported in.
    splitSyllables_aDrawingEndsTheSyllable: (ut) ->
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        spans = karaoke.Reader(dialectName)\splitSyllables "{\\k50}a{\\p1}m 0 0{\\p0}b"
        ut\assertEquals #spans, 3
        ut\assertEquals spans[1].text, "a"
        ut\assertEquals spans[2].startTime, 500
        ut\assertEquals spans[3].text, "b"
        ut\assertEquals spans[3].startTime, 500

    -- A tag on a syllable a karaoke tag has only just opened finds no text to end, so the syllable
    -- stays open and its duration goes to the text after the tag. Observed in both renderers by
    -- rebuilding the line with one transform per syllable and watching it beside the original, where
    -- `ra` is sung at 1s.
    splitSyllables_aTagOnAFreshSyllableEndsNothing: (ut) ->
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        spans = karaoke.Reader(dialectName)\splitSyllables "{\\k100}Ka{\\k100}{\\b1}ra{\\k100}o"
        ut\assertEquals #spans, 3
        ut\assertEquals spans[2].text, "ra"
        ut\assertEquals spans[2].startTime, 1000
        -- the tag ends the syllable once text has taken it, which is what leaves `a` at 2s
        withText = karaoke.Reader(dialectName)\splitSyllables "{\\k100}Ka{\\k100}r{\\b1}a{\\k100}o"
        ut\assertEquals withText[3].text, "a"
        ut\assertEquals withText[3].startTime, 2000

    -- A drawing under a karaoke tag of its own is reported as a syllable starting when that tag says,
    -- holding the drawing in its text and nothing in the stripped text. Observed in both renderers by
    -- rebuilding the line from this reading, where the shape whitens at 2s and `ke` at 3s.
    parseKaraokeData_reportsADrawingsOwnSyllable: (ut) ->
      line = "{\\k100}Ka{\\k100}ra{\\k100}{\\p1}m 0 0 l 30 0 l 30 30 l 0 30{\\p0}{\\k100}ke"

      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        syllables = syllablesOf dialectName, line
        ut\assertEquals #syllables, 4
        ut\assertEquals syllables[3].start_time, 2000
        ut\assertEquals syllables[3].text_stripped, ""
        -- the `\p0` closing drawing mode falls after the boundary, so it opens the following syllable
        ut\assertEquals syllables[4].text, "{\\p0}ke"
        ut\assertEquals syllables[4].start_time, 3000

    -- One section per override block, so two blocks running together stay apart while the tags of a
    -- single block stay together. Both spell the same line, which the reassembled text holds them to.
    splitSyllables_separatesOverrideBlocksThatRunTogether: (ut) ->
      apart = readers[DialectName.Libass]\splitSyllables("{\\k50}{\\b1}{\\i1}a")[1]
      ut\assertEquals #apart.strippedSections, 2
      ut\assertEquals apart.strippedSections[1].text, "{\\b1}"
      ut\assertEquals apart.strippedSections[2].text, "{\\i1}"
      ut\assertEquals apart.strippedSections[2].textOffset, apart.strippedSections[1].textOffset
      ut\assertEquals apart\withStrippedSections!, "{\\b1}{\\i1}a"

      together = readers[DialectName.Libass]\splitSyllables("{\\k50}{\\b1\\i1}a")[1]
      ut\assertEquals #together.strippedSections, 1
      ut\assertEquals together\withStrippedSections!, "{\\b1\\i1}a"

    -- A drawing and the override block that switched into it sit at the same offset, so a section's
    -- kind is the only thing telling the two apart.
    splitSyllables_separatesADrawingFromTheBlockBeforeIt: (ut) ->
      spans = readers[DialectName.Libass]\splitSyllables "{\\k50}{\\p1}m 0 0 l 9 9{\\p0}"
      sections = spans[1].strippedSections

      ut\assertEquals #sections, 2
      ut\assertEquals sections[1].kind, karaoke.SectionKind.OverrideBlock
      ut\assertEquals sections[1].text, "{\\p1}"
      ut\assertEquals sections[2].kind, karaoke.SectionKind.Drawing
      ut\assertEquals sections[2].text, "m 0 0 l 9 9"
      ut\assertEquals sections[2].textOffset, sections[1].textOffset
      ut\assertEquals spans[1]\hasDrawing!, true

    parseKaraokeData_holdsADrawingOutOfTheStrippedText: (ut) ->
      syllables = karaoke.parseKaraokeData dialogueLine "{\\k50}{\\p1}m 0 0 l 9 9{\\p0}"
      ut\assertEquals syllables[1].text_stripped, ""

    -- Aegisub declares the karaoke tags as taking an integer, so it truncates a decimal duration
    parseKaraokeData_truncatesADecimalDurationForAegisub: (ut) ->
      ut\assertEquals syllablesOf(DialectName.Aegisub, "{\\k50.9}ab")[1].duration, 500
      ut\assertEquals syllablesOf(DialectName.Aegisub, "{\\k30.5}ab")[1].duration, 300

    -- .5 is the fraction a truncated read and a rounded one disagree on, and both renderers put the
    -- next syllable's start at 305ms rather than 310
    parseKaraokeData_keepsADecimalDurationForTheRenderers: (ut) ->
      ut\assertEquals syllablesOf(DialectName.Libass, "{\\k50.9}ab")[1].duration, 509
      ut\assertEquals syllablesOf(DialectName.Libass, "{\\k30.5}ab")[1].duration, 305
      ut\assertEquals syllablesOf(DialectName.XyVsfilter, "{\\k30.5}ab")[1].duration, 305

    -- only a missing argument takes the dialect's default; one holding no number counts as zero
    parseKaraokeData_emptyArgumentTakesNothingForAegisub: (ut) ->
      ut\assertEquals syllablesOf(DialectName.Aegisub, "{\\k}ab")[1].duration, 0

    parseKaraokeData_emptyArgumentTakesASecondForTheRenderers: (ut) ->
      ut\assertEquals syllablesOf(DialectName.Libass, "{\\k}ab")[1].duration, 1000

    parseKaraokeData_unreadableArgumentCountsAsZero: (ut) ->
      ut\assertEquals syllablesOf(DialectName.Libass, "{\\k?}ab")[1].duration, 0

    -- `\kt` sets where the next syllable starts without ending the one it sits in
    splitSyllables_absoluteTagSetsTheNextStart: (ut) ->
      spans = readers[DialectName.Libass]\splitSyllables "{\\kf50}aaa{\\kt100}bbb{\\kf20}ccc"
      ut\assertEquals spans[#spans].startTime, 1000

    -- a style the line is set in is what a redundant tag is compared against, so the same line
    -- splits differently under a style already declaring what the tag writes
    splitSyllables_comparesAgainstTheGivenStyle: (ut) ->
      boldStyle = createStyle bold: true
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables("{\\k50}a{\\b1}b", boldStyle), 1
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables("{\\k50}a{\\b0}b", boldStyle), 2

    -- Both renderers hold a style's own scale, spacing, outline and shadow to zero as they read the
    -- style line, so a style declaring a negative one begins at zero and a tag writing zero moves
    -- nothing. This is the style parser's doing, and differs from the tags. `\xshad` keeps a negative
    -- argument where `\shad` refuses one, but a style's Shadow is clamped whichever wrote it.
    splitSyllables_clampsANegativeStyleWidth: (ut) ->
      style = createStyle outline: -5, shadow: -5, spacing: -9
      for dialect in *{DialectName.Libass, DialectName.XyVsfilter}
        reader = readers[dialect]
        ut\assertEquals #reader\splitSyllables("{\\k50}a{\\bord0}b", style), 1
        ut\assertEquals #reader\splitSyllables("{\\k50}a{\\xshad0}b", style), 1
        ut\assertEquals #reader\splitSyllables("{\\k50}a{\\fsp0}b", style), 1
        -- and the clamped zero is what a moving value is measured against
        ut\assertEquals #reader\splitSyllables("{\\k50}a{\\bord2}b", style), 2

    splitSyllables_clampsANegativeStyleScale: (ut) ->
      style = createStyle scale_x: -50
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables("{\\k50}a{\\fscx0}b", style), 1

    -- One dialect folds every border style but the opaque box onto one value as it reads a style line,
    -- so two styles differing only between 1 and 2 are one style to it and two to the other. No tag
    -- writes the field, so a `\r` between two such styles is the only way to reach this at all.
    splitSyllables_foldsTheBorderStyleInOneDialectOnly: (ut) ->
      stylesByName = Outlined: createStyle(name: "Outlined", borderstyle: 2)
      text = "{\\k50}a{\\rOutlined}b"
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables(text, nil, stylesByName), 2
      ut\assertEquals #readers[DialectName.XyVsfilter]\splitSyllables(text, nil, stylesByName), 1

    -- Two values the format gives no meaning to are still two values to the dialect comparing the
    -- number, and one to the dialect comparing what it understood. Both draw the same outline, so
    -- this separates the two readings on nothing but the number itself.
    splitSyllables_meaninglessBorderStylesStillEndARunInOneDialect: (ut) ->
      stylesByName =
        Two: createStyle(name: "Two", borderstyle: 2)
        Five: createStyle(name: "Five", borderstyle: 5)
      text = "{\\k50}{\\rTwo}a{\\rFive}b"
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables(text, nil, stylesByName), 2
      ut\assertEquals #readers[DialectName.XyVsfilter]\splitSyllables(text, nil, stylesByName), 1

    -- the opaque box is the one value both keep apart, so it ends a run in either
    splitSyllables_opaqueBoxEndsARunInBoth: (ut) ->
      stylesByName = Boxed: createStyle(name: "Boxed", borderstyle: 3)
      text = "{\\k50}a{\\rBoxed}b"
      for dialect in *{DialectName.Libass, DialectName.XyVsfilter}
        ut\assertEquals #readers[dialect]\splitSyllables(text, nil, stylesByName), 2

    splitSyllables_resetReachesANamedStyle: (ut) ->
      stylesByName = Other: createStyle name: "Other", fontsize: 72
      text = "{\\k50}a{\\rOther}b"
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables(text, nil, stylesByName), 2
      -- with no such style the reset falls back to the line's own, which changes nothing here
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables(text), 1
  }

  tests.splitSyllables_aBreakEndsTheSyllableItFollows = (ut) ->
    spans = readers[DialectName.Libass]\splitSyllables "{\\k50}aa\\Nbb"
    ut\assertEquals spans[1].text, "aa\\N"
    ut\assertEquals spans[2].text, "bb"

  -- A script may state a wrap style no renderer range-checks, and above the declared range the two
  -- part: libass asks whether the style is the no-wrap one, VSFilter whether it is one of the three
  -- that wrap, so `\n` breaks in VSFilter alone. Observed in both, and the one soft-break divergence.
  tests.splitSyllables_anOutOfRangeScriptWrapStylePartsTheRenderers = (ut) ->
    line = "{\\k50}aa\\nbb"

    for wrapStyle in *{WrapStyle.SmartTopWider, WrapStyle.NoWordWrap}
      ut\assertEquals #readers[DialectName.Libass]\splitSyllables(line, nil, nil, wrapStyle),
        #readers[DialectName.XyVsfilter]\splitSyllables(line, nil, nil, wrapStyle)

    ut\assertEquals #readers[DialectName.Libass]\splitSyllables(line, nil, nil, 9), 1
    ut\assertEquals #readers[DialectName.XyVsfilter]\splitSyllables(line, nil, nil, 9), 2

  tests.parseKaraokeData_keepsALineBreakInTheSyllableText = (ut) ->
    syllables = syllablesOf DialectName.Aegisub, "{\\k50}a\\Nb"
    ut\assertEquals syllables[1].text, "a\\Nb"

  for case in *segmentationCases
    for dialect in *{DialectName.Libass, DialectName.XyVsfilter}
      expected = case[dialect]
      tests["splitSyllables_#{case.name}_#{dialect}"] = (ut) ->
        ut\assertEquals #readers[dialect]\splitSyllables(case.text, nil, nil, case.wrapStyle), expected

  for case in *aegisubCases
    tests["parseKaraokeData_#{case.name}_aegisub"] = (ut) ->
      ut\assertEquals #syllablesOf(DialectName.Aegisub, case.text), case.count

  tests
