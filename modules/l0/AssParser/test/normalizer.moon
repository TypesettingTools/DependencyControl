-- cspell:ignore blurinf -- a tag written against its argument, as `clipm` is
-- cspell:ignore HFFFFFF -- a color literal written out in a fixture, not a word
--
-- Pins the normalizer against the equivalences it is meant to act on. Every row
-- `value-equivalences` records as safe for both renderers has to come out rectified into its canonical
-- spelling, every row safe for only one has to come out untouched and reported, and a tag that reads at
-- face value has to come out byte for byte, so the files cannot drift apart without a failure here.
-- Called from test.moon as: (controls\requireTest "normalizer") controls\requireTest "value-equivalences"
--
-- The strongest case is the last: a line is rewritten and the result is put back to the oracle. That
-- checks the property the design rests on — nothing is kept unchecked — rather than any particular
-- rewrite, so it keeps holding as the rules change underneath it.
(equivalences) ->
  normalizer = require "l0.AssParser.normalizer"
  {:isEquivalent} = require "l0.AssParser.diagnostics"
  {:DialectName} = require "l0.AssParser.dialects"
  {:emit} = require "l0.AssParser.emitter"
  Scanner = require "l0.AssParser.Scanner"
  Ass = require "l0.AssParser.ass"
  {:WrapStyle, :defaultStyle} = Ass

  renderers = {DialectName.Libass, DialectName.XyVsfilter}

  normalizeLineAndEmit = (line, options) ->
    tokens, _, divergences, changes, styleToDeclare = normalizer.normalizeLine line, options
    emit(tokens), divergences, changes, styleToDeclare

  ---The one change a line is expected to have produced.
  ---@param written string The line to normalize.
  ---@param reference? AssDialectName Which dialect to converge the others onto.
  ---@return AssNormalizeChange
  onlyChange = (written, reference) ->
    _, _, changes = normalizeLineAndEmit written, {targets: renderers, referenceDialect: reference}
    changes[1]

  tests = {
    _description: "Rewrites the tags of a line that do not mean what they say into the spelling of
      what they mean, keeps a face-value tag byte for byte however redundant, and reports the tags
      the target dialects disagree about instead of applying them."

    -- What was rewritten is reported beside the line, keyed to the bytes it was read from, so a caller
    -- can put a change next to the finding that named the same tag. The range covers the backslash the
    -- tag was written with, as a finding's does.
    normalizeLine_reportsWhatItRewrote: (ut) ->
      change = onlyChange "{\\b1\\c&H00FFFFFF&\\bord2}abc"
      ut\assertEquals change.kind, "tag"
      ut\assertEquals emit(change.before), "\\c&H00FFFFFF&"
      ut\assertEquals emit(change.after), "\\c&HFFFFFF&"
      -- one token on each side, the tag as it was and the tag as it now reads
      ut\assertEquals #change.before, 1
      ut\assertEquals #change.after, 1
      ut\assertEquals change.before[1].name, "c"
      ut\assertEquals change.after[1].name, "c"
      ut\assertNil change.converged

    -- A line every dialect already reads at face value is reported as changed in nothing, which is what
    -- tells a caller there is nothing to record rather than that recording failed.
    normalizeLine_reportsNoChangeWhereItRewroteNothing: (ut) ->
      for written in *{"{\\bord2}abc", "{\\1c&HFFFFFF&}abc", "plain text"}
        _, _, changes = normalizeLineAndEmit written, {targets: renderers}
        ut\assertEquals #changes, 0

    -- Whitespace around an argument is dropped by every dialect before the argument is read, so
    -- writing the tag without it says the same thing. An argument of whitespace alone means the bare
    -- tag, which is why `{\bord }` becomes `{\bord}` and not the `{\bord0}` a zero would spell: both
    -- renderers were observed drawing the first as the style's own outline and the second without one.
    normalizeLine_writesAnArgumentWithoutTheWhitespaceEveryDialectDrops: (ut) ->
      expected = {
        "{\\bord }X": "{\\bord}X"
        "{\\fscx }X": "{\\fscx}X"
        "{\\bord4 }X": "{\\bord4}X"
        "{\\fnCourier New }X": "{\\fnCourier New}X"
        "{\\fn Courier New}X": "{\\fnCourier New}X"
        -- the sign is what makes a size relative, so the text is trimmed rather than the value written back
        "{\\fs+10 }X": "{\\fs+10}X"
      }
      for written, want in pairs expected
        ut\assertEquals normalizeLineAndEmit(written, {targets: renderers}), want

    -- A bare tag is canonical wherever the targets agree what it restores, and after a `\r` naming
    -- another style they do not: libass restores the style that `\r` put in force and VSFilter the
    -- line's own. Without a reference there is nothing to prefer, so the line stands; with one, the
    -- value is spelled out and the other target is marked converged, which is what says its picture
    -- changed. Both readings were observed by rendering the two styles against each other.
    normalizeLine_spellsOutABareTagOnlyWhereTheTargetsPartOverIt: (ut) ->
      styleNegative = {key, value for key, value in pairs defaultStyle}
      styleNegative.name = "Negative"
      styleNegative.outline = 0
      styles = {Default: defaultStyle, Negative: styleNegative}
      written = "{\\rNegative\\bord}X"

      -- neither reading is wrong, so nothing is rewritten
      ut\assertEquals normalizeLineAndEmit(written, {targets: renderers, style: defaultStyle, stylesByName: styles}), written

      for {reference, want, converged} in *{
          {DialectName.Libass, "{\\rNegative\\bord0}X", DialectName.XyVsfilter}
          {DialectName.XyVsfilter, "{\\rNegative\\bord2}X", DialectName.Libass}
        }
        rewritten, _, changes = normalizeLineAndEmit written, {targets: renderers, style: defaultStyle, stylesByName: styles, referenceDialect: reference}
        ut\assertEquals rewritten, want
        ut\assertEquals #changes, 1
        ut\assertEquals changes[1].converged[1], converged

    -- Where the targets agree what a bare tag restores, which is every line without a `\r` to another
    -- style, the bare form is the spelling and naming a reference changes nothing.
    normalizeLine_keepsABareTagTheTargetsAgreeOn: (ut) ->
      for reference in *{nil, DialectName.Libass, DialectName.XyVsfilter}
        ut\assertEquals normalizeLineAndEmit("{\\bord}X", {targets: renderers, style: defaultStyle, referenceDialect: reference}), "{\\bord}X"
        ut\assertEquals normalizeLineAndEmit("{\\fscx}X", {targets: renderers, style: defaultStyle, referenceDialect: reference}), "{\\fscx}X"

    -- A color literal holding no digit puts the style's own value back for a dialect that refuses one,
    -- exactly as the bare tag does, so there the bare tag is its spelling. libass reads it as a value
    -- instead, so the two part and only a named reference settles which spelling the line takes.
    normalizeLine_writesARefusedColorLiteralAsTheBareTag: (ut) ->
      for {reference, want} in *{
          {DialectName.XyVsfilter, "{\\c}x"}
          {DialectName.Libass, "{\\c&H000000&}x"}
        }
        ut\assertEquals normalizeLineAndEmit("{\\c&H&}x", {targets: renderers, referenceDialect: reference}), want
      -- neither spelling holds for both, so with no reference the line stands as written
      ut\assertEquals normalizeLineAndEmit("{\\c&H&}x", {targets: renderers}), "{\\c&H&}x"

    -- Where two targets canonicalize a tag differently there is nothing to prefer one by without a
    -- reference, so the result must not fall out of the order the targets were passed in. A color
    -- literal holding no digit is that case, one target writing the bare tag and the other the value.
    normalizeLine_doesNotDependOnTheOrderOfItsTargets: (ut) ->
      reversed = {DialectName.XyVsfilter, DialectName.Libass}
      for written in *{"{\\c&H&}x", "{\\1a&H&}x", "{\\bord-2}x", "{\\b2}x", "{\\be0.6}x"}
        ut\assertEquals normalizeLineAndEmit(written, {targets: renderers}),
          normalizeLineAndEmit written, {targets: reversed}

    -- `\1a&H&` reads as zero for one target and as the style's own alpha for the other, so both the
    -- stated value and the bare tag hold for both only where that alpha is zero. Where it is, the
    -- stated value is written; where it is not, neither spelling holds and the line stands.
    normalizeLine_writesAnEmptyAlphaLiteralOutWhereTheStyleAllowsIt: (ut) ->
      translucent = {key, value for key, value in pairs defaultStyle}
      translucent.color1 = "&H80FFFFFF&"
      ut\assertEquals normalizeLineAndEmit("{\\1a&H&}x", {targets: renderers, style: defaultStyle}), "{\\1a&H00&}x"
      ut\assertEquals normalizeLineAndEmit("{\\1a&H&}x", {targets: renderers, style: translucent}), "{\\1a&H&}x"

    -- Whitespace leading a style name is dropped by Aegisub alone, so both renderers miss the style and
    -- draw the line's own. Writing it away would hand them the style the line never got, which is why
    -- this one stays as written while the trailing space beside it goes.
    normalizeLine_keepsWhitespaceLeadingAStyleName: (ut) ->
      styles = {Default: defaultStyle, Bold: {key, value for key, value in pairs defaultStyle}}
      styles.Bold.name = "Bold"
      ut\assertEquals normalizeLineAndEmit("{\\r Bold}X", {targets: renderers, style: defaultStyle, stylesByName: styles}), "{\\r Bold}X"
      ut\assertEquals normalizeLineAndEmit("{\\rBold }X", {targets: renderers, style: defaultStyle, stylesByName: styles}), "{\\rBold}X"

    -- A rewrite made to converge a target on the reference names that target, since the picture it
    -- draws changes where every other rewrite leaves every target's picture alone. A renderer check
    -- reads this to know which of its comparisons is expected to differ.
    normalizeLine_marksARewriteThatConvergesATarget: (ut) ->
      change = onlyChange "{\\p1}m 0 0 l 100 0 b 10 10 20 20{\\p0}", DialectName.Libass
      ut\assertEquals change.kind, "drawing"
      ut\assertEquals emit(change.after), "m 0 0 l 100 0"
      ut\assertEquals table.concat(change.converged, ","), DialectName.XyVsfilter

    -- A change names tokens rather than offsets, so locating one in either line goes through the two
    -- streams. The original keeps the bytes the line arrived with, so a tag is still found there after
    -- an earlier tag on the same line has been rewritten to a different length.
    normalizeLine_locatesAChangeInBothLines: (ut) ->
      written = "{\\alpha&20\\bord2\\c&H00FFFFFF&}abc"
      tokens, original, _, changes = normalizer.normalizeLine written, {targets: renderers}
      ut\assertEquals #changes, 2

      rewritten = emit tokens
      ut\assertEquals emit(original), written
      spans = normalizer.getChangeSpans changes, original, tokens

      -- a span brackets what the tokens on its side emit as, a tag's own backslash included
      for index, change in ipairs changes
        at = spans[index]
        ut\assertEquals written\sub(at.startIndex, at.endIndex), emit change.before
        ut\assertEquals rewritten\sub(at.rewrittenStartIndex, at.rewrittenEndIndex), emit change.after

    -- A rewrite that takes a token out has nothing to point at in the rewritten line, so its span
    -- there is the empty one at the point the token stood. Two removals in a row reach the same point,
    -- there being nothing between them once both are gone.
    normalizeLine_locatesARemovalAtThePointItStood: (ut) ->
      written = "{\\\\}x"
      tokens, original, _, changes = normalizer.normalizeLine written, {targets: renderers}
      ut\assertEquals emit(tokens), "{}x"
      ut\assertEquals #changes, 2

      spans = normalizer.getChangeSpans changes, original, tokens
      for index, change in ipairs changes
        at = spans[index]
        -- nothing left of it in the rewritten line, and the backslash still there in the original
        ut\assertEquals #change.after, 0
        ut\assertEquals written\sub(at.startIndex, at.endIndex), emit change.before
        ut\assertEquals at.rewrittenEndIndex, at.rewrittenStartIndex - 1

      ut\assertEquals spans[1].rewrittenStartIndex, spans[2].rewrittenStartIndex

    normalizeLine_leavesAnAlreadyMinimalLineAlone: (ut) ->
      text = "{\\k50}a{\\b1}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- A drawing is rectified by dropping only what every renderer was observed to spend nothing on: a
    -- word holding no number and whatever follows it up to the next command, a spline extension with
    -- too few nodes behind it, and a trailing coordinate too short to make a point.
    normalizeLine_dropsWhatNoRendererSpendsInADrawing: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\p1}m 0 0 l 100 0 l 100 100 junk{\\p0}a"),
        "{\\p1}m 0 0 l 100 0 l 100 100{\\p0}a"
      ut\assertEquals normalizeLineAndEmit("{\\p1}m 0 0 l 100 0 l 100 100 x 5 5 l 0 100{\\p0}a"),
        "{\\p1}m 0 0 l 100 0 l 100 100 l 0 100{\\p0}a"
      ut\assertEquals normalizeLineAndEmit("{\\p1}m 0 0 p 300 0 l 100 100{\\p0}a"),
        "{\\p1}m 0 0 l 100 100{\\p0}a"
      ut\assertEquals normalizeLineAndEmit("{\\p1}m 0 0 l 100 0 l 100 100 l 300{\\p0}a"),
        "{\\p1}m 0 0 l 100 0 l 100 100{\\p0}a"

    -- A drawing that says what it means is kept byte for byte, whatever whitespace it was written with
    normalizeLine_leavesAWellFormedDrawingAlone: (ut) ->
      for text in *{"{\\p1}m 0 0 l 100 0 l 100 100 l 0 100{\\p0}a", "{\\p1}m 0 0   l 100 0  l 100 100{\\p0}a"}
        ut\assertEquals normalizeLineAndEmit(text), text

    -- A move reaching no point is what lets the open move after it become the root in libass, so
    -- dropping it would turn a drawing that renders there into one no renderer draws.
    normalizeLine_keepsAMoveThatReachesNoPoint: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\p1}m junk n 0 0 l 100 0{\\p0}a"), "{\\p1}m n 0 0 l 100 0{\\p0}a"

    -- Something written against a command letter does not swallow it. Every renderer scans a drawing
    -- character by character and passes over a character naming no command without consuming what
    -- follows, so all four of these open a move at the origin and were drawn doing so in both.
    normalizeLine_readsPastJunkBeforeACommand: (ut) ->
      whole = "{\\p1}m 0 0 l 100 0 m 200 200 l 300 200{\\p0}a"
      for written in *{"}", "}}", "(", "x", "m"}
        ut\assertEquals normalizeLineAndEmit("{\\p1}#{written}m 0 0 l 100 0 m 200 200 l 300 200{\\p0}a"), whole

    -- Junk standing between a command and its numbers is the other case: it ends the run, and the
    -- numbers behind it reach no command, so the first contour goes and the drawing starts at the next.
    normalizeLine_dropsNumbersJunkCutsOffFromTheirCommand: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\p1}m} 0 0 l 100 0 m 200 200 l 300 200{\\p0}a"),
        "{\\p1}m 200 200 l 300 200{\\p0}a"

    -- A command reaching for nodes it has not got is ignored by every reader wherever it stands, so it
    -- goes wherever it stands too. Four readings of the VSFilter line were each shown drawing such a
    -- drawing exactly as they draw the contour behind it written alone.
    normalizeLine_dropsACommandStandingBeforeTheFirstMove: (ut) ->
      for written in *{"l 100 0", "b 1 2 3 4 5 6", "p 1 2"}
        ut\assertEquals normalizeLineAndEmit("{\\p1}#{written} m 0 0 l 50 50{\\p0}a"),
          "{\\p1}m 0 0 l 50 50{\\p0}a"

    -- A drawing left open runs the line's own words into it, gluing the last coordinate to the first of
    -- them. Every renderer hands the position to `strtod`, which reads the number and stops at the `W`,
    -- so the coordinate is the drawing's and only the words behind it go.
    normalizeLine_keepsACoordinateWrittenAgainstTheTextBehindIt: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\p1}m 0 0 l 100 0 l 100 100 l 0 100With the blue sky"),
        "{\\p1}m 0 0 l 100 0 l 100 100 l 0 100"

    -- The two malformations the renderers part on have no spelling that means one thing to both, so
    -- they are left exactly as written: points that do not complete a curve, and a drawing that never
    -- reaches a first point and so draws nothing anywhere.
    normalizeLine_leavesADivergentDrawingAlone: (ut) ->
      for text in *{"{\\p1}m 0 0 l 100 0 b 300 100 300 0{\\p0}a", "{\\p1}l 100 0 l 100 100{\\p0}a"}
        ut\assertEquals normalizeLineAndEmit(text), text

    -- Named a reference, the drawing is written as that dialect reads it, so a divergence is converged
    -- rather than only reported. Orphaned points are what libass drops, and writing them away makes
    -- VSFilter draw what libass already drew.
    normalizeLine_convergesOrphanedPointsOnTheReference: (ut) ->
      text = "{\\p1}m 0 0 l 100 0 b 300 100 300 0{\\p0}a"
      -- libass discards the points, so writing them away is its reading and VSFilter then agrees
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, referenceDialect: DialectName.Libass}),
        "{\\p1}m 0 0 l 100 0{\\p0}a"
      -- VSFilter keeps them in the path, and a contour of no area puts them there for every dialect,
      -- which was matched pixel for pixel against the drawing as written
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, referenceDialect: DialectName.XyVsfilter}),
        "{\\p1}m 0 0 l 100 0 m 300 100 l 300 0 l 300 100{\\p0}a"
      -- named no reference, neither picture may move, so the points stay as written
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers}), text

    -- libass opens a drawing at an open move that follows a move reaching no point, where VSFilter
    -- draws nothing at all. Writing that root as an ordinary move is libass's reading spelled so that
    -- VSFilter reaches it too; there is no contour before the first for the two moves to differ over.
    normalizeLine_convergesARootTakenFromAnOpenMove: (ut) ->
      text = "{\\p1}m junk n 0 0 l 100 0 l 100 100{\\p0}a"
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, referenceDialect: DialectName.Libass}),
        "{\\p1}m 0 0 l 100 0 l 100 100{\\p0}a"
      -- with no reference only the unreadable word goes, since the move is what libass opens on
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers}), "{\\p1}m n 0 0 l 100 0 l 100 100{\\p0}a"

    -- A drawing the reference draws no part of reads as no drawing at all, so converging on it takes
    -- the drawing out. The `\p` pair is left standing, since removing a tag is cleanup rather than
    -- rectification and belongs to whatever runs after authoring.
    normalizeLine_removesADrawingTheReferenceDrawsNoPartOf: (ut) ->
      -- VSFilter draws nothing where an open move stands in for a move that reached no point
      ut\assertEquals normalizeLineAndEmit("{\\p1}m junk n 0 0 l 100 0 l 100 100{\\p0}a",
        {targets: renderers, referenceDialect: DialectName.XyVsfilter}), "{\\p1}{\\p0}a"
      -- and neither draws a thing where nothing opens the drawing at all
      ut\assertEquals normalizeLineAndEmit("{\\p1}l 100 0 l 100 100{\\p0}a",
        {targets: renderers, referenceDialect: DialectName.Libass}), "{\\p1}{\\p0}a"

    -- A drawing ends a karaoke syllable whether or not it draws anything, observed in both renderers:
    -- a degenerate `{\p1}m 0 0{\p0}` splits a line in two where an empty `{\p1}{\p0}` splits nothing.
    -- Taking the drawing out would move the timing of every syllable after it, so where the line names
    -- a karaoke tag the drawing stays and the divergence is reported instead.
    normalizeLine_keepsADrawingWhoseSyllableCarriesTiming: (ut) ->
      for reference in *{DialectName.Libass, DialectName.XyVsfilter}
        for text in *{"{\\k50}b{\\p1}m junk n 0 0 l 100 0{\\p0}a", "{\\k50}b{\\p1}l 100 0 l 100 100{\\p0}a"}
          rewritten = normalizeLineAndEmit text, {targets: renderers, referenceDialect: reference}
          ut\assertContains rewritten, "{\\p1}"
          ut\assertFalse rewritten == "{\\k50}b{\\p1}{\\p0}a"

    normalizeLine_leavesALineWithoutTagsAlone: (ut) ->
      ut\assertEquals normalizeLineAndEmit("plain text"), "plain text"

    -- A redundant tag is not a quirky one: it means exactly what it says, and its explicit value or
    -- its layout may be what a later transformation keys on. Rectifying keeps it byte for byte.
    normalizeLine_leavesAFaceValueArgumentAlone: (ut) ->
      text = "{\\k50}a{\\fs48}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    normalizeLine_neverMergesRedundantTags: (ut) ->
      text = "{\\fscx50\\fscx80}ab"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- 700 is an accepted weight in both renderers, whatever units each holds it in afterwards
    normalizeLine_leavesAnExplicitWeightAlone: (ut) ->
      text = "{\\k50}a{\\b700}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    normalizeLine_writesARefusedArgumentAsABareTag: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\b2}b"), "{\\k50}a{\\b}b"

    normalizeLine_writesANegativeArgumentAsZero: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\bord-2}b"), "{\\k50}a{\\bord0}b"

    normalizeLine_writesAFractionalFlagAsAWholeNumber: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\u1.5}b"), "{\\k50}a{\\u1}b"

    -- Every implementation reads a bare run of hex digits and writes the `&H…&` a style is written
    -- with, so the notation is a spelling question with one canonical answer.
    normalizeLine_writesABareColorInTheStyleNotation: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\1cFF0000}b"), "{\\k50}a{\\1c&HFF0000&}b"

    normalizeLine_writesAColorInUpperCase: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\1c&Hff0000&}b"), "{\\k50}a{\\1c&HFF0000&}b"

    -- a transparency is two digits where a color is six, which is why they are separate argument types
    normalizeLine_writesAnAlphaInItsOwnNotation: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\alpha80}b"), "{\\k50}a{\\alpha&H80&}b"
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\3a80}b"), "{\\k50}a{\\3a&H80&}b"

    normalizeLine_leavesACanonicalColorAlone: (ut) ->
      text = "{\\k50}a{\\1c&HFF0000&}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- karaoke arguments are durations rather than appearances, so however they are spelled the
    -- normalizer leaves them alone
    normalizeLine_neverRewritesAKaraokeArgument: (ut) ->
      text = "{\\k50.9}a{\\kf0}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- the tag both renderers refuse to clamp, which reads like the one they do
    normalizeLine_keepsANegativeTheRenderersHold: (ut) ->
      text = "{\\k50}a{\\xshad-2}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- libass has no grammar for `inf` or `nan` and reads either as zero, and xy-VSFilter was observed
    -- drawing both as a zero for these five tags, so `0` is the spelling and no reference is needed to
    -- write it. A blur is the tag that parts from them: VSFilter aborts on an infinite radius rather
    -- than drawing anything, so there is no picture for a finite spelling to keep.
    normalizeLine_writesANonFiniteArgumentAsTheZeroItDraws: (ut) ->
      for tagName in *{"bord", "shad", "xshad", "yshad", "be"}
        for argument in *{"inf", "-inf", "nan"}
          ut\assertEquals normalizeLineAndEmit("{\\#{tagName}#{argument}}x", {targets: renderers, style: defaultStyle}),
            "{\\#{tagName}0}x"

      for argument in *{"inf", "nan"}
        text = "{\\blur#{argument}}x"
        ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, style: defaultStyle}), text

    -- A hex numeral is 16 to VSFilter's conversion and 0 to libass's, so it has to be written out as a
    -- decimal numeral even where the dialect doing the writing reads it at face value. The two read it
    -- as different numbers, so neither spelling holds for both and only a named reference settles it.
    normalizeLine_writesAHexNumeralAsADecimalOne: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\bord0x10}x",
        {targets: renderers, style: defaultStyle, referenceDialect: DialectName.XyVsfilter}), "{\\bord16}x"
      ut\assertEquals normalizeLineAndEmit("{\\bord0x10}x",
        {targets: renderers, style: defaultStyle, referenceDialect: DialectName.Libass}), "{\\bord0}x"
      ut\assertEquals normalizeLineAndEmit("{\\bord0x10}x", {targets: renderers, style: defaultStyle}), "{\\bord0x10}x"
      -- a decimal numeral saying what it means is still left byte for byte
      ut\assertEquals normalizeLineAndEmit("{\\bord16}x", {targets: renderers, style: defaultStyle}), "{\\bord16}x"
      ut\assertEquals normalizeLineAndEmit("{\\bord2.0}x", {targets: renderers, style: defaultStyle}), "{\\bord2.0}x"

    -- A karaoke template is expanded into the lines that are drawn, so every reading a rewrite would be
    -- checked against is a reading of the template. The blur is one the normalizer holds down on any
    -- other line, which is what says the whole line was left alone rather than nothing having applied.
    normalizeLine_leavesAKaraokeTemplateAsWritten: (ut) ->
      text = "{\\pos($center,$middle)\\blur9000}x"
      ut\assertEquals normalizeLineAndEmit({:text, effect: "template syl"}, {targets: renderers, style: defaultStyle}), text
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, style: defaultStyle}), text
      -- declared by the effect alone, holding no substitution of its own
      ut\assertEquals normalizeLineAndEmit({text: "{\\blur9000}x", effect: "code syl"},
        {targets: renderers, style: defaultStyle}), "{\\blur9000}x"
      -- and an ordinary line is still rewritten, effect or no effect
      ut\assertEquals normalizeLineAndEmit({text: "{\\blur9000}x", effect: "karaoke"},
        {targets: renderers, style: defaultStyle}), "{\\blur7680}x"

    -- Past a radius of 7680 xy-VSFilter aborts instead of drawing the line, and libass holds every
    -- radius above 100 to 100, so writing the largest that draws keeps libass's picture whatever the
    -- line said and gets VSFilter to draw one at all. That holds with no reference named, while a
    -- libass reference writes libass's own bound instead.
    normalizeLine_holdsABlurToTheLargestRadiusThatDraws: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\blur9000}a", {targets: renderers, style: defaultStyle}), "{\\blur7680}a"
      ut\assertEquals normalizeLineAndEmit("{\\blur500}a", {targets: renderers, style: defaultStyle}), "{\\blur500}a"
      ut\assertEquals normalizeLineAndEmit("{\\blur9000}a",
        {targets: renderers, style: defaultStyle, referenceDialect: DialectName.Libass}), "{\\blur100}a"
      -- libass draws an infinity as nothing and no radius shares that picture, so nothing is written
      ut\assertEquals normalizeLineAndEmit("{\\blurinf}a", {targets: renderers, style: defaultStyle}), "{\\blurinf}a"

    -- Both renderers put the script's wrap style back for an argument outside the declared four, as
    -- a bare `\q` does. The script has to state the no-wrap style, or restoring and keeping the 9
    -- read alike and the rewrite is accepted without saying anything.
    normalizeLine_writesAnOutOfRangeWrapStyleAsABareTag: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\q9}{\\k50}aa\\nbb", {targets: renderers, wrapStyle: WrapStyle.NoWordWrap}
      ut\assertEquals rewritten, "{\\q}{\\k50}aa\\nbb"
      ut\assertEquals #divergences, 0

    -- an argument holding no number converts to zero rather than restoring, so zero is its spelling
    normalizeLine_writesAJunkWrapStyleAsZero: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\qabc}{\\k50}aa\\nbb", {targets: renderers, wrapStyle: WrapStyle.NoWordWrap}
      ut\assertEquals rewritten, "{\\q0}{\\k50}aa\\nbb"
      ut\assertEquals #divergences, 0

    normalizeLine_leavesADeclaredWrapStyleAlone: (ut) ->
      text = "{\\q2}{\\k50}aa\\nbb"
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, wrapStyle: WrapStyle.NoWordWrap}), text

    -- A rewrite reaches a tag through the transform's own token stream, and the transform's argument
    -- text is written back from it. Spelled here with a rewrite that changes no value, since one that
    -- does cannot be made inside a window at all.
    normalizeLine_rectifiesAQuirkInsideATransform: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\t(0,100,\\1c&ffffff&)}b"),
        "{\\k50}a{\\t(0,100,\\1c&HFFFFFF&)}b"

    -- The quirk is rectified through both transforms, and the pair is then written side by side, which
    -- is how the renderers read it. The `)` left over was junk in the line as it arrived and stays so.
    normalizeLine_rectifiesAQuirkInsideANestedTransform: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\k50}a{\\t(0,200,\\t(0,100,\\1c&ffffff&))}b"),
        "{\\k50}a{\\t(0,200,)\\t(0,100,\\1c&HFFFFFF&)}b"

    -- A color literal wearing a prefix with no digits behind it is black to libass and the style's own
    -- to xy-VSFilter, drawn against a style holding neither and alike at block level and inside a
    -- window. No spelling means the same to both, so it stands unless libass is named, and naming it
    -- makes the rewrite one that moves VSFilter's picture on purpose.
    normalizeLine_keepsAColorLiteralTheRenderersReadApart: (ut) ->
      for written in *{"{\\c&&}x", "{\\t(0,1000,\\c&&)}x"}
        ut\assertEquals normalizeLineAndEmit(written, {targets: renderers}), written

      ut\assertEquals normalizeLineAndEmit("{\\c&&}x", {targets: renderers, referenceDialect: DialectName.Libass}),
        "{\\c&H000000&}x"
      change = onlyChange "{\\c&&}x", DialectName.Libass
      ut\assertEquals table.concat(change.converged, ","), DialectName.XyVsfilter

    -- digits behind the prefix are read by both, so that one canonicalizes as any other literal does
    normalizeLine_writesALiteralWhoseDigitsBothRead: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\3c&660066&}x", {targets: renderers}), "{\\3c&H660066&}x"

    -- A value the renderers refuse acts as the bare tag where it is written outright, and animates
    -- toward the number itself inside a window: both interpolate what was written and hold only what
    -- they draw, so `\bord-2` reaches the floor partway and stays there. Closing the window at that
    -- moment and animating to the floor instead draws the same line from end to end, which is why the
    -- window moves rather than the argument alone. Both were rendered against each other to settle it.
    normalizeLine_shortensATransformReachingItsBound: (ut) ->
      approximate = {targets: renderers, allowApproximateNormalizations: true}

      -- the style's own border is 2, so from 2 toward -2 the floor is reached halfway through
      ut\assertEquals normalizeLineAndEmit("{\\fs40\\t(0,100,\\bord-2)}b", approximate),
        "{\\fs40\\t(0,50,\\bord0)}b"

      -- The acceleration is kept as written and only the closing time moves, the window being cut where
      -- the accelerated value reaches the floor rather than halfway along it. From 4 toward -12 with the
      -- progress squared that is a quarter of the distance, so half of the window.
      ut\assertEquals normalizeLineAndEmit("{\\bord4\\t(0,1000,2,\\bord-12)}b", approximate),
        "{\\bord4\\t(0,500,2,\\bord0)}b"

    -- The rewrite draws a line the renderers read alike only up to the last bit of the arithmetic, which
    -- a measurement taken off the frame can tell, so nothing here happens unless it is asked for.
    normalizeLine_leavesATransformAloneWithoutApproximationAllowed: (ut) ->
      for text in *{"{\\fs40\\t(0,100,\\bord-2)}b", "{\\bord4\\t(0,1000,2,\\bord-12)}b"}
        ut\assertEquals normalizeLineAndEmit(text, {targets: renderers}), text

    -- Both renderers read an interval as whole milliseconds, so a crossing falling between two of them
    -- is spelled as the nearer one and the window animates a fraction faster than the one it stands for.
    -- From 2 toward -2 with the progress squared the floor is reached at 4242.64ms.
    normalizeLine_roundsACrossingOnlyWhereAskedTo: (ut) ->
      text = "{\\bord2\\t(0,6000,2,\\bord-2)}b"
      approximate = {targets: renderers, allowApproximateNormalizations: true}
      ut\assertEquals normalizeLineAndEmit(text, approximate), text

      rounding = {targets: renderers, allowApproximateNormalizations: true,
        allowRoundedTransformCrossings: true}
      ut\assertEquals normalizeLineAndEmit(text, rounding), "{\\bord2\\t(0,4243,2,\\bord0)}b"

      -- the border moves by 0.00034 pixels at the widest, so a bound below that turns the rewrite away
      held = {targets: renderers, allowApproximateNormalizations: true,
        allowRoundedTransformCrossings: true, largestAcceptedError: 0.0001}
      ut\assertEquals normalizeLineAndEmit(text, held), text

    -- `\fs` at or below zero puts the style's own size back rather than landing on a bound, and a target
    -- already at the bound reaches it only as the window closes. Neither names a moment to close a
    -- shorter window at, so neither is rewritten.
    normalizeLine_keepsATransformWithNoBoundToReach: (ut) ->
      for written in *{"\\t(0,2000,\\fs0)", "\\t(0,2000,\\fscx0)"}
        text = "{\\fs40#{written}}b"
        ut\assertEquals normalizeLineAndEmit(text), text

      -- written outright it is still the bare tag, which is the case the equivalence was read from
      ut\assertEquals normalizeLineAndEmit("{\\fs40\\fs0}b"), "{\\fs40\\fs}b"

    -- A transform holding another replaces the window it sits in for everything after it, which both
    -- renderers were observed doing, so the two draw what a pair written side by side draws. Writing
    -- them that way is what stops the nesting reading as one animation driving another.
    normalizeLine_splitsATransformHoldingAnother: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\t(0,100,\\fscy150\\t(5000,6000,\\fscx200))}MMMM"),
        "{\\t(0,100,\\fscy150)\\t(5000,6000,\\fscx200)}MMMM"

    -- Splitting one pair can leave another, so the pass repeats until the line holds none.
    -- The pair rule applied twice, so all three end up side by side. Asserted on the text rather than
    -- on how many changes it took, which counts the repairs the same line needs as well as the splits.
    normalizeLine_splitsATransformHoldingTwoMore: (ut) ->
      rewritten = normalizeLineAndEmit "{\\t(0,100,\\t(200,300,\\t(5000,6000,\\fscx200)))}MMMM"
      ut\assertContains rewritten, "\\t(0,100,)"
      ut\assertContains rewritten, "\\t(200,300,)"
      ut\assertContains rewritten, "\\t(5000,6000,\\fscx200)"

    -- Both renderers read `\fad` and `\fade` as one tag whose shape is picked by how many arguments it
    -- was given, the name being ignored, so the name that states the count is the spelling of what the
    -- tag does. Each of these was drawn in both renderers beside the renamed line and matched it.
    normalizeLine_namesAFadeForItsArgumentCount: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\fade(0,200)}x"), "{\\fad(0,200)}x"
      ut\assertEquals normalizeLineAndEmit("{\\fad(255,0,255,0,1,2,3)}x"), "{\\fade(255,0,255,0,1,2,3)}x"

    -- a count neither shape takes fades under neither name, so there is no spelling to move it to
    normalizeLine_leavesAFadeNoShapeTakesAlone: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\fad(0,200,400)}x"), "{\\fad(0,200,400)}x"

    -- an argument list runs to the end of its block whether or not it closes, so closing it says what
    -- both renderers already read
    normalizeLine_closesAnArgumentListLeftOpen: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\fad(0,750}x"), "{\\fad(0,750)}x"

    -- A backslash naming no tag is read past by every dialect. It cannot be a marker an automation
    -- script keys on either, being ASS syntax already.
    normalizeLine_takesOutABackslashNamingNoTag: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\fs40\\\\blur0.6}x"), "{\\fs40\\blur0.6}x"
      ut\assertEquals normalizeLineAndEmit("{\\fs40\\\\\\blur0.6}x"), "{\\fs40\\blur0.6}x"

    -- A tag declaring no bare form reads as nothing when written with no arguments, so it draws like a
    -- backslash naming no tag and goes the same way. Its braces go with it where it stood alone in the
    -- block, since an emptied `{}` would only be a second finding in place of the first.
    normalizeLine_takesOutABareTagWithNoBareForm: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\pos}ab"), "ab"
      ut\assertEquals normalizeLineAndEmit("{\\clip}ab"), "ab"
      ut\assertEquals normalizeLineAndEmit("{\\move}{\\org}{\\fad}ab"), "ab"
      -- whitespace and empty parentheses read as the bare form too
      ut\assertEquals normalizeLineAndEmit("{\\pos   }ab"), "ab"
      ut\assertEquals normalizeLineAndEmit("{\\pos()}ab"), "ab"
      -- the braces stay where another tag still stands in them
      ut\assertEquals normalizeLineAndEmit("{\\b1\\pos}ab"), "{\\b1}ab"

    -- Arguments matching no signature read as nothing just as a bare tag does, but which of them were
    -- meant cannot be recovered, so the line keeps them and the finding names them instead.
    normalizeLine_keepsATagWhoseArgumentsMatchNoSignature: (ut) ->
      for text in *{"{\\pos(1,2,3)}ab", "{\\pos(1)}ab", "{\\pos1,2}ab", "{\\fad(1,2,3)}ab"}
        ut\assertEquals normalizeLineAndEmit(text), text

    -- A transform whose interval has no width steps at the moment it names rather than applying from the
    -- first frame, so a tag inside one is in force between that moment and whatever writes the field
    -- next. Reading it as always-applied let a later transform hide it, and a divergent value inside
    -- one was then rewritten as freely as an agreed one: libass rounds a fractional `\be` where
    -- VSFilter keeps it, so this may only be converged with libass named.
    normalizeLine_keepsADivergentValueInAnIntervalOfNoWidth: (ut) ->
      line = "{\\t(5554,5554,0.5,\\be7.7)\\t(5762,5762,0.5,\\be7.6)}x"
      ut\assertEquals normalizeLineAndEmit(line), line

    -- The outer transform is left standing where the split empties it. Both renderers switch collision
    -- detection off for a transform whether or not it animates anything, which the descriptor states,
    -- so taking the empty one away parts the line from the one it was rewritten out of.
    normalizeLine_leavesAnEmptiedTransformStanding: (ut) ->
      ut\assertContains normalizeLineAndEmit("{\\t(0,100,\\t(5000,6000,\\fscx200))}MMMM"), "\\t(0,100,)"

    -- Every split is checked like any other rewrite, so a line the targets read differently afterwards
    -- comes back as it went in.
    normalizeLine_splitsOnlyWhereEveryTargetReadsItAlike: (ut) ->
      for written in *{"{\\t(0,100,\\fscy150\\t(5000,6000,\\fscx200))}MMMM", "{\\t(0,100,\\t(0,200,\\bord2))}a"}
        out = normalizeLineAndEmit written
        for dialect in *renderers
          ut\assertTrue isEquivalent written, out, dialect

    -- A tag a transform does not interpolate applies whole from the first frame, interval or no
    -- interval, so it does outside the transform what it did inside. Lifted, it stands before the
    -- transform, which keeps its order against everything written outside.
    normalizeLine_liftsATagATransformDoesNotInterpolate: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\t(0,100,\\fscx200\\b1)}MMMM"), "{\\b1\\t(0,100,\\fscx200)}MMMM"
      ut\assertEquals normalizeLineAndEmit("{\\t(0,100,\\b1\\i1\\fscx200)}MMMM"), "{\\b1\\i1\\t(0,100,\\fscx200)}MMMM"

    -- A tag taking a parenthesized list closes its own once it stands alone, where inside the transform
    -- the single `)` had been closing both at once. The one the transform's list took from it is spent
    -- on that, so the line keeps the count of parentheses it was written with.
    normalizeLine_closesALiftedTagsArgumentList: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\t(0,100,\\fscx200\\pos(10,20))}MMMM"),
        "{\\pos(10,20)\\t(0,100,\\fscx200)}MMMM"
      ut\assertEquals normalizeLineAndEmit("{\\t(0,500,\\fad(0,100))}x"), "{\\fad(0,100)\\t(0,500,)}x"

    -- The inner transform needs a closer of its own once split out, and takes the one the outer list
    -- had been using for both. A tag written with no parentheses at all had none taken, so there is
    -- nothing to spend and it gains a pair outright.
    normalizeLine_takesTheStolenCloserWhenSplittingANestedTransform: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\t(0,500,\\t(100,200,\\fscx50))}x"),
        "{\\t(0,500,)\\t(100,200,\\fscx50)}x"
      ut\assertEquals normalizeLineAndEmit("{\\t(0,500,\\t\\fscx50)}x"), "{\\t(0,500,)\\t(\\fscx50)}x"

      -- every dialect has to read each rewrite as it read the line
      for written in *{"{\\t(0,500,\\t(100,200,\\fscx50))}x", "{\\t(0,100,\\fscx200\\pos(10,20))}MMMM"}
        rewritten = normalizeLineAndEmit written, {targets: renderers}
        ut\assertEquals select(2, rewritten\gsub "%(", ""), select(2, rewritten\gsub "%)", "")
        for dialect in *{DialectName.Aegisub, DialectName.Libass, DialectName.XyVsfilter}
          ut\assertTrue isEquivalent written, rewritten, dialect

    -- A color's canonical spelling drops the parentheses a degenerate one was written with, since
    -- xy-VSFilter reads the digits where they stand inside them and so holds no digit at all for
    -- `\alpha(&HFF&)`. A transform's argument list ends at the first `)`, so a tag nested in one never
    -- got a closer of its own: the one its author wrote stands after the transform as junk, and the
    -- parentheses take it with them.
    normalizeLine_takesTheStolenCloserWithTheParentheses: (ut) ->
      balanced = (written) ->
        rewritten = normalizeLineAndEmit written, {targets: renderers}
        ut\assertEquals select(2, rewritten\gsub "%(", ""), select(2, rewritten\gsub "%)", "")
        rewritten

      ut\assertEquals balanced("{\\t(167,167,\\alpha(00))}x"), "{\\t(167,167,\\alpha&H00&)}x"
      ut\assertEquals balanced("{\\t(0,500,\\alpha(ff))}x"), "{\\t(0,500,\\alpha&HFF&)}x"
      ut\assertEquals balanced("{\\t(0,500,\\1c(FF00FF))}x"), "{\\t(0,500,\\1c&HFF00FF&)}x"

      -- standing on its own the tag owns its parentheses, and there is no stolen closer to find
      ut\assertEquals balanced("{\\alpha(ff)}x"), "{\\alpha&HFF&}x"

      -- every dialect has to read the rewrite as it read the line, which is what lets it stand
      for written in *{"{\\t(167,167,\\alpha(00))}x", "{\\t(0,500,\\alpha(ff))}x", "{\\alpha(ff)}x"}
        rewritten = normalizeLineAndEmit written, {targets: renderers}
        for dialect in *{DialectName.Aegisub, DialectName.Libass, DialectName.XyVsfilter}
          ut\assertTrue isEquivalent written, rewritten, dialect

    -- `\r` resets every field, so lifting it above a tag the transform interpolates would stop it
    -- resetting what that tag wrote. The move is put to the targets like any other and comes back
    -- refused, which is what keeps the rule from having to know about `\r` at all.
    normalizeLine_refusesALiftThatChangesWhatTheLineDraws: (ut) ->
      text = "{\\t(0,100,\\fscx200\\r)}MMMM"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- A refusal is recorded against the tag rather than the pass, so the tags beside it are still
    -- tried. `\an` survives the lift where `\b` would not: a reset puts a style's weight back and
    -- leaves the alignment alone, so lifting the bold above the reset would lose it and lifting the
    -- alignment loses nothing.
    normalizeLine_keepsLiftingPastARefusedTag: (ut) ->
      ut\assertEquals normalizeLineAndEmit("{\\t(0,100,\\fscx200\\r\\an7)}MMMM"), "{\\an7\\t(0,100,\\fscx200\\r)}MMMM"
      ut\assertEquals normalizeLineAndEmit("{\\t(0,100,\\fscx200\\r\\b1)}MMMM"), "{\\t(0,100,\\fscx200\\r\\b1)}MMMM"

    -- The three passes compose on the shape the wild corpus turns up, leaving both transforms holding
    -- only what they interpolate and every other tag where it actually applies.
    normalizeLine_liftsAndSplitsTheShapeTheCorpusHolds: (ut) ->
      text = "{\\an5\\t(0,300,\\fscx65\\t(0,830,\\frx-28\\fad(0,500)\\p1))}m 0 0"
      out = normalizeLineAndEmit text
      ut\assertContains out, "\\fad(0,500)\\t(0,830,"
      for dialect in *renderers
        ut\assertTrue isEquivalent text, out, dialect

    normalizeLine_leavesAFaceValueArgumentInsideATransformAlone: (ut) ->
      text = "{\\k50}a{\\t(0,100,\\bord2)}b"
      ut\assertEquals normalizeLineAndEmit(text), text

    -- the targets disagree about the rewrite whether it sits in a transform or not, so it is reported
    normalizeLine_reportsADivergentQuirkInsideATransform: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\k50}{\\be1}a{\\t(0,100,\\be0.6)}b"
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\t(0,100,\\be0.6)}b"
      ut\assertEquals #divergences, 1

    -- One renderer rounds `\be` and the other keeps the fraction, so writing 0.6 as 1 would change
    -- what the second draws. The rewrite is reported rather than made.
    normalizeLine_reportsATagTheTargetsDisagreeAbout: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\k50}{\\be1}a{\\be0.6}b"
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be0.6}b"
      ut\assertEquals #divergences, 1
      ut\assertEquals divergences[1].tag, "be0.6"
      ut\assertEquals divergences[1].rewritten, "be1"
      ut\assertEquals table.concat(divergences[1].accepting, "+"), DialectName.Libass

    -- asked to satisfy that renderer alone, the same rewrite becomes available
    normalizeLine_appliesARewriteOneTargetAccepts: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\k50}{\\be1}a{\\be0.6}b", targets: {DialectName.Libass}
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be1}b"
      ut\assertEquals #divergences, 0

    -- Named as the reference, the rounding renderer's reading defines the line, and the other target
    -- follows it: it reads the rewritten `\be1` at face value and splits the rewritten line as the
    -- reference does, so the rewrite that strict mode reports is applied and the two converge.
    normalizeLine_convergesOnTheReferenceDialect: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\k50}{\\be1}a{\\be0.6}b", {targets: renderers, referenceDialect: DialectName.Libass}
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be1}b"
      ut\assertEquals #divergences, 0

    -- The keeping renderer as reference reads 0.6 at face value, so the only canonical spelling on
    -- offer is the rounder's, and taking it would change what the reference draws. The line stays
    -- and the disagreement is still reported.
    normalizeLine_keepsAQuirkTheReferenceReadsAtFaceValue: (ut) ->
      rewritten, divergences = normalizeLineAndEmit "{\\k50}{\\be1}a{\\be0.6}b", {targets: renderers, referenceDialect: DialectName.XyVsfilter}
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be0.6}b"
      ut\assertEquals #divergences, 1

    normalizeLine_rejectsAReferenceOutsideTheTargets: (ut) ->
      ut\assertError -> normalizeLineAndEmit "{\\k50}ab",
        {targets: {DialectName.Libass}, referenceDialect: DialectName.XyVsfilter}

    -- Rendered both ways in `observe-declared-default-repair.moon`: a script declaring no `Default` and
    -- a line reaching nothing is drawn by each renderer in the style it keeps for itself, and declaring
    -- the reference's own under that name leaves the reference's picture untouched while bringing the
    -- other onto it. The line itself needs no edit, `Default` being the name both reach for.
    normalizeLine_reportsTheStyleToDeclareForALineReachingNone: (ut) ->
      {:dialects} = require "l0.AssParser.dialects"
      declaringOther = Other: Ass.createStyle name: "Other"

      declare = (referenceDialect) ->
        select 4, normalizeLineAndEmit {text: "{\\b1}x", style: "Missing"},
          {targets: renderers, :referenceDialect, stylesByName: declaringOther}

      ut\assertEquals declare(DialectName.Libass), dialects[DialectName.Libass].fallbackStyle
      ut\assertEquals declare(DialectName.XyVsfilter), dialects[DialectName.XyVsfilter].fallbackStyle
      ut\assertEquals declare(DialectName.Libass).name, "Default"

      -- nothing says whose reading the others should follow without a reference
      ut\assertNil declare nil

    -- A line ending where it starts states no span for a transform that names no interval, so it is
    -- read exactly as a line stating no timings at all is.
    normalizeLine_readsNoSpanFromALineEndingWhereItStarts: (ut) ->
      text = "{\\t(\\fscx200)}x"
      ut\assertEquals normalizeLineAndEmit({:text, start_time: 500, end_time: 500}, {targets: renderers}),
        normalizeLineAndEmit text, {targets: renderers}

    normalizeLine_reportsNoStyleToDeclareWhereTheLineReachesOne: (ut) ->
      declare = (stylesByName, styleName) ->
        select 4, normalizeLineAndEmit {text: "{\\b1}x", style: styleName},
          {targets: renderers, referenceDialect: DialectName.Libass, :stylesByName}

      ut\assertNil declare {Other: Ass.createStyle name: "Other"}, "Other"
      ut\assertNil declare {Default: Ass.createStyle name: "Default"}, "Missing"
      -- a script whose styles were never handed over says nothing about what it declares
      ut\assertNil declare nil, "Missing"
      ut\assertNil declare {Other: Ass.createStyle name: "Other"}, nil

    -- A line handed over whole names its style instead of holding it, so a rewrite is weighed against
    -- whatever that name reaches. Both sides of that comparison have to be read against the same style:
    -- reading the rewrite against one style and the line it came from against another makes the two
    -- part over the style rather than the rewrite, which withholds every rewrite on every line.
    normalizeLine_rewritesALineAgainstTheStyleItsNameReaches: (ut) ->
      style = Ass.createStyle {name: "Sign", bold: true}
      stylesByName = {Sign: style}
      text, want = "{\\3a&b7}x", "{\\3a&HB7&}x"

      ut\assertEquals normalizeLineAndEmit({:text, style: "Sign"}, {targets: renderers, :stylesByName}), want
      ut\assertEquals normalizeLineAndEmit(text, {targets: renderers, :style, :stylesByName}), want

    -- The result is a stream rather than text, so what it was read under decides what its tags mean.
    -- A reference is the dialect whose reading has to survive, so it is the one the stream belongs to.
    normalizeLine_readsTheResultUnderTheReferenceOrTheFirstTarget: (ut) ->
      streamFor = (reference) ->
        (normalizer.normalizeLine "{\\b1}x", {targets: renderers, referenceDialect: reference}).dialect

      ut\assertEquals streamFor(DialectName.XyVsfilter), DialectName.XyVsfilter
      ut\assertEquals streamFor(DialectName.Libass), DialectName.Libass
      ut\assertEquals streamFor(nil), renderers[1]

    -- Handing the scan over saves doing it again, so it has to reach the same result as letting the
    -- normalizer scan for itself, and what the stream holds is what gets rewritten.
    normalizeLine_takesAStreamInsteadOfScanningAgain: (ut) ->
      for written in *{"{\\b1\\c&H00FFFFFF&\\bord2}abc", "{\\bord0x10}x", "{\\fscy-6}x", "plain text"}
        scanned = Scanner(renderers[1])\scan written
        ut\assertEquals emit(normalizer.normalizeLine written, {targets: renderers}),
          emit(normalizer.normalizeLine {text: "ignored"}, {targets: renderers, tokens: scanned})

    -- A stream handed over names the dialect that read it, and that is the reading the result comes
    -- back in. Naming a reference as well states a second one, and the reference is the reading that
    -- has to survive, so the two disagreeing is a contradiction rather than something to pick between.
    normalizeLine_refusesAStreamThatDisagreesWithTheReference: (ut) ->
      written = "{\\b1}x"
      scannedAs = (dialect) -> Scanner(dialect)\scan written

      ok, err = pcall normalizer.normalizeLine, written,
        {targets: renderers, tokens: scannedAs(DialectName.XyVsfilter),
          referenceDialect: DialectName.Libass}
      ut\assertFalse ok
      ut\assertContains tostring(err), DialectName.XyVsfilter

      -- naming the same one twice says nothing new, so it holds
      agreeing = normalizer.normalizeLine written,
        {targets: renderers, tokens: scannedAs(DialectName.Libass),
          referenceDialect: DialectName.Libass}
      ut\assertEquals agreeing.dialect, DialectName.Libass

      -- and with no reference the stream's own dialect is the one it comes back in
      held = normalizer.normalizeLine written,
        {targets: renderers, tokens: scannedAs DialectName.XyVsfilter}
      ut\assertEquals held.dialect, DialectName.XyVsfilter

    -- A block holding no tag draws nothing under any dialect, but only Aegisub gives one a kind of its
    -- own and only where no backslash stands in it, so a comment block reaches a renderer's stream as
    -- junk and reaches every stream in pieces wherever its author broke a line. One comment token per
    -- block is what leaves all three saying the same thing about it.
    normalizeLine_readsEveryDialectsCommentBlockAsOneToken: (ut) ->
      kindsOf = (text) ->
        table.concat [token.kind for token in *normalizer.normalizeLine text, {targets: renderers}], " "

      ut\assertEquals kindsOf("a{a plain remark}b"), "text block-start comment block-end text"
      -- neither dialect's own scan calls this one a comment, the line break putting a backslash in it
      ut\assertEquals kindsOf("a{left: Coma\\Nright: what?}b"), "text block-start comment block-end text"
      -- a block the scan read a tag in keeps its runs, those being junk beside a tag rather than prose
      ut\assertEquals kindsOf("a{a remark\\Nmore\\b1}b"), "text block-start junk junk tag block-end text"

      -- the comment token holds what its runs held, so the line emits as it was written
      for written in *{"a{a plain remark}b", "a{left: Coma\\Nright: what?}b", "a{one}b{two\\Nthree}c"}
        ut\assertEquals emit(normalizer.normalizeLine written, {targets: renderers}), written

    -- A templater's source is not ASS, so reading it as ASS invents tags nobody wrote. It comes back
    -- as the one run of junk it is, which still emits as the text it was given.
    normalizeLine_handsBackATemplateAsJunk: (ut) ->
      written = "{\\pos($center,$middle)\\blur9000}x"
      tokens, original, divergences, changes = normalizer.normalizeLine {text: written, effect: "template syl"},
        {targets: renderers}
      ut\assertEquals #tokens, 1
      ut\assertEquals tokens[1].kind, "junk"
      ut\assertEquals emit(tokens), written
      -- the rest of the call's answer holds its shape here as on any other line: an original that emits
      -- what came in, and a list of changes rather than nothing at all
      ut\assertEquals emit(original), written
      ut\assertEquals #divergences, 0
      ut\assertEquals #changes, 0

    -- the reference invariant, checked across every recorded equivalence: whatever converges, the
    -- reference reads the result exactly as it read the input
    normalizeLine_neverChangesWhatTheReferenceReads: (ut) ->
      offenders = {}
      for row in *equivalences
        for reference in *renderers
          rewritten = normalizeLineAndEmit row.written, {targets: renderers, stylesByName: row.stylesByName, wrapStyle: row.wrapStyle, referenceDialect: reference}
          continue if isEquivalent row.written, rewritten, reference, nil, row.stylesByName, row.wrapStyle
          offenders[#offenders + 1] = "#{row.name}:#{reference}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- The property the design rests on, checked against every recorded equivalence rather than a
    -- chosen line: whatever comes back, both renderers read it as they read the input.
    normalizeLine_neverChangesWhatATargetReads: (ut) ->
      offenders = {}
      for row in *equivalences
        rewritten = normalizeLineAndEmit row.written, {targets: renderers, stylesByName: row.stylesByName, wrapStyle: row.wrapStyle}
        for dialect in *renderers
          continue if isEquivalent row.written, rewritten, dialect, nil, row.stylesByName, row.wrapStyle
          offenders[#offenders + 1] = "#{row.name}:#{dialect}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- Describing a rewrite from the stream kept beside it is what makes a check cheap, and a stream
    -- left out of step with the text describes the line wrongly without failing, so a rewrite gets
    -- accepted or refused on a reading nothing else would catch. Every row is normalized again with
    -- both routes running, which throws where they part. Each reference is named in turn because
    -- converging a value is what moves one far enough for a stale reading to show — a rewrite that only
    -- respells the same value describes the same either way.
    normalizeLine_describesARewriteTheSameFromAKeptStreamAsFromAScan: (ut) ->
      offenders = {}
      for row in *equivalences
        for reference in *{false, renderers[1], renderers[2]}
          ok, thrown = pcall normalizeLineAndEmit, row.written, {targets: renderers,
            stylesByName: row.stylesByName, wrapStyle: row.wrapStyle,
            referenceDialect: reference or nil, verifyDescriptionTrees: true}
          continue if ok
          offenders[#offenders + 1] = "#{row.name} under #{reference or 'no reference'}: #{thrown}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, "\n"), ""
  }

  -- Every equivalence safe for both renderers records the canonical spelling of a quirk, which is
  -- exactly what rectifying writes, so the rewritten line has to come out as the row says.
  for row in *equivalences
    continue unless #row.dialects == #renderers
    tests["normalizeLine_#{row.name}"] = (ut) ->
      ut\assertEquals normalizeLineAndEmit(row.written, {targets: renderers, stylesByName: row.stylesByName, wrapStyle: row.wrapStyle}), row.rewritten

  tests
