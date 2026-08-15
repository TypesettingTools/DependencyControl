-- cspell:ignore Iczaka -- a signature quoted verbatim from a corpus script
-- cspell:ignore bordd -- a misspelling written on purpose, to show a tag name matched by prefix
-- cspell:ignore HFFFFFF -- a color literal written out in a fixture, not a word
--
-- Checks the recorded value equivalences against an oracle that derives them, so a row claiming a
-- rewrite is safe where the model says otherwise fails here rather than misleading a normalizer later.
-- Called from test.moon as: (controls\requireTest "diagnostics")!
--
-- The two sides are independent on purpose. `equivalences` is a hand-written record of what probing
-- the renderers established; the oracle asks the scanner, the run state and the karaoke reader what
-- a line reads as. A row and the oracle agreeing means the model reproduces an observation. Where they
-- disagree, one of the two is wrong and the failure names which row to go and re-probe.
->
  diagnostics = require "l0.AssParser.diagnostics"
  {:DialectName} = require "l0.AssParser.dialects"
  {:defaultStyle} = require "l0.AssParser.ass"
  {:isEquivalent, :describeLine, :describeCanonicalAppearance, :describeKaraokeSyllables} = diagnostics
  {:groupDialectsByKaraokeReading, :equivalences} = diagnostics
  {:FindingCode, :Severity, :findLineDefects} = diagnostics

  declaredStyles = {Declared: defaultStyle}

  ---The codes a line's findings report, joined, which is what an assertion reads against.
  ---@param findings AssFinding[]
  ---@return string
  describeCodes = (findings) -> table.concat [finding.code for finding in *findings], " "

  renderers = {DialectName.Libass, DialectName.XyVsfilter}

  ---The dialects a row claims the rewrite is safe for, as a set.
  ---@param row AssEquivalence
  ---@return table<string, true>
  claimedBy = (row) -> {name, true for name in *row.dialects}

  ---Describes a grouping as the dialects in each group, so a failure names who agreed with whom rather
  ---than reporting that some number of readings happened.
  ---@param groups AssDialectName[][]
  ---@return string
  describeGroups = (groups) ->
    table.concat [table.concat(group, "+") for group in *groups], " | "

  tests = {
    _description: "Checks each recorded value equivalence against an oracle deriving the same answer
      from the scanner, the run state and the karaoke reader, and pins the cross-dialect grouping a
      diagnostics layer would report."

    equivalences_holdExactlyWhereTheyAreClaimed: (ut) ->
      offenders = {}
      for row in *equivalences
        claimed = claimedBy row
        for dialect in *renderers
          actual = isEquivalent dialect, row.written, row.rewritten, nil, row.stylesByName, row.wrapStyle
          continue if actual == not not claimed[dialect]
          offenders[#offenders + 1] = "#{row.name}:#{dialect}:claimed#{claimed[dialect] and 'safe' or 'unsafe'}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- a rewrite that changed nothing anywhere would pass the check above while recording nothing
    equivalences_rewriteSomethingOtherThanTheLineItself: (ut) ->
      offenders = [row.name for row in *equivalences when row.written == row.rewritten]
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- the unsafe rows are the whole reason the table is worth keeping, so lose them and it says little
    equivalences_recordRewritesThatAreNotUniversallySafe: (ut) ->
      divergent = [row.name for row in *equivalences when #row.dialects < #renderers]
      ut\assertTrue #divergent > 0

    -- The two dialects hold one appearance in different terms, and a canonical read is what lets a
    -- line be compared across them at all.
    describeCanonicalAppearance_agreesWhereOnlyTheTermsDiffer: (ut) ->
      for text in *{"{\\b1}x", "{\\b0}x", "{\\b700}x", "{\\b500}x"}
        ut\assertEquals describeCanonicalAppearance(DialectName.Libass, text),
          describeCanonicalAppearance DialectName.XyVsfilter, text

    -- one rounds a fractional pass away and clamps a negative one; the other draws both
    describeCanonicalAppearance_keepsADifferenceInWhatIsDrawn: (ut) ->
      for text in *{"{\\be0.6}x", "{\\be-3}x"}
        ut\assertNotEquals describeCanonicalAppearance(DialectName.Libass, text),
          describeCanonicalAppearance DialectName.XyVsfilter, text

    -- the format gives 2 no meaning and both draw it as the outline 1 asks for, so folding it is what
    -- makes the two comparable; 4 is the libass extension that genuinely draws its own way
    describeCanonicalAppearance_partsTheBorderStylesTheRenderersDrawApart: (ut) ->
      styled = (borderstyle) ->
        style = {k, v for k, v in pairs defaultStyle}
        style.borderstyle = borderstyle
        style

      for borderstyle in *{1, 2, 3, 5}
        ut\assertEquals describeCanonicalAppearance(DialectName.Libass, "x", styled borderstyle),
          describeCanonicalAppearance DialectName.XyVsfilter, "x", styled borderstyle

      ut\assertNotEquals describeCanonicalAppearance(DialectName.Libass, "x", styled 4),
        describeCanonicalAppearance DialectName.XyVsfilter, "x", styled 4

    -- only one dialect tracks the character set, so holding it would part every pair of dialects on
    -- its presence before a value was read
    describeCanonicalAppearance_leavesOutAFieldOnlyOneDialectCompares: (ut) ->
      ut\assertEquals describeCanonicalAppearance(DialectName.Libass, "{\\fe1}x"),
        describeCanonicalAppearance DialectName.XyVsfilter, "{\\fe1}x"

    -- a dialect that compares no runs tracks no appearance to report
    describeCanonicalAppearance_isNilForADialectComparingNoRuns: (ut) ->
      ut\assertNil describeCanonicalAppearance DialectName.Aegisub, "{\\b1}x"

    -- The fold is what makes the picture comparable and is exactly what hides a split: libass ends a
    -- run between the two spellings of bold and VSFilter does not, which the syllables still report.
    describeCanonicalAppearance_foldsASplitThatTheKaraokeReadingKeeps: (ut) ->
      ut\assertEquals describeCanonicalAppearance(DialectName.Libass, "{\\k50}{\\b1}a{\\b700}b"),
        describeCanonicalAppearance DialectName.Libass, "{\\k50}{\\b1}a{\\b1}b"
      ut\assertNotEquals describeKaraokeSyllables(DialectName.Libass, "{\\k50}{\\b1}a{\\b700}b"),
        describeKaraokeSyllables DialectName.Libass, "{\\k50}{\\b1}a{\\b1}b"

    describeLine_partsTwoLinesTheDialectTellsApart: (ut) ->
      ut\assertNotEquals describeLine(DialectName.Libass, "{\\k50}a{\\b1}b"),
        describeLine DialectName.Libass, "{\\k50}a{\\b0}b"

    -- A rewrite that moves a transform's interval leaves the same state behind and touches no field a
    -- renderer compares runs on, so a descriptor read at one moment cannot see it. Reading each line
    -- at the moments its own transforms open, close and stand halfway is what parts them.
    describeLine_partsARewriteThatMovesATransformsInterval: (ut) ->
      nested = "{\\t(0,100,\\fscy150\\t(5000,6000,\\fscx200))}MMMM"
      for dialect in *renderers
        -- de-nesting into two transforms over the same intervals is the rewrite that holds
        ut\assertTrue isEquivalent dialect, nested, "{\\t(0,100,\\fscy150)\\t(5000,6000,\\fscx200)}MMMM"

        -- and each of these is a de-nesting that quietly changed when something animates
        ut\assertFalse isEquivalent dialect, nested, "{\\t(0,100,\\fscy150)\\t(1000,2000,\\fscx200)}MMMM"
        ut\assertFalse isEquivalent dialect, nested, "{\\t(0,100,\\fscy150)\\fscx200}MMMM"
        ut\assertFalse isEquivalent dialect, nested, "{\\t(0,100,\\fscy150\\fscx200)}MMMM"

    -- A line holding no transform is read at one moment, as it always was, so nothing pays for this
    -- but the lines it is about.
    describeLine_readsALineWithoutATransformAtOneMoment: (ut) ->
      ut\assertEquals select(2, describeLine(DialectName.Libass, "{\\b1}a{\\i1}b")\gsub "@t%d+", ""), 1
      ut\assertGreaterThan select(2, describeLine(DialectName.Libass, "{\\t(0,100,\\fscx200)}a")\gsub "@t%d+", ""), 1

    -- Recording the appearance at the line's end alone would call these alike: the same tags in the
    -- same places, leaving the same state, drawing `A` bold in one and italic in the other. What a
    -- rewrite must not do is move an appearance a later tag overwrites, and that is what this catches.
    describeLine_partsTwoLinesDrawingAnEarlierRunDifferently: (ut) ->
      ut\assertNotEquals describeLine(DialectName.Libass, "{\\b1}A{\\i1}B{\\b0}"),
        describeLine DialectName.Libass, "{\\i1}A{\\b1}B{\\b0}"
      ut\assertFalse isEquivalent DialectName.Libass, "{\\b1}A{\\i1}B{\\b0}", "{\\i1}A{\\b1}B{\\b0}"

      -- and the same where only a value differs, the later tag writing both lines to one size
      ut\assertFalse isEquivalent DialectName.Libass, "{\\fs60}A{\\fs48}B", "{\\fs80}A{\\fs48}B"

    -- Every run's appearance is recorded, so the whole of a line's text is checked and not only its
    -- syllables: a consumer editing text, which this parser never does, is held to it too.
    describeLine_partsTwoLinesByTheirText: (ut) ->
      ut\assertFalse isEquivalent DialectName.Libass, "{\\b1}AX{\\i1}B", "{\\b1}AY{\\i1}B"
      ut\assertFalse isEquivalent DialectName.Libass, "{\\b1}A{\\i1}B", "{\\b1}B{\\i1}A"

    -- A tag no run follows draws nothing, so the state it leaves cannot part two lines. A drawing is a
    -- run like any other, which is what the second pair turns on: the trailing tag scales it.
    describeLine_ignoresAppearanceNoRunIsDrawnIn: (ut) ->
      ut\assertTrue isEquivalent DialectName.Libass, "{\\fs40}ab{\\fscx80}", "{\\fs40}ab{\\fscx60}"
      ut\assertFalse isEquivalent DialectName.Libass, "{\\fs40}ab{\\fscx80}{\\p1}m 0 0 l 9 9{\\p0}",
        "{\\fs40}ab{\\p1}m 0 0 l 9 9{\\p0}"

      -- Dropping the tag parts them instead. It moves a field libass compares, opening a syllable that
      -- holds nothing, and `parseKaraokeData` reports a line's last syllable however empty it is.
      ut\assertFalse isEquivalent DialectName.Libass, "{\\fs40}ab{\\fscx80}", "{\\fs40}ab"

    describeLine_matchesForTwoSpellingsOfOneColor: (ut) ->
      ut\assertEquals describeLine(DialectName.Libass, "{\\k50}a{\\1c&H0000FF&}b"),
        describeLine DialectName.Libass, "{\\k50}a{\\1c0000FF}b"

    -- a line every dialect reads alike is the ordinary case, and the one a diagnostic stays quiet on
    groupDialectsByKaraokeReading_yieldsOneGroupForAnAgreedLine: (ut) ->
      ut\assertEquals describeGroups(groupDialectsByKaraokeReading "{\\k50}ab{\\k30}cd"), "aegisub+libass+vsfilter"

    -- Aegisub opens a syllable per karaoke tag and reads no appearance, so it differs from both renderers
    -- wherever a tag moves one. That is a divergence in reported timing rather than in what is drawn.
    groupDialectsByKaraokeReading_partsAegisubFromTheRenderersOnAnAppearanceTag: (ut) ->
      ut\assertEquals describeGroups(groupDialectsByKaraokeReading "{\\k50}a{\\b1}b"), "aegisub | libass+vsfilter"

    -- the character set separates the two renderers, and leaves Aegisub beside the one ignoring it, which
    -- is why a diagnostic has to report which dialects agree rather than how many readings there were
    groupDialectsByKaraokeReading_partsTheRenderersOnTheCharacterSet: (ut) ->
      ut\assertEquals describeGroups(groupDialectsByKaraokeReading "{\\k50}a{\\fe0}b"), "aegisub+libass | vsfilter"

    -- three readings at once, which is the shape a count would flatten into the same answer as any
    -- other disagreement
    groupDialectsByKaraokeReading_partsAllThreeWhereEachReadsDifferently: (ut) ->
      ut\assertEquals describeGroups(groupDialectsByKaraokeReading "{\\k50}a{\\kt20}b{\\fe0}c"),
        "aegisub | libass | vsfilter"
  }

  for row in *equivalences
    for dialect in *renderers
      safe = (claimedBy row)[dialect]
      tests["isEquivalent_#{row.name}_#{dialect}"] = (ut) ->
        actual = isEquivalent dialect, row.written, row.rewritten, nil, row.stylesByName, row.wrapStyle
        ut\assertEquals actual, not not safe

  -- Both renderers put the line's own style back for an unknown name, observed by rendering it beside
  -- a bare `\r` and beside the style it reset away from. The check runs only where the script's styles
  -- are given, since without them every name looks undeclared.
  tests.findLineDefects_reportsAResetToAnUnknownStyle = (ut) ->
    found = findLineDefects "abc{\\rMissing}d", nil, declaredStyles
    ut\assertEquals #found, 1
    ut\assertEquals found[1].code, FindingCode.ResetToUnknownStyle
    ut\assertEquals found[1].severity, Severity.Warning
    ut\assertContains found[1].message, "Missing"

    ut\assertEquals #findLineDefects("abc{\\rDeclared}d", nil, declaredStyles), 0
    ut\assertEquals #findLineDefects("abc{\\r}d", nil, declaredStyles), 0
    ut\assertEquals #findLineDefects("abc{\\rMissing}d"), 0

  tests.findLineDefects_quietOnALineReadAsWritten = (ut) ->
    ut\assertEquals #findLineDefects("{\\k50}a{\\b1}b", nil, declaredStyles), 0
    ut\assertEquals #findLineDefects("plain text"), 0
    ut\assertEquals #findLineDefects("{\\pos(1,2)}{\\fs48}a"), 0

  -- The scan is lossless, so the bytes a finding names cut back out of the line are the tag it is
  -- about, for a tag nested in a transform's arguments as much as a top-level one.
  tests.findLineDefects_anchorsToTheTagItNames = (ut) ->
    text = "abc{\\rMissing}d"
    finding = findLineDefects(text, nil, declaredStyles)[1]
    ut\assertEquals text\sub(finding.startIndex, finding.endIndex), "\\rMissing"
    ut\assertEquals finding.tag, "rMissing"

    nested = "{\\t(0,100,\\bord-2)}a"
    finding = findLineDefects(nested)[1]
    ut\assertEquals nested\sub(finding.startIndex, finding.endIndex), "\\bord-2"

  -- The constraint that moved the value names the finding, so a clamp, a rounding and a refusal are
  -- told apart rather than reported as one unhelpful code.
  tests.findLineDefects_namesTheConstraintThatMovedTheValue = (ut) ->
    ut\assertEquals describeCodes(findLineDefects "{\\be0.6}a"), FindingCode.ValueRounded
    ut\assertEquals describeCodes(findLineDefects "{\\be200}a"), FindingCode.ValueClamped
    ut\assertEquals describeCodes(findLineDefects "{\\bord-2}a"), FindingCode.ValueClamped
    ut\assertEquals describeCodes(findLineDefects "{\\fs0}a"), FindingCode.ArgumentRefused
    ut\assertEquals describeCodes(findLineDefects "{\\b50}a"), FindingCode.ArgumentRefused

  -- A finding naming fewer dialects than were asked is itself the divergence, anchored to the tag that
  -- causes it, where a whole-line verdict would leave a consumer nothing to act on. libass rounds and
  -- clamps `\be` where VSFilter takes it as written, both observed.
  tests.findLineDefects_namesOnlyTheDialectsReadingItThatWay = (ut) ->
    finding = findLineDefects("{\\be0.6}a")[1]
    ut\assertEquals #finding.dialects, 1
    ut\assertEquals finding.dialects[1], DialectName.Libass

    -- both refuse a weight of 50, so one finding names them both
    finding = findLineDefects("{\\b50}a")[1]
    ut\assertEquals #finding.dialects, 2

  -- `\fe` ends a run of text for VSFilter and not for libass, which moves a karaoke syllable boundary.
  -- The trait declaring that is what the finding is derived from.
  tests.findLineDefects_reportsACharacterSetOnlyOneDialectCompares = (ut) ->
    finding = findLineDefects("{\\fe1}a")[1]
    ut\assertEquals finding.code, FindingCode.CharacterSetNotCompared
    ut\assertEquals finding.dialects[1], DialectName.XyVsfilter

  -- A `\t` holding no tags animates nothing, yet still switches the line's collision detection off, so
  -- whether it can be removed turns on what else the line writes. The split reported here is the one
  -- both renderers were observed making: `\pos`, `\move`, `\org`, a transform that does animate
  -- something, and a scroll in the Effect field each switch collisions off on their own, while `\fad`,
  -- `\clip` and `\frz` leave them on.
  tests.findLineDefects_partsAnEmptyTransformByWhatElseHoldsTheLine = (ut) ->
    removable = {
      "{\\an2\\pos(10,10)\\t(0,500,)}a"
      "{\\an2\\move(10,10,20,20)\\t(0,500,)}a"
      "{\\an2\\org(10,10)\\t(0,500,)}a"
      "{\\an2\\t(0,500,\\fscx200)\\t(0,500,)}a"
    }
    for text in *removable
      ut\assertContains describeCodes(findLineDefects text), FindingCode.TransformEmpty

    loadBearing = {"{\\an2\\t(0,500,)}a", "{\\an2\\t()}a", "{\\an2\\fad(100,100)\\t(0,500,)}a", "{\\an2\\frz10\\t(0,500,)}a"}
    for text in *loadBearing
      ut\assertContains describeCodes(findLineDefects text), FindingCode.TransformEmptyHoldsCollisions

  -- The Effect field switches collisions off without a tag saying so, so a line carrying one has to be
  -- read with it or the transform beside it is called load-bearing when it is not.
  tests.findLineDefects_readsTheEffectFieldForCollisionState = (ut) ->
    text = "{\\an2\\t(0,500,)}a"
    ut\assertContains describeCodes(findLineDefects text), FindingCode.TransformEmptyHoldsCollisions
    for effect in *{"Banner;0;0;0", "Scroll up;0;720;0;0"}
      ut\assertContains describeCodes(findLineDefects text, nil, nil, effect), FindingCode.TransformEmpty

  -- Removing every empty transform is what would let the line collide, so a line holding only those
  -- reports each of them as holding it still rather than each as removable because the others remain.
  tests.findLineDefects_callsEveryEmptyTransformLoadBearingWhereNothingElseHoldsTheLine = (ut) ->
    found = [finding for finding in *findLineDefects("{\\an2\\t(0,100,)\\t(0,500,)}a") when finding.code == FindingCode.TransformEmptyHoldsCollisions]
    ut\assertEquals #found, 2

  -- A transform that animates something is not empty, however little it holds.
  tests.findLineDefects_reportsNoEmptyTransformWhereOneAnimates = (ut) ->
    ut\assertNotContains describeCodes(findLineDefects "{\\an2\\t(0,500,\\fscx200)}a"), FindingCode.TransformEmpty
    ut\assertNotContains describeCodes(findLineDefects "{\\an2\\t(0,500,\\fscx200)}a"), FindingCode.TransformEmptyHoldsCollisions

  tests.findLineDefects_reportsTheFormsAScanRecords = (ut) ->
    ut\assertEquals describeCodes(findLineDefects "{\\ b1}a"), FindingCode.WhitespaceInTag
    ut\assertEquals describeCodes(findLineDefects "{\\t(0,100,\\bord2}a"), FindingCode.UnclosedArgumentList

  -- A backslash and a name is someone reaching for a tag. Which of a misspelling, a note and a wider
  -- vocabulary they reached for cannot be told from the text, so all three report the same way.
  tests.findLineDefects_namesATagNoDialectKnows = (ut) ->
    found = findLineDefects "{\\FX Por Iczaka\\move(377,50,294,51)}a"
    ut\assertEquals found[1].code, FindingCode.UnrecognizedTag
    ut\assertContains found[1].message, "draws nothing"

  -- VSFilterMod's own tags are the one case worth naming apart, since the line is not defective so
  -- much as written for a renderer none of the three is. The list comes from diffing its `RTS.cpp`.
  tests.findLineDefects_namesTheForkATagBelongsTo = (ut) ->
    for written in *{
      "{\\1vc(EC5007,FFFFFF,EC5007,FFFFFF)}a", "{\\1img(ima.png,0,50)}a"
      "{\\jitter1,2,3}a", "{\\distort1,2,3}a", "{\\z5}a"
    }
      found = findLineDefects written
      ut\assertEquals found[1].code, FindingCode.VsfilterModTag
      ut\assertContains found[1].message, "VSFilterMod"

  -- Only a fork tag that begins with nothing a real tag is named after can be seen at all. Every
  -- dialect matches by prefix, so `\moves4` is read as `\move` with `s4` for an argument and `\rnds5`
  -- as a `\r` naming the style `nds5`, and neither reaches the scan as a tag nobody knows.
  tests.findLineDefects_cannotSeeAForkTagARealOneIsAPrefixOf = (ut) ->
    for written in *{"{\\moves4(1,2,3,4)}a", "{\\rnds5}a", "{\\frs10}a", "{\\fsvp3}a"}
      ut\assertNotContains describeCodes(findLineDefects written), FindingCode.VsfilterModTag

  -- Every dialect matches a tag name by prefix, so a misspelling that begins with a real name is read
  -- as that tag with junk for an argument rather than as no tag at all.
  tests.findLineDefects_readsAMisspellingThatPrefixesARealTagAsThatTag = (ut) ->
    ut\assertNotContains describeCodes(findLineDefects "{\\bordd2}a"), FindingCode.UnrecognizedTag

  -- unanimated's Colorize writes `{*` before the tags of each per-character block it generates, behind
  -- a "Use asterisks" checkbox, and strips the leftovers by the same mark. Both renderers were observed
  -- reading past it wherever it stands, so it is a note about a marker rather than a defect.
  tests.findLineDefects_readsAsterisksAsAGeneratedBlockMarker = (ut) ->
    found = findLineDefects "{*\\c&H7A9B97&}K"
    ut\assertEquals describeCodes(found), FindingCode.BlockMarker
    ut\assertEquals found[1].severity, Severity.Info

  -- A backslash naming nothing is the opposite case, and gets its own name rather than being reported
  -- as whatever else a block holds that no tag claimed.
  tests.findLineDefects_namesAStrayBackslash = (ut) ->
    ut\assertEquals describeCodes(findLineDefects "{\\\\blur0.6}a"), FindingCode.StrayBackslash
    ut\assertEquals describeCodes(findLineDefects "{\\blur1\\}a"), FindingCode.StrayBackslash

  -- Two mistakes the wild corpus turns up in bulk, which the general finding reported as one. The
  -- first loses the value outright; the second silently drops the alpha the author meant to set.
  tests.findLineDefects_tellsAMalformedLiteralFromADroppedAlpha = (ut) ->
    found = findLineDefects "{\\alpha&20}a"
    ut\assertEquals found[1].code, FindingCode.ColorLiteralMalformed
    ut\assertContains found[1].message, "the value written is lost"

    found = findLineDefects "{\\c&H00FFFFFF&}a"
    ut\assertEquals found[1].code, FindingCode.ColorAlphaIgnored
    ut\assertContains found[1].message, "the alpha is dropped"

  -- A literal written as the format asks reports nothing at all, in either the six-digit or the
  -- two-digit form, so neither finding fires on ordinary authoring.
  tests.findLineDefects_reportsNothingForAWellFormedLiteral = (ut) ->
    for written in *{"{\\c&HFFFFFF&}a", "{\\1a&HFF&}a", "{\\3c&H0000FF&}a", "{\\alpha&H80&}a"}
      ut\assertEquals #findLineDefects(written), 0

  -- Both renderers read these from the line's first instance, so a later one is dead however far down
  -- it stands. Observed for all seven by rendering the pair against the first and the last alone.
  tests.findLineDefects_reportsALineTagAnEarlierOneAlreadySettled = (ut) ->
    found = findLineDefects "{\\pos(10,10)\\pos(90,90)}a"
    ut\assertEquals describeCodes(found), FindingCode.LineTagIgnored
    ut\assertEquals found[1].tag, "pos90,90"

  -- Three of those slots are shared between two tags, so the tag named as having settled it need not
  -- be the same one being reported.
  tests.findLineDefects_namesTheTagThatSettledASharedSlot = (ut) ->
    for {written, dead, settledBy} in *{
      {"{\\move(1,2,3,4)}a{\\pos(9,9)}b", "pos9,9", "move"}
      {"{\\fad(100,100)\\fade(255,0,255,0,1,2,3)}a", "fade255,0,255,0,1,2,3", "fad"}
      {"{\\an7}a{\\a2}b", "a2", "an"}
    }
      found = findLineDefects written
      ut\assertEquals found[1].code, FindingCode.LineTagIgnored
      ut\assertEquals found[1].tag, dead
      ut\assertContains found[1].message, "`\\#{settledBy}` earlier in the line"

  -- `\q` and a rectangular `\clip` take the last value written, as an ordinary state write does, so a
  -- second one of those is live rather than dead and nothing is reported.
  tests.findLineDefects_reportsNothingWhereTheLastTagWins = (ut) ->
    for written in *{"{\\q2\\q0}a", "{\\clip(0,0,3,7)\\clip(0,0,9,7)}a", "{\\pos(1,1)}a"}
      ut\assertNotContains describeCodes(findLineDefects written), FindingCode.LineTagIgnored

  -- Both renderers end a transform's argument list at the first `)`, so a tag inside it that opens a
  -- list of its own closes the transform. Reporting the unclosed lists that follow names the symptom;
  -- naming the tag whose `)` did it says what to change, so the specific finding takes their place.
  tests.findLineDefects_namesTheTagWhoseParenthesisClosedATransform = (ut) ->
    found = findLineDefects "{\\t(0,100,\\fad(0,500)\\fscx200))}a"
    ut\assertEquals found[1].code, FindingCode.TransformParenthesizedArgument
    ut\assertEquals found[1].tag, "fad0,500"
    ut\assertContains found[1].message, "closes the transform"
    ut\assertNotContains describeCodes(found), FindingCode.UnclosedArgumentList

    -- the tag left outside the transform keeps its surplus parentheses, which it reads past
    ut\assertEquals found[2].code, FindingCode.ValueNotAsWritten
    ut\assertEquals found[2].tag, "fscx200))"

  -- A transform cannot animate a transform: the inner window replaces the outer for the tags after it,
  -- which both renderers were asked and agreed on.
  tests.findLineDefects_reportsATransformInsideATransform = (ut) ->
    codes = describeCodes findLineDefects "{\\t(0,100,\\t(5000,6000,\\fscx200))}a"
    ut\assertContains codes, FindingCode.TransformNested
    ut\assertContains codes, FindingCode.TransformParenthesizedArgument
    ut\assertNotContains codes, FindingCode.UnclosedArgumentList

  -- A transform whose own list is genuinely unclosed, with nothing inside it to explain why, still
  -- reports the plain finding.
  tests.findLineDefects_keepsThePlainUnclosedFindingWhereNothingExplainsIt = (ut) ->
    ut\assertEquals describeCodes(findLineDefects "{\\t(0,100,\\bord2}a"), FindingCode.UnclosedArgumentList

  -- A count no signature takes leaves the token unmatched, short or long alike. Both renderers were
  -- observed skipping an over-supplied `\pos`, `\org`, `\move`, `\clip` and `\fad` whole rather than
  -- reading it short, so an extra argument is as much a defect as a missing one.
  tests.findLineDefects_reportsAnyArgumentCountNoSignatureTakes = (ut) ->
    ut\assertEquals describeCodes(findLineDefects "{\\pos(1)}a"), FindingCode.UnmatchedSignature
    ut\assertEquals describeCodes(findLineDefects "{\\pos(1,2,3)}a"), FindingCode.UnmatchedSignature

  -- A spline starts one and needs a single node before it, where a spline extension continues one and
  -- needs three. Reading them alike would report a valid spline as a defect and strip it away.
  tests.findLineDefects_tellsASplineFromItsExtension = (ut) ->
    ut\assertEquals #findLineDefects("{\\p1}m 0 0 s 10 10 20 20 30 30{\\p0}"), 0
    ut\assertEquals #findLineDefects("{\\p1}m 0 0 s 10 10 20 20 30 30 p 40 40{\\p0}"), 0
    ut\assertEquals describeCodes(findLineDefects "{\\p1}m 0 0 p 40 40 l 10 10{\\p0}"),
      FindingCode.DrawingExtensionWithoutNodes

  -- A spline extends by one point at a time once it has its three, so eight coordinates are a whole
  -- spline and one extension rather than a curve left two short.
  tests.findLineDefects_readsASplineExtendingByOnePoint = (ut) ->
    ut\assertEquals #findLineDefects("{\\p1}m 0 0 s 10 10 20 20 30 30 40 40{\\p0}"), 0
    -- a cubic curve does repeat at the count it opens with, so the same shape there is two points short
    ut\assertEquals describeCodes(findLineDefects "{\\p1}m 0 0 b 10 10 20 20 30 30 40 40{\\p0}"),
      FindingCode.DrawingOrphanedPoints

  -- Where an opening group is left incomplete the two part only on a cubic curve: VSFilter rolls a
  -- spline's points back and keeps a curve's, which is why the two cannot share one reading.
  tests.findLineDefects_tellsAPartialSplineFromAPartialCurve = (ut) ->
    ut\assertEquals describeCodes(findLineDefects "{\\p1}m 0 0 s 10 10{\\p0}"),
      FindingCode.DrawingIncompleteArguments
    ut\assertEquals describeCodes(findLineDefects "{\\p1}m 0 0 b 10 10 20 20{\\p0}"),
      FindingCode.DrawingOrphanedPoints

  -- A block whose content holds no backslash is an authoring comment: Aegisub gives it a block type of
  -- its own, the renderers skip past it, and none of them draws it. The same characters beside a tag
  -- in one block are not — nothing marked them as a comment, so they are a defect.
  tests.findLineDefects_tellsACommentBlockFromJunkBesideATag = (ut) ->
    for text in *{"{note}a", "{\\b1}{note}a"}
      finding = findLineDefects(text)[1]
      ut\assertEquals finding.code, FindingCode.CommentBlock
      ut\assertEquals finding.severity, Severity.Info

    for text in *{"{note\\b1}a", "{\\b1}{note\\b1}a"}
      finding = findLineDefects(text)[1]
      ut\assertEquals finding.code, FindingCode.JunkInBlock
      ut\assertEquals finding.severity, Severity.Warning

    -- a backslash naming no tag gets a finding of its own, being a typo rather than stray characters
    ut\assertEquals describeCodes(findLineDefects "{\\}a"), FindingCode.StrayBackslash

  -- The eight malformations put to both renderers as ink probes, each reported as what it is. A
  -- drawing that reads at face value stays quiet, however many coordinates one command repeats over.
  tests.findLineDefects_quietOnAWellFormedDrawing = (ut) ->
    ut\assertEquals #findLineDefects("{\\p1}m 0 0 l 100 0 l 100 100 l 0 100{\\p0}"), 0
    ut\assertEquals #findLineDefects("{\\p1}m 0 0 b 10 10 20 20 30 30{\\p0}"), 0
    -- one `l` drawing three lines, which is the command repeating rather than a defect
    ut\assertEquals #findLineDefects("{\\p1}m 0 0 l 100 0 100 100 0 100{\\p0}"), 0

  -- Both renderers draw nothing at all until a move has reached a point, and only `m` opens one for
  -- both: a drawing led by a line or by an open move is rejected whole in each.
  tests.findLineDefects_reportsADrawingThatNeverOpens = (ut) ->
    for text in *{"{\\p1}l 100 0 l 100 100{\\p0}", "{\\p1}n 0 0 l 100 0 l 100 100{\\p0}"}
      found = findLineDefects text
      ut\assertEquals #found, 1
      ut\assertEquals found[1].code, FindingCode.DrawingRejected
      ut\assertEquals found[1].severity, Severity.Error

  -- An open move reaching a point before any move leaves points where the drawing's first move has to
  -- stand, and every reader throws the whole drawing away for it. Both renderers were observed drawing
  -- no ink for these, where the move behind the open one had been read as opening the drawing.
  tests.findLineDefects_reportsADrawingNoReaderOpens = (ut) ->
    for drawing in *{"n 0 0 m 10 10 l 50 50", "n 0 0 l 100 0", "l 100 0"}
      ut\assertEquals describeCodes(findLineDefects "{\\p1}#{drawing}{\\p0}"), FindingCode.DrawingRejected

  -- A command reaching for nodes it has not got is ignored by every reader, wherever it stands. Four
  -- readings of the VSFilter line were put to one before the first move and each drew the drawing
  -- behind it exactly as it drew the same drawing written alone.
  tests.findLineDefects_reportsACommandWithoutTheNodesItNeeds = (ut) ->
    for drawing in *{"l 100 0 m 0 0 l 50 50", "b 1 2 3 4 5 6 m 0 0 l 50 50", "m 0 0 p 300 0 l 50 50"}
      ut\assertEquals describeCodes(findLineDefects "{\\p1}#{drawing}{\\p0}"),
        FindingCode.DrawingExtensionWithoutNodes

  -- Characters naming no command are reported in runs, a run ending wherever one does name a command.
  -- Every renderer scans a drawing character by character, so a word is not the unit: the `n` in `junk`
  -- is an open move to all of them and only the `ju` and the `k` around it go unread.
  tests.findLineDefects_reportsUnrecognizedDrawingCharacters = (ut) ->
    for text in *{"{\\p1}m 0 0 l 100 0 junk{\\p0}", "{\\p1}m 0 0 l 100 0 x 5 5{\\p0}"}
      codes = describeCodes findLineDefects text
      ut\assertContains codes, FindingCode.DrawingUnrecognizedToken

    -- no letter of this one names a command, so it is the single run its author wrote
    found = findLineDefects "{\\p1}m 0 0 l 100 0 l 100 100 l 0 100 xyz{\\p0}"
    ut\assertEquals #found, 1
    ut\assertContains found[1].message, "xyz"

  -- Leftover coordinates part the two only where they amount to a whole point: libass commits a curve
  -- in whole batches and drops the rest, VSFilter keeps them in the path, where they widen the drawing
  -- without drawing anything. A leftover half point is unusable to both, so neither is named alone.
  tests.findLineDefects_tellsOrphanedPointsFromAnUnusableLeftover = (ut) ->
    found = findLineDefects "{\\p1}m 0 0 l 100 0 b 300 100 300 0{\\p0}"
    ut\assertEquals #found, 1
    ut\assertEquals found[1].code, FindingCode.DrawingOrphanedPoints
    ut\assertEquals #found[1].dialects, 1
    ut\assertEquals found[1].dialects[1], DialectName.Libass

    found = findLineDefects "{\\p1}m 0 0 l 100 0 l 300{\\p0}"
    ut\assertEquals found[1].code, FindingCode.DrawingIncompleteArguments
    ut\assertEquals #found[1].dialects, 2

  -- The other place they part: after an `m` that reached no point, libass lets the next open move
  -- stand in and VSFilter draws nothing, which was seen by eye in both.
  tests.findLineDefects_reportsARootTakenFromAnOpenMove = (ut) ->
    codes = describeCodes findLineDefects "{\\p1}m junk n 0 0 l 100 0 l 100 100{\\p0}"
    ut\assertContains codes, FindingCode.DrawingRootFromOpenMove

    for finding in *findLineDefects "{\\p1}m junk n 0 0 l 100 0 l 100 100{\\p0}"
      continue unless finding.code == FindingCode.DrawingRootFromOpenMove
      ut\assertEquals #finding.dialects, 1
      ut\assertEquals finding.dialects[1], DialectName.Libass

  tests.findLineDefects_reportsASplineExtensionWithoutEnoughNodes = (ut) ->
    found = findLineDefects "{\\p1}m 0 0 p 300 0 l 100 100{\\p0}"
    ut\assertEquals #found, 1
    ut\assertEquals found[1].code, FindingCode.DrawingExtensionWithoutNodes

  -- Characters after a closed argument list reach the renderers as junk of their own, where Aegisub
  -- keeps them on the tag instead. The defect is the same one seen through two scans, so it is
  -- reported whichever dialect the line is read with, even though the bytes it anchors to differ.
  tests.findLineDefects_reportsCharactersAfterAClosedArgumentList = (ut) ->
    for order in *{{DialectName.Libass, DialectName.XyVsfilter}, {DialectName.Aegisub, DialectName.Libass}}
      found = findLineDefects "{\\t(0,100,\\bord2)junk}a", order
      ut\assertEquals #found, 1
      ut\assertEquals found[1].code, FindingCode.JunkInBlock
      ut\assertContains found[1].message, "junk"

    ut\assertEquals #findLineDefects("{\\t(0,100,\\bord2)\\b1}a"), 0

  -- A transform's arguments are scanned as a block of their own, so its timings arrive as junk
  -- standing ahead of every tag it holds, which is what tells them from a defect.
  tests.findLineDefects_staysQuietOnATransformsTimings = (ut) ->
    ut\assertEquals #findLineDefects("{\\t(0,100,\\bord2)}a"), 0
    ut\assertEquals #findLineDefects("{\\t(\\bord2)}a"), 0

    text = "{\\b1}{note\\b1}a"
    finding = findLineDefects(text)[1]
    ut\assertEquals text\sub(finding.startIndex, finding.endIndex), "note"
    -- the characters are no tag, so the finding names none
    ut\assertNil finding.tag

  tests
