-- Override-tag scanner tests: the conformance corpus, run against the scanner in both directions.
-- Called from test.moon as: (require "...test.override-tags") corpus
--
-- Two assertions per case per dialect. The scan has to produce the token stream the corpus records,
-- which is what keeps the three dialects apart; and emitting that scan has to reproduce the input
-- byte for byte, which is what keeps the scan lossless. The second is the one that finds a source
-- form nobody has named yet, since a stream that cannot rebuild its input names the bytes it lost.
--
-- The `overrideTags` cases check the tag table against itself rather than against a scan: a field
-- or argument type named there but declared nowhere fails silently at runtime, since a tag writing an
-- unseeded field compares against nil and so ends a run of text wherever it appears.

AssRunState = require "l0.AssParser.RunState"
lineState = require "l0.AssParser.LineState"
Scanner = require "l0.AssParser.Scanner"
{:BorderStyle, :FontWeight, :defaultStyle} = require "l0.AssParser.ass"
{:ArgumentType, :DialectName, :RunField, :TagName, :TokenKind, :dialects, :getArgumentReading, :getFieldConversion, :overrideTags} = require "l0.AssParser.dialects"
{:emit} = require "l0.AssParser.emit"
{:emitArguments} = require "l0.AssParser.arguments"

-- `Enum` fills `values` through `pairs`, whose order is unspecified, so sort for a stable
-- registration order across runs
dialectNames = [name for name in *DialectName.values]
table.sort dialectNames

---Formats a token stream as one comparable string.
---@param tokens AssToken[] The stream to format.
---@return string formatted One `kind(name|params)` entry per token, a tag's children in brackets.
describe = (tokens) ->
  parts = for token in *tokens
    piece = "#{token.kind}(#{token.name or ''}|#{tostring token.params or token.text or ''})"
    piece ..= "[#{describe token.children}]" if token.children
    piece
  table.concat parts, " "

---Joins adjacent text tokens, which the corpus records as the one rendered run a dialect produces.
---A scan splits that run wherever it had something to record — a brace it rejected, an escape it
---resolved — so joining belongs to the comparison and not to the scanner.
---@param tokens AssToken[]
---@return AssToken[]
joinText = (tokens) ->
  joined = {}
  for token in *tokens
    last = joined[#joined]
    if last and last.kind == TokenKind.Text and token.kind == TokenKind.Text
      last.text ..= token.text
    else
      joined[#joined + 1] = {k, v for k, v in pairs token}
  joined

---The first tag token of a scan, which is what an argument-typing assertion reads.
---@param tokens AssToken[]
---@return AssToken?
firstTag = (tokens) ->
  for token in *tokens
    return token if token.kind == TokenKind.Tag

---@param corpus AssCorpusCase[] The conformance corpus, passed in by the suite.
(corpus) ->
  scanners = {name, Scanner name for name in *dialectNames}

  tests = {
    _description: "Scans the ASS override-tag conformance corpus under all three dialects, asserts
      that emitting each scan reproduces the line it was read from, and checks the tag table declares
      a signature for every name and names only fields a style seeds."

    new_defaultsToAegisub: (ut) ->
      ut\assertEquals Scanner!.dialect.name, "aegisub"

    new_acceptsADialectTable: (ut) ->
      dialect = scanners.libass.dialect
      ut\assertEquals Scanner(dialect).dialect, dialect

    new_rejectsAnUnknownDialect: (ut) ->
      ok = pcall Scanner, "noSuchDialect"
      ut\assertFalse ok

    scan_emptyTextYieldsNoTokens: (ut) ->
      ut\assertEquals #scanners.aegisub\scan(""), 0

    -- Typed arguments, attached to every tag token at scan time so no consumer reads `params` by hand.
    scan_typesASingleArgument: (ut) ->
      tag = firstTag scanners.libass\scan "{\\fs48.5}x"
      ut\assertEquals tag.arguments[1], 48.5
      ut\assertEquals #tag.signature, 1

    -- A tag written bare comes back with no arguments and no signature, which its `acceptsBareTag`
    -- tells apart from a tag whose arguments matched nothing: that one has no arguments either.
    scan_typesABareTagAsItsDeclaredBareForm: (ut) ->
      tag = firstTag scanners.libass\scan "{\\fs}x"
      ut\assertEquals #tag.arguments, 0
      ut\assertNil tag.signature
      ut\assertTrue overrideTags[tag.name].acceptsBareTag

      unmatched = firstTag scanners.libass\scan "{\\pos}x"
      ut\assertNil unmatched.signature
      ut\assertNil overrideTags[unmatched.name].acceptsBareTag

    -- Aegisub's tag table types a karaoke duration as an integer where the renderers read a double,
    -- so the same argument scans to two values
    scan_typesAKaraokeDurationByDialect: (ut) ->
      ut\assertEquals firstTag(scanners.aegisub\scan "{\\k50.9}x").arguments[1], 50
      ut\assertEquals firstTag(scanners.libass\scan "{\\k50.9}x").arguments[1], 50.9

    scan_typesAParenthesizedPair: (ut) ->
      tag = firstTag scanners.libass\scan "{\\pos(100,200.5)}x"
      ut\assertEquals tag.arguments[1], 100
      ut\assertEquals tag.arguments[2], 200.5

    scan_picksTheSignatureTheArityNames: (ut) ->
      ut\assertEquals #firstTag(scanners.libass\scan "{\\move(1,2,3,4)}x").arguments, 4
      ut\assertEquals #firstTag(scanners.libass\scan "{\\move(1,2,3,4,500,600)}x").arguments, 6

    scan_leavesAnUndeclaredArityUntyped: (ut) ->
      tag = firstTag scanners.libass\scan "{\\pos(100)}x"
      ut\assertNil tag.arguments
      ut\assertEquals tag.params, "100"

    -- splitting stops at the first backslash, so a transform's nested tags keep their commas
    scan_keepsATransformTagsTailWhole: (ut) ->
      tag = firstTag scanners.aegisub\scan "{\\t(0,500,\\frz30)}x"
      ut\assertEquals tag.arguments[1], 0
      ut\assertEquals tag.arguments[2], 500
      ut\assertEquals tag.arguments[3], "\\frz30"

    -- No typed value can show a leading `+`, since `+10` and `10` are one number, and that difference
    -- is what makes a font size scale the one in force rather than name one. So the scan records it.
    scan_recordsARelativeSize: (ut) ->
      ut\assertFalse firstTag(scanners.libass\scan "{\\fs10}x").sizeIsRelative
      ut\assertTrue firstTag(scanners.libass\scan "{\\fs+10}x").sizeIsRelative
      ut\assertTrue firstTag(scanners.libass\scan "{\\fs-10}x").sizeIsRelative

    -- Every other tag reads a sign as part of the number, so the value already holds it and the
    -- question is not asked. Nil says that, where false would claim no sign had been written.
    scan_asksForARelativeSizeOfNoOtherTag: (ut) ->
      ut\assertNil firstTag(scanners.libass\scan "{\\bord-2}x").sizeIsRelative
      ut\assertNil firstTag(scanners.libass\scan "{\\fscx+50}x").sizeIsRelative
      ut\assertNil firstTag(scanners.libass\scan "{\\fn-Arial}x").sizeIsRelative
      ut\assertNil firstTag(scanners.libass\scan "{\\rMyStyle}x").sizeIsRelative
      ut\assertNil firstTag(scanners.libass\scan "{\\1c&HFF0000&}x").sizeIsRelative

    scan_typesAFontNameWhole: (ut) ->
      tag = firstTag scanners.libass\scan "{\\fnComic Sans MS}x"
      ut\assertEquals tag.arguments[1], "Comic Sans MS"

    -- Each of these reports what it found rather than which assertion tripped, since the suite's
    -- assertions take no message and a bare "expected true" would not say which row is wrong.
    overrideTags_coversEveryDeclaredName: (ut) ->
      missing = [name for name in *TagName.values when not overrideTags[name]]
      table.sort missing
      ut\assertEquals table.concat(missing, " "), ""

    overrideTags_namesOnlyDeclaredRunFields: (ut) ->
      declared = {value, true for value in *RunField.values}
      offenders = {}
      for name, definition in pairs overrideTags
        continue unless definition.runFields
        offenders[#offenders + 1] = "#{name}:#{field}" for field in *definition.runFields when not declared[field]
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    overrideTags_signaturesHoldDeclaredArgumentTypes: (ut) ->
      declared = {value, true for value in *ArgumentType.values}
      offenders = {}
      for name, definition in pairs overrideTags
        -- a tag taking no argument at all declares no signature, and says so with `acceptsBareTag`
        unless definition.signatures and (#definition.signatures > 0 or definition.acceptsBareTag)
          offenders[#offenders + 1] = "#{name}:noSignature"
          continue
        for signature in *definition.signatures
          offenders[#offenders + 1] = "#{name}:emptySignature" if #signature == 0
          offenders[#offenders + 1] = "#{name}:#{argument}" for argument in *signature when not declared[argument]
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- An argument count picks a signature, which only works while no tag declares two of one length.
    -- The bare form is outside that, being an `acceptsBareTag` rather than a signature: a tag written
    -- with no argument reads as bare before any length is compared.
    overrideTags_signatureLengthsArePerTagUnique: (ut) ->
      offenders = {}
      for name, definition in pairs overrideTags
        seen = {}
        for signature in *definition.signatures
          offenders[#offenders + 1] = "#{name}:#{#signature}" if seen[#signature]
          seen[#signature] = true
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- Every tag whose bare form was observed doing something declares it, so a consumer reading the
    -- table can tell a tag that accepts no argument from one that simply went unmatched. Every tag in
    -- both lists was written bare in both renderers against two controls — the frame if the bare form
    -- acts and the frame if it does nothing — and matched the acting one.
    overrideTags_everyTagWithABareFormDeclaresIt: (ut) ->
      -- restore the style's own value for the one field they write
      resetting = {
        "1a", "1c", "2a", "2c", "3a", "3c", "4a", "4c", "alpha", "c"
        "b", "i", "u", "s"
        "bord", "xbord", "ybord", "shad", "xshad", "yshad", "blur", "be"
        "fs", "fscx", "fscy", "fsp", "fn", "fe"
        "fr", "frx", "fry", "frz", "fax", "fay"
        -- declares the bare form and no other, since it has no valued spelling
        "fsc"
      }
      -- Refer to something other than one run field: `\r` puts the whole style back, `\q` the script's
      -- wrap style, and `\an` and `\a` the style's alignment. No fixed argument spells any of them,
      -- because what each names differs between documents.
      referring = {"r", "q", "an", "a"}
      -- Mean one value however they are reached, which `bareTagDefault` spells: `\p0`, `\pbo0`, `\kt0`
      -- and a karaoke duration of 100. `\t` belongs here too and states no default, for the reason its
      -- entry in the tag table gives.
      spelled = {"p", "pbo", "kt", "k", "kf", "K", "ko", "t"}

      declares = {}
      for name, definition in pairs overrideTags
        declares[name] = true if definition.acceptsBareTag

      expected = {}
      for list in *{resetting, referring, spelled}
        expected[name] = true for name in *list

      missing = [name for name in pairs expected when not declares[name]]
      table.sort missing
      ut\assertEquals table.concat(missing, " "), ""

      -- Nothing else claims one. A bare instance of each of these is skipped by both renderers, so
      -- `{\pos}` has to keep reading as unmatched rather than as a form the tag accepts.
      extra = [name for name in pairs declares when not expected[name]]
      table.sort extra
      ut\assertEquals table.concat(extra, " "), ""

      -- Written bare, each of these is skipped outright by both renderers, so none declares the form
      -- and `{\pos}` reads as unmatched rather than as something the tag accepts.
      for name in *{"pos", "move", "org", "fad", "fade", "clip", "iclip"}
        ut\assertNil declares[name]

    -- Two tags writing one field have to hold it the same way, or the value one writes could never be
    -- compared against the value the other did. Nothing enforces that where the conversions are declared, so
    -- a reading added to one tag and not to its siblings would separate them silently.
    getFieldConversion_agreesAcrossEveryTagWritingAField: (ut) ->
      offenders = {}
      for dialectName in *dialectNames
        for name, definition in pairs overrideTags
          continue unless definition.runFields
          stated = (getArgumentReading dialectName, name).conversion or {}
          for field in *definition.runFields
            conversion = getFieldConversion(dialectName, field) or {}
            for key in *{"resolvesWeight", "roundsToWhole"}
              continue if conversion[key] == stated[key]
              offenders[#offenders + 1] = "#{dialectName}:#{name}:#{field}:#{key}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- a field a tag writes but no style seeds would compare against nil, so every tag naming it
    -- would end a run of text wherever it appeared
    overrideTags_everyNamedFieldIsSeeded: (ut) ->
      offenders = {}
      for dialectName in *dialectNames
        continue unless dialects[dialectName].runComparison
        state = AssRunState defaultStyle, dialectName
        for name, definition in pairs overrideTags
          continue unless definition.runFields
          for field in *definition.runFields
            continue if state.__ignored[field]
            offenders[#offenders + 1] = "#{dialectName}:#{name}:#{field}" if state.values[field] == nil
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- One value is asked for and the two dialects hold it differently, so a single write has to land
    -- as two numbers.
    setValue_writesEachDialectsOwnRepresentation: (ut) ->
      held = (dialectName, field, value) ->
        state = AssRunState defaultStyle, dialectName
        state\setValue field, value
        state.values[field]

      ut\assertEquals held(DialectName.Libass, RunField.Bold, 1), 1
      ut\assertEquals held(DialectName.XyVsfilter, RunField.Bold, 1), FontWeight.Bold
      ut\assertEquals held(DialectName.Libass, RunField.Bold, 0), 0
      ut\assertEquals held(DialectName.XyVsfilter, RunField.Bold, 0), FontWeight.Normal

      -- a weight neither reading resolves is the number it names in both
      ut\assertEquals held(DialectName.Libass, RunField.Bold, 500), 500
      ut\assertEquals held(DialectName.XyVsfilter, RunField.Bold, 500), 500

    -- A consumer reading a value, passing it around and writing it back must not watch it drift, which
    -- is what makes the two halves usable as a pair.
    setValue_roundTripsThroughGetValue: (ut) ->
      offenders = {}
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        for field in *{RunField.Bold, RunField.BorderStyle, RunField.BlurEdges, RunField.FontSize}
          for value in *{0, 1, 3, 4, 400, 500, 700}
            state = AssRunState defaultStyle, dialectName
            state\setValue field, value
            once = state\getValue field
            state\setValue field, once
            twice = state\getValue field
            offenders[#offenders + 1] = "#{dialectName}:#{field}:#{value}" unless once == twice
      ut\assertEquals table.concat(offenders, " "), ""

    -- VSFilter holds no value for the box libass draws behind a whole line, so the write lands on the
    -- outline it draws for that border style instead, and the read reports the outline honestly.
    setValue_landsOnWhatTheDialectDrawsWhereItCannotHoldTheValue: (ut) ->
      state = AssRunState defaultStyle, DialectName.XyVsfilter
      state\setValue RunField.BorderStyle, BorderStyle.ShadowBox
      ut\assertEquals state\getValue(RunField.BorderStyle), BorderStyle.Outline

      libass = AssRunState defaultStyle, DialectName.Libass
      libass\setValue RunField.BorderStyle, BorderStyle.ShadowBox
      ut\assertEquals libass\getValue(RunField.BorderStyle), BorderStyle.ShadowBox

    -- `moved` answers whether a run of text ends here, which is not the same question as whether the
    -- write landed: VSFilter has no value for libass's shadow box, so asking for one on a line already
    -- drawing an outline moves nothing while giving the caller something other than what it asked for.
    setValue_reportsWhatTheFieldHoldsWhereTheDialectDegradesTheValue: (ut) ->
      state = AssRunState defaultStyle, DialectName.XyVsfilter
      moved, held = state\setValue RunField.BorderStyle, BorderStyle.ShadowBox
      ut\assertFalse moved
      ut\assertEquals held, BorderStyle.Outline

      -- libass states the value outright, so there the same write lands as asked
      libass = AssRunState defaultStyle, DialectName.Libass
      moved, held = libass\setValue RunField.BorderStyle, BorderStyle.ShadowBox
      ut\assertTrue moved
      ut\assertEquals held, BorderStyle.ShadowBox

    -- A read folds every border style but the box and libass's own shadow box onto the outline, and
    -- libass compares the number a style named, so writing the outline back over a 2 would lose a run
    -- boundary `\r` really produces.
    setValue_keepsARepresentationTheReadFoldsAway: (ut) ->
      for declared in *{2, 5}
        style = {k, v for k, v in pairs defaultStyle}
        style.borderstyle = declared

        state = AssRunState style, DialectName.Libass
        moved, held = state\setValue RunField.BorderStyle,
          state\getValue RunField.BorderStyle

        ut\assertFalse moved
        ut\assertEquals held, BorderStyle.Outline
        ut\assertEquals state.values[RunField.BorderStyle], declared

    -- a write that moves nothing ends no run, which is the same contract `applyTag` reports on
    setValue_reportsWhetherTheFieldMoved: (ut) ->
      state = AssRunState defaultStyle, DialectName.XyVsfilter
      ut\assertFalse (state\setValue RunField.Bold, state\getValue RunField.Bold)
      ut\assertTrue (state\setValue RunField.Bold, 1)
      ut\assertFalse (state\setValue RunField.Bold, 1)

    -- libass leaves the character set out of its comparison, so it holds nothing to write into and a
    -- consumer writing a whole appearance across both dialects needs no special case for it
    setValue_isANoOpForAFieldTheDialectLeavesOut: (ut) ->
      state = AssRunState defaultStyle, DialectName.Libass
      ut\assertFalse state\setValue RunField.CharSet, 128
      ut\assertNil state.values[RunField.CharSet]

    -- Both renderers split on a glyph being a drawing and compare no drawing scale, so `\p` writes
    -- nothing a run comparison reads however its argument moves.
    applyTag_drawingScaleMovesNoComparedField: (ut) ->
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        state = AssRunState defaultStyle, dialectName
        for text in *{"{\\p1}x", "{\\p2}x", "{\\p0}x", "{\\p}x", "{\\p-1}x"}
          token = firstTag scanners[dialectName]\scan text
          ut\assertFalse state\applyTag token

    -- The line-level counterpart to the run state. Most of these are read from the line's first
    -- instance and a later one is dead, which was observed in both renderers.
    readTokens_keepsTheFirstOfALineLevelTag: (ut) ->
      state = lineState.readTokens scanners[DialectName.Libass]\scan "{\\pos(10,20)\\pos(90,90)}a"
      ut\assertEquals state.position.x, 10
      ut\assertEquals state.position.y, 20

    -- `\pos` and `\move` compete for one slot, so whichever comes first settles it and the other is
    -- dropped however far apart the two stand.
    readTokens_letsMoveSettleThePositionSlot: (ut) ->
      state = lineState.readTokens scanners[DialectName.Libass]\scan "{\\move(1,2,3,4)}a{\\pos(90,90)}b"
      ut\assertNil state.position
      ut\assertEquals state.move.x1, 1
      ut\assertEquals state.move.y2, 4

    -- `\q` and a rectangular `\clip` take the last value written, as an ordinary state write does.
    readTokens_keepsTheLastWrapStyleAndRectangularClip: (ut) ->
      state = lineState.readTokens scanners[DialectName.Libass]\scan "{\\q2\\q0\\clip(0,0,3,7)\\clip(0,0,9,7)}a"
      ut\assertEquals state.wrapStyle, 0
      ut\assertEquals state.clip.rectangle.x2, 9

    -- A clip written as a path goes the other way and keeps the first, which is the one place a tag's
    -- precedence turns on the form it was written in.
    readTokens_keepsTheFirstVectorClip: (ut) ->
      state = lineState.readTokens scanners[DialectName.Libass]\scan "{\\iclip(m 0 0 l 9 9)\\clip(m 1 1 l 5 5)}a"
      ut\assertEquals state.clip.drawing, "m 0 0 l 9 9"
      ut\assertTrue state.clip.inverse
      ut\assertNil state.clip.rectangle

    -- A legacy `\a` states the SSA numbering, which is converted to the keypad one every style field
    -- and every `\an` uses, so a consumer reads one numbering.
    -- Every value was drawn against all nine keypad alignments in both renderers and matched exactly
    -- one. 4 and 8 are illegal and both draw as 5 does, which is top-left in the keypad numbering.
    readTokens_convertsALegacyAlignment: (ut) ->
      for {legacy, expected} in *{
        {1, 1}, {2, 2}, {3, 3}, {4, 7}, {5, 7}, {6, 8}, {7, 9}, {8, 7}, {9, 4}, {10, 5}, {11, 6}
      }
        state = lineState.readTokens scanners[DialectName.Libass]\scan "{\\a#{legacy}}a"
        ut\assertEquals state.alignment, expected

    -- Both renderers put the style's own alignment back for a value outside the range, which leaving
    -- the field unset already says, and settle the slot anyway, so a later alignment tag is dead.
    readTokens_letsAnOutOfRangeAlignmentSettleTheSlot: (ut) ->
      for written in *{"{\\a0}a{\\an7}b", "{\\a99}a{\\an7}b", "{\\an0}a{\\an7}b"}
        ut\assertNil lineState.readTokens(scanners[DialectName.Libass]\scan written).alignment

    -- The two-argument fade is widened into the seven-argument shape, so nothing downstream has to
    -- know which spelling the line used.
    readTokens_widensTheShortFade: (ut) ->
      state = lineState.readTokens scanners[DialectName.Libass]\scan "{\\fad(100,200)}a"
      ut\assertEquals state.fade.fadeInEnd, 100
      ut\assertEquals state.fade.fadeOutStart, 200
      ut\assertEquals state.fade.startAlpha, 255
      ut\assertEquals state.fade.midAlpha, 0

    -- Refusing a tag reports which one settled the slot, which is what a warning about a dead tag reads.
    applyTag_reportsTheTagThatSettledTheSlot: (ut) ->
      state = lineState.AssLineState!
      tokens = scanners[DialectName.Libass]\scan "{\\fad(1,2)\\fade(255,0,255,0,1,2,3)}a"
      applied = [{state\applyTag token} for token in *tokens when token.kind == "tag"]
      ut\assertTrue applied[1][1]
      ut\assertFalse applied[2][1]
      ut\assertEquals applied[2][2], "fad"

    -- A transform interpolates the tags it holds across its window, which the midpoint of a 0 to 2000
    -- transform reads as exactly halfway to the target. Observed in both renderers by drawing
    -- `{\t(0,2000,\fscx200)}` at 1000ms beside a plain `{\fscx150}` and finding them identical.
    applyTag_interpolatesAcrossATransformsWindow: (ut) ->
      for {time, expected} in *{{0, 100}, {500, 125}, {1000, 150}, {1500, 175}, {2000, 200}, {3000, 200}}
        state = AssRunState defaultStyle, DialectName.Libass
        state.time = time
        state\applyTag firstTag scanners[DialectName.Libass]\scan "{\\t(0,2000,\\fscx200)}x"
        ut\assertEquals state.values[RunField.ScaleX], expected

    -- Given no time the state answers for any frame past a transform's start, which is what every
    -- consumer that cannot name one needs and what the state did before it could read a time.
    applyTag_withoutATimeAppliesATransformAtItsTargets: (ut) ->
      state = AssRunState defaultStyle, DialectName.Libass
      state\applyTag firstTag scanners[DialectName.Libass]\scan "{\\t(5000,6000,\\fscx200)}x"
      ut\assertEquals state.values[RunField.ScaleX], 200

    -- A tag a transform does not interpolate is applied whole the moment it is parsed, before the
    -- window opens as readily as after. Observed in both renderers for all nine such tags.
    applyTag_appliesATagWholeBeforeItsWindowOpens: (ut) ->
      state = AssRunState defaultStyle, DialectName.Libass
      state.time = 0
      ut\assertTrue state\applyTag firstTag scanners[DialectName.Libass]\scan "{\\t(5000,6000,\\b1)}x"
      ut\assertEquals state.values[RunField.Bold], 1

    -- A transform inside a transform replaces the window it sits in rather than composing with it, so
    -- the inner one's factor governs its tags. The inner window here has not opened at 1000ms.
    applyTag_aNestedTransformReplacesTheWindowItSitsIn: (ut) ->
      state = AssRunState defaultStyle, DialectName.Libass
      state.time = 1000
      state\applyTag firstTag scanners[DialectName.Libass]\scan "{\\t(0,2000,\\t(5000,6000,\\fscx200))}x"
      ut\assertEquals state.values[RunField.ScaleX], 100

    -- A `\r` naming no declared style puts the line's own style back, exactly as a bare `\r` does, so
    -- an earlier reset is undone rather than left standing. Observed in both renderers by rendering it
    -- beside a bare `\r` and beside the bold style it resets away from: the ink matches the first and
    -- differs from the second.
    reset_anUndeclaredStyleNamePutsTheLinesOwnStyleBack: (ut) ->
      bolded = {k, v for k, v in pairs defaultStyle}
      bolded.bold = true
      stylesByName = {Bolded: bolded}

      -- read through the canonical layer, since the weight a dialect stores raw is its own
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        readings = {}
        for text in *{"{\\rBolded}{\\rNoSuchStyle}x", "{\\rBolded}{\\r}x", "{\\rBolded}x"}
          state = AssRunState defaultStyle, dialectName, stylesByName
          for token in *Scanner(dialectName)\scan text
            state\applyTag token if token.kind == TokenKind.Tag
          readings[#readings + 1] = state\getValue RunField.Bold

        ut\assertEquals readings[1], readings[2]
        -- and the reset it undoes really did put the bold style in force
        ut\assertNotEquals readings[1], readings[3]

    -- A refused argument puts a style's value back, as a bare tag does. `\r` moves which style that
    -- is for one renderer and not the other, so a reset ahead of the refused value parts them.
    reset_partsTheDialectsOnWhichStyleARefusedArgumentPutsBack: (ut) ->
      bolded = {k, v for k, v in pairs defaultStyle}
      bolded.bold = true
      stylesByName = {Bolded: bolded}

      readings = {}
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        state = AssRunState defaultStyle, dialectName, stylesByName
        for token in *Scanner(dialectName)\scan "{\\rBolded\\b50}text"
          state\applyTag token if token.kind == TokenKind.Tag
        readings[dialectName] = state.values[RunField.Bold]

      -- the reset put a bold style in force, and that is what one of them restores from
      ut\assertEquals readings[DialectName.Libass], 1
      -- the other restores the line's own style, which the reset never moved
      ut\assertEquals readings[DialectName.XyVsfilter], FontWeight.Normal

    -- `%g` alone caps a number at six significant digits and reaches for an exponent outside a narrow
    -- band of magnitudes, and a tag holding one reads back as its mantissa, so `\fs1234567.5` would
    -- come back as `\fs1` rather than as a wrong size.
    emitArguments_writesAFractionNoRendererWouldMisread: (ut) ->
      for params in *{"123456.75", "0.1234567", "1234567.5", "0.00001", "359.9999999"
          "100000000000000000000"}
        token = firstTag scanners[DialectName.Libass]\scan "{\\fscx#{params}}x"
        ut\assertEquals emitArguments(DialectName.Libass, token), params

    -- A nested tag holds commas of its own, so counting them alone would fill the four-argument
    -- signature and leave the clip torn between an acceleration and the tags. Both renderers apply
    -- the animated clip, which is what a template writing one relies on.
    parse_aNestedTagKeepsItsOwnCommas: (ut) ->
      for dialectName in *dialectNames
        token = firstTag scanners[dialectName]\scan "{\\t(0,500,\\clip(1,2,3,4))}x"
        ut\assertEquals #token.arguments, 3
        ut\assertEquals token.arguments[1], 0
        ut\assertEquals token.arguments[2], 500
        ut\assertTrue nil != tostring(token.arguments[3])\find "clip", 1, true

    -- with no timings the whole argument list is the nested tag, which animates the line's length
    parse_aTransformWithoutTimingsIsOneArgument: (ut) ->
      for dialectName in *dialectNames
        token = firstTag scanners[dialectName]\scan "{\\t(\\clip(1,2,3,4))}x"
        ut\assertEquals #token.arguments, 1

    -- Every dialect drops the whitespace trailing an argument, so `\bord4 ` reads as `\bord4` and
    -- `\rBold ` finds the style. Observed by rendering both renderers against the same tag written
    -- without the space, and in Aegisub through its own parser, which reports the parameter trimmed.
    parse_dropsWhitespaceTrailingAnArgument: (ut) ->
      for dialectName in *dialectNames
        ut\assertEquals firstTag(scanners[dialectName]\scan "{\\bord4 }x").arguments[1], 4
        ut\assertEquals firstTag(scanners[dialectName]\scan "{\\fnCourier New }x").arguments[1], "Courier New"
        ut\assertEquals firstTag(scanners[dialectName]\scan "{\\rBold }x").arguments[1], "Bold"

    -- An argument of whitespace alone is no argument at all: both renderers draw `{\bord }` as the
    -- bare tag, restoring the style's outline, where reading a zero would take the outline away.
    parse_readsAWhitespaceOnlyArgumentAsTheBareTag: (ut) ->
      for dialectName in *dialectNames
        for text in *{"{\\bord }x", "{\\fscx }x", "{\\fn }x", "{\\r }x"}
          token = firstTag scanners[dialectName]\scan text
          ut\assertEquals #token.arguments, 0
          -- the text is kept as written, so the scan stays lossless
          ut\assertEquals token.params, " "

    -- Aegisub drops the whitespace leading an argument as well as the whitespace trailing one, so it
    -- finds the style `{\r Bold}` names. Both renderers keep it and the lookup misses, which is why
    -- each draws the line's own style rather than the one written.
    parse_partsOverWhitespaceLeadingAStyleName: (ut) ->
      ut\assertEquals firstTag(scanners[DialectName.Aegisub]\scan "{\\r Bold}x").arguments[1], "Bold"
      for dialectName in *{DialectName.Libass, DialectName.XyVsfilter}
        ut\assertEquals firstTag(scanners[dialectName]\scan "{\\r Bold}x").arguments[1], " Bold"

    -- A font name has its leading whitespace skipped everywhere, which is the `\fn` handler's own
    -- doing rather than the general trimming above, so this holds in the renderers too.
    parse_dropsWhitespaceLeadingAFontNameInEveryDialect: (ut) ->
      for dialectName in *dialectNames
        ut\assertEquals firstTag(scanners[dialectName]\scan "{\\fn Courier New}x").arguments[1], "Courier New"

    -- a tag whose own arguments are commas must keep splitting on every one of them
    parse_aTagWithoutANestedTagStillSplits: (ut) ->
      for dialectName in *dialectNames
        for text in *{"{\\clip(1,2,3,4)}x", "{\\move(0,0,100,100)}x"}
          token = firstTag scanners[dialectName]\scan text
          ut\assertEquals #token.arguments, 4

    -- The emitter reads none of the parsed fields, so an edit to `arguments` is written back through
    -- here and assigned to `params`. Text that already says what it means comes back unchanged.
    emitArguments_writesACanonicalArgumentUnchanged: (ut) ->
      for text in *{"{\\b1}x", "{\\bord-2}x", "{\\fs+10}x", "{\\fnComic Sans MS}x", "{\\pos(10,20)}x"}
        token = firstTag scanners[DialectName.Libass]\scan text
        ut\assertEquals emitArguments(DialectName.Libass, token), token.params

    -- and text that does not comes back as the canonical way of writing what it meant, since reading
    -- dropped the spelling
    emitArguments_writesAQuirkAsWhatItMeant: (ut) ->
      canonical = (dialect, text) ->
        emitArguments dialect, firstTag scanners[dialect]\scan text
      ut\assertEquals canonical(DialectName.Libass, "{\\u1.5}x"), "1"
      ut\assertEquals canonical(DialectName.Libass, "{\\1cFF0000}x"), "&HFF0000&"
      ut\assertEquals canonical(DialectName.Libass, "{\\alpha80}x"), "&H80&"

    -- the values were typed per dialect, so writing them back is per dialect too
    emitArguments_writesADurationAsItsDialectReadIt: (ut) ->
      libass = firstTag scanners[DialectName.Libass]\scan "{\\k50.9}x"
      aegisub = firstTag scanners[DialectName.Aegisub]\scan "{\\k50.9}x"
      ut\assertEquals emitArguments(DialectName.Libass, libass), "50.9"
      ut\assertEquals emitArguments(DialectName.Aegisub, aegisub), "50"

    emitArguments_writesABareTagAsNoArgumentsAtAll: (ut) ->
      ut\assertEquals emitArguments(DialectName.Libass, firstTag scanners[DialectName.Libass]\scan "{\\b}x"), ""

    emit_takesATransformEditedThroughItsTags: (ut) ->
      tokens = scanners[DialectName.Libass]\scan "{\\t(0,100,\\bord2)}text"
      for token in *tokens
        continue unless token.children
        child.params = "9" for child in *token.children when child.kind == TokenKind.Tag
        token.params = emit token.children
      ut\assertEquals emit(tokens), "{\\t(0,100,\\bord9)}text"
  }

  for case in *corpus
    for dialect in *dialectNames
      tests["scan_#{case.name}_#{dialect}"] = (ut) ->
        ut\assertEquals describe(joinText scanners[dialect]\scan case.input), describe case[dialect]

      tests["emit_#{case.name}_#{dialect}"] = (ut) ->
        ut\assertEquals emit(scanners[dialect]\scan case.input), case.input

  tests
