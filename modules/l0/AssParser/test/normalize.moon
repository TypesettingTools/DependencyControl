-- cspell:ignore HFFFFFF -- a color literal written out in a fixture, not a word
--
-- Pins the normalizer prototype against the equivalences it is meant to act on. Every row `diagnostics`
-- records as safe for both renderers has to come out rectified into its canonical spelling, every row
-- safe for only one has to come out untouched and reported, and a tag that reads at face value has to
-- come out byte for byte, so the files cannot drift apart without a failure here.
-- Called from test.moon as: (controls\requireTest "normalize")!
--
-- The strongest case is the last: a line is rewritten and the result is put back to the oracle. That
-- checks the property the design rests on — nothing is kept unchecked — rather than any particular
-- rewrite, so it keeps holding as the rules change underneath it.
->
  {:normalizeLine} = require "l0.AssParser.normalize"
  {:equivalences, :isEquivalent} = require "l0.AssParser.diagnostics"
  {:DialectName} = require "l0.AssParser.dialects"
  {:WrapStyle, :defaultStyle} = require "l0.AssParser.ass"

  renderers = {DialectName.Libass, DialectName.XyVsfilter}

  ---The one change a line is expected to have produced.
  ---@param written string The line to normalize.
  ---@param reference? AssDialectName Which dialect to converge the others onto.
  ---@return AssNormalizeChange
  onlyChange = (written, reference) ->
    _, _, changes = normalizeLine written, {targets: renderers, referenceDialect: reference}
    changes[1]

  tests = {
    _description: "Rewrites the tags of a line that do not mean what they say into the spelling of
      what they mean, keeps a face-value tag byte for byte however redundant, and reports the tags
      the target dialects disagree about instead of applying them."

    -- What was rewritten is reported beside the line, keyed to the bytes it was read from, so a caller
    -- can put a change next to the finding that named the same tag. The range covers the backslash the
    -- tag was written with, as a finding's does, while the text itself is spelled without it.
    normalizeLine_reportsWhatItRewrote: (ut) ->
      change = onlyChange "{\\b1\\c&H00FFFFFF&\\bord2}abc"
      ut\assertEquals change.kind, "tag"
      ut\assertEquals change.before, "c&H00FFFFFF&"
      ut\assertEquals change.after, "c&HFFFFFF&"
      ut\assertEquals change.startIndex, 5
      ut\assertEquals change.endIndex, 17
      ut\assertNil change.converged

    -- A line every dialect already reads at face value is reported as changed in nothing, which is what
    -- tells a caller there is nothing to record rather than that recording failed.
    normalizeLine_reportsNoChangeWhereItRewroteNothing: (ut) ->
      for written in *{"{\\bord2}abc", "{\\1c&HFFFFFF&}abc", "plain text"}
        _, _, changes = normalizeLine written, {targets: renderers}
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
        ut\assertEquals normalizeLine(written, {targets: renderers}), want

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
      ut\assertEquals normalizeLine(written, {targets: renderers, style: defaultStyle, stylesByName: styles}), written

      for {reference, want, converged} in *{
          {DialectName.Libass, "{\\rNegative\\bord0}X", DialectName.XyVsfilter}
          {DialectName.XyVsfilter, "{\\rNegative\\bord2}X", DialectName.Libass}
        }
        rewritten, _, changes = normalizeLine written, {targets: renderers, style: defaultStyle, stylesByName: styles, referenceDialect: reference}
        ut\assertEquals rewritten, want
        ut\assertEquals #changes, 1
        ut\assertEquals changes[1].converged[1], converged

    -- Where the targets agree what a bare tag restores, which is every line without a `\r` to another
    -- style, the bare form is the spelling and naming a reference changes nothing.
    normalizeLine_keepsABareTagTheTargetsAgreeOn: (ut) ->
      for reference in *{nil, DialectName.Libass, DialectName.XyVsfilter}
        ut\assertEquals normalizeLine("{\\bord}X", {targets: renderers, style: defaultStyle, referenceDialect: reference}), "{\\bord}X"
        ut\assertEquals normalizeLine("{\\fscx}X", {targets: renderers, style: defaultStyle, referenceDialect: reference}), "{\\fscx}X"

    -- A color literal holding no digit puts the style's own value back for a dialect that refuses one,
    -- exactly as the bare tag does, so there the bare tag is its spelling. libass reads it as a value
    -- instead, so the two part and only a named reference settles which spelling the line takes.
    normalizeLine_writesARefusedColorLiteralAsTheBareTag: (ut) ->
      for {reference, want} in *{
          {DialectName.XyVsfilter, "{\\c}x"}
          {DialectName.Libass, "{\\c&H000000&}x"}
        }
        ut\assertEquals normalizeLine("{\\c&H&}x", {targets: renderers, referenceDialect: reference}), want
      -- neither spelling holds for both, so with no reference the line stands as written
      ut\assertEquals normalizeLine("{\\c&H&}x", {targets: renderers}), "{\\c&H&}x"

    -- Where two targets canonicalize a tag differently there is nothing to prefer one by without a
    -- reference, so the result must not fall out of the order the targets were passed in. A color
    -- literal holding no digit is that case, one target writing the bare tag and the other the value.
    normalizeLine_doesNotDependOnTheOrderOfItsTargets: (ut) ->
      reversed = {DialectName.XyVsfilter, DialectName.Libass}
      for written in *{"{\\c&H&}x", "{\\1a&H&}x", "{\\bord-2}x", "{\\b2}x", "{\\be0.6}x"}
        ut\assertEquals normalizeLine(written, {targets: renderers}),
          normalizeLine written, {targets: reversed}

    -- `\1a&H&` reads as zero for one target and as the style's own alpha for the other, so both the
    -- stated value and the bare tag hold for both only where that alpha is zero. Where it is, the
    -- stated value is written; where it is not, neither spelling holds and the line stands.
    normalizeLine_writesAnEmptyAlphaLiteralOutWhereTheStyleAllowsIt: (ut) ->
      translucent = {key, value for key, value in pairs defaultStyle}
      translucent.color1 = "&H80FFFFFF&"
      ut\assertEquals normalizeLine("{\\1a&H&}x", {targets: renderers, style: defaultStyle}), "{\\1a&H00&}x"
      ut\assertEquals normalizeLine("{\\1a&H&}x", {targets: renderers, style: translucent}), "{\\1a&H&}x"

    -- Whitespace leading a style name is dropped by Aegisub alone, so both renderers miss the style and
    -- draw the line's own. Writing it away would hand them the style the line never got, which is why
    -- this one stays as written while the trailing space beside it goes.
    normalizeLine_keepsWhitespaceLeadingAStyleName: (ut) ->
      styles = {Default: defaultStyle, Bold: {key, value for key, value in pairs defaultStyle}}
      styles.Bold.name = "Bold"
      ut\assertEquals normalizeLine("{\\r Bold}X", {targets: renderers, style: defaultStyle, stylesByName: styles}), "{\\r Bold}X"
      ut\assertEquals normalizeLine("{\\rBold }X", {targets: renderers, style: defaultStyle, stylesByName: styles}), "{\\rBold}X"

    -- A rewrite made to converge a target on the reference names that target, since the picture it
    -- draws changes where every other rewrite leaves every target's picture alone. A renderer check
    -- reads this to know which of its comparisons is expected to differ.
    normalizeLine_marksARewriteThatConvergesATarget: (ut) ->
      change = onlyChange "{\\p1}m 0 0 l 100 0 b 10 10 20 20{\\p0}", DialectName.Libass
      ut\assertEquals change.kind, "drawing"
      ut\assertEquals change.after, "m 0 0 l 100 0"
      ut\assertEquals table.concat(change.converged, ","), DialectName.XyVsfilter

    -- The range is the one the line arrived with, so it still locates the tag after earlier tags in the
    -- same line have been rewritten to a different length.
    normalizeLine_keepsRangesInTheLineAsItArrived: (ut) ->
      written = "{\\alpha&20\\bord2\\c&H00FFFFFF&}abc"
      _, _, changes = normalizeLine written, {targets: renderers}
      ut\assertEquals #changes, 2
      for change in *changes
        ut\assertEquals written\sub(change.startIndex + 1, change.endIndex), change.before

    normalizeLine_leavesAnAlreadyMinimalLineAlone: (ut) ->
      text = "{\\k50}a{\\b1}b"
      ut\assertEquals normalizeLine(text), text

    -- A drawing is rectified by dropping only what every renderer was observed to spend nothing on: a
    -- word holding no number and whatever follows it up to the next command, a spline extension with
    -- too few nodes behind it, and a trailing coordinate too short to make a point.
    normalizeLine_dropsWhatNoRendererSpendsInADrawing: (ut) ->
      ut\assertEquals normalizeLine("{\\p1}m 0 0 l 100 0 l 100 100 junk{\\p0}a"),
        "{\\p1}m 0 0 l 100 0 l 100 100{\\p0}a"
      ut\assertEquals normalizeLine("{\\p1}m 0 0 l 100 0 l 100 100 x 5 5 l 0 100{\\p0}a"),
        "{\\p1}m 0 0 l 100 0 l 100 100 l 0 100{\\p0}a"
      ut\assertEquals normalizeLine("{\\p1}m 0 0 p 300 0 l 100 100{\\p0}a"),
        "{\\p1}m 0 0 l 100 100{\\p0}a"
      ut\assertEquals normalizeLine("{\\p1}m 0 0 l 100 0 l 100 100 l 300{\\p0}a"),
        "{\\p1}m 0 0 l 100 0 l 100 100{\\p0}a"

    -- A drawing that says what it means is kept byte for byte, whatever whitespace it was written with
    normalizeLine_leavesAWellFormedDrawingAlone: (ut) ->
      for text in *{"{\\p1}m 0 0 l 100 0 l 100 100 l 0 100{\\p0}a", "{\\p1}m 0 0   l 100 0  l 100 100{\\p0}a"}
        ut\assertEquals normalizeLine(text), text

    -- A move reaching no point is what lets the open move after it become the root in libass, so
    -- dropping it would turn a drawing that renders there into one no renderer draws.
    normalizeLine_keepsAMoveThatReachesNoPoint: (ut) ->
      ut\assertEquals normalizeLine("{\\p1}m junk n 0 0 l 100 0{\\p0}a"), "{\\p1}m n 0 0 l 100 0{\\p0}a"

    -- Something written against a command letter does not swallow it. Every renderer scans a drawing
    -- character by character and passes over a character naming no command without consuming what
    -- follows, so all four of these open a move at the origin and were drawn doing so in both.
    normalizeLine_readsPastJunkBeforeACommand: (ut) ->
      whole = "{\\p1}m 0 0 l 100 0 m 200 200 l 300 200{\\p0}a"
      for written in *{"}", "}}", "(", "x", "m"}
        ut\assertEquals normalizeLine("{\\p1}#{written}m 0 0 l 100 0 m 200 200 l 300 200{\\p0}a"), whole

    -- Junk standing between a command and its numbers is the other case: it ends the run, and the
    -- numbers behind it reach no command, so the first contour goes and the drawing starts at the next.
    normalizeLine_dropsNumbersJunkCutsOffFromTheirCommand: (ut) ->
      ut\assertEquals normalizeLine("{\\p1}m} 0 0 l 100 0 m 200 200 l 300 200{\\p0}a"),
        "{\\p1}m 200 200 l 300 200{\\p0}a"

    -- A command reaching for nodes it has not got is ignored by every reader wherever it stands, so it
    -- goes wherever it stands too. Four readings of the VSFilter line were each shown drawing such a
    -- drawing exactly as they draw the contour behind it written alone.
    normalizeLine_dropsACommandStandingBeforeTheFirstMove: (ut) ->
      for written in *{"l 100 0", "b 1 2 3 4 5 6", "p 1 2"}
        ut\assertEquals normalizeLine("{\\p1}#{written} m 0 0 l 50 50{\\p0}a"),
          "{\\p1}m 0 0 l 50 50{\\p0}a"

    -- A drawing left open runs the line's own words into it, gluing the last coordinate to the first of
    -- them. Every renderer hands the position to `strtod`, which reads the number and stops at the `W`,
    -- so the coordinate is the drawing's and only the words behind it go.
    normalizeLine_keepsACoordinateWrittenAgainstTheTextBehindIt: (ut) ->
      ut\assertEquals normalizeLine("{\\p1}m 0 0 l 100 0 l 100 100 l 0 100With the blue sky"),
        "{\\p1}m 0 0 l 100 0 l 100 100 l 0 100"

    -- The two malformations the renderers part on have no spelling that means one thing to both, so
    -- they are left exactly as written: points that do not complete a curve, and a drawing that never
    -- reaches a first point and so draws nothing anywhere.
    normalizeLine_leavesADivergentDrawingAlone: (ut) ->
      for text in *{"{\\p1}m 0 0 l 100 0 b 300 100 300 0{\\p0}a", "{\\p1}l 100 0 l 100 100{\\p0}a"}
        ut\assertEquals normalizeLine(text), text

    -- Named a reference, the drawing is written as that dialect reads it, so a divergence is converged
    -- rather than only reported. Orphaned points are what libass drops, and writing them away makes
    -- VSFilter draw what libass already drew.
    normalizeLine_convergesOrphanedPointsOnTheReference: (ut) ->
      text = "{\\p1}m 0 0 l 100 0 b 300 100 300 0{\\p0}a"
      -- libass discards the points, so writing them away is its reading and VSFilter then agrees
      ut\assertEquals normalizeLine(text, {targets: renderers, referenceDialect: DialectName.Libass}),
        "{\\p1}m 0 0 l 100 0{\\p0}a"
      -- VSFilter keeps them in the path, and a contour of no area puts them there for every dialect,
      -- which was matched pixel for pixel against the drawing as written
      ut\assertEquals normalizeLine(text, {targets: renderers, referenceDialect: DialectName.XyVsfilter}),
        "{\\p1}m 0 0 l 100 0 m 300 100 l 300 0 l 300 100{\\p0}a"
      -- named no reference, neither picture may move, so the points stay as written
      ut\assertEquals normalizeLine(text, {targets: renderers}), text

    -- libass opens a drawing at an open move that follows a move reaching no point, where VSFilter
    -- draws nothing at all. Writing that root as an ordinary move is libass's reading spelled so that
    -- VSFilter reaches it too; there is no contour before the first for the two moves to differ over.
    normalizeLine_convergesARootTakenFromAnOpenMove: (ut) ->
      text = "{\\p1}m junk n 0 0 l 100 0 l 100 100{\\p0}a"
      ut\assertEquals normalizeLine(text, {targets: renderers, referenceDialect: DialectName.Libass}),
        "{\\p1}m 0 0 l 100 0 l 100 100{\\p0}a"
      -- with no reference only the unreadable word goes, since the move is what libass opens on
      ut\assertEquals normalizeLine(text, {targets: renderers}), "{\\p1}m n 0 0 l 100 0 l 100 100{\\p0}a"

    -- A drawing the reference draws no part of reads as no drawing at all, so converging on it takes
    -- the drawing out. The `\p` pair is left standing, since removing a tag is cleanup rather than
    -- rectification and belongs to whatever runs after authoring.
    normalizeLine_removesADrawingTheReferenceDrawsNoPartOf: (ut) ->
      -- VSFilter draws nothing where an open move stands in for a move that reached no point
      ut\assertEquals normalizeLine("{\\p1}m junk n 0 0 l 100 0 l 100 100{\\p0}a",
        {targets: renderers, referenceDialect: DialectName.XyVsfilter}), "{\\p1}{\\p0}a"
      -- and neither draws a thing where nothing opens the drawing at all
      ut\assertEquals normalizeLine("{\\p1}l 100 0 l 100 100{\\p0}a",
        {targets: renderers, referenceDialect: DialectName.Libass}), "{\\p1}{\\p0}a"

    -- A drawing ends a karaoke syllable whether or not it draws anything, observed in both renderers:
    -- a degenerate `{\p1}m 0 0{\p0}` splits a line in two where an empty `{\p1}{\p0}` splits nothing.
    -- Taking the drawing out would move the timing of every syllable after it, so where the line names
    -- a karaoke tag the drawing stays and the divergence is reported instead.
    normalizeLine_keepsADrawingWhoseSyllableCarriesTiming: (ut) ->
      for reference in *{DialectName.Libass, DialectName.XyVsfilter}
        for text in *{"{\\k50}b{\\p1}m junk n 0 0 l 100 0{\\p0}a", "{\\k50}b{\\p1}l 100 0 l 100 100{\\p0}a"}
          rewritten = normalizeLine text, {targets: renderers, referenceDialect: reference}
          ut\assertContains rewritten, "{\\p1}"
          ut\assertFalse rewritten == "{\\k50}b{\\p1}{\\p0}a"

    normalizeLine_leavesALineWithoutTagsAlone: (ut) ->
      ut\assertEquals normalizeLine("plain text"), "plain text"

    -- A redundant tag is not a quirky one: it means exactly what it says, and its explicit value or
    -- its layout may be what a later transformation keys on. Rectifying keeps it byte for byte.
    normalizeLine_leavesAFaceValueArgumentAlone: (ut) ->
      text = "{\\k50}a{\\fs48}b"
      ut\assertEquals normalizeLine(text), text

    normalizeLine_neverMergesRedundantTags: (ut) ->
      text = "{\\fscx50\\fscx80}ab"
      ut\assertEquals normalizeLine(text), text

    -- 700 is an accepted weight in both renderers, whatever units each holds it in afterwards
    normalizeLine_leavesAnExplicitWeightAlone: (ut) ->
      text = "{\\k50}a{\\b700}b"
      ut\assertEquals normalizeLine(text), text

    normalizeLine_writesARefusedArgumentAsABareTag: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\b2}b"), "{\\k50}a{\\b}b"

    normalizeLine_writesANegativeArgumentAsZero: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\bord-2}b"), "{\\k50}a{\\bord0}b"

    normalizeLine_writesAFractionalFlagAsAWholeNumber: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\u1.5}b"), "{\\k50}a{\\u1}b"

    -- Every implementation reads a bare run of hex digits and writes the `&H…&` a style is written
    -- with, so the notation is a spelling question with one canonical answer.
    normalizeLine_writesABareColorInTheStyleNotation: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\1cFF0000}b"), "{\\k50}a{\\1c&HFF0000&}b"

    normalizeLine_writesAColorInUpperCase: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\1c&Hff0000&}b"), "{\\k50}a{\\1c&HFF0000&}b"

    -- a transparency is two digits where a color is six, which is why they are separate argument types
    normalizeLine_writesAnAlphaInItsOwnNotation: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\alpha80}b"), "{\\k50}a{\\alpha&H80&}b"
      ut\assertEquals normalizeLine("{\\k50}a{\\3a80}b"), "{\\k50}a{\\3a&H80&}b"

    normalizeLine_leavesACanonicalColorAlone: (ut) ->
      text = "{\\k50}a{\\1c&HFF0000&}b"
      ut\assertEquals normalizeLine(text), text

    -- karaoke arguments are durations rather than appearances, so however they are spelled the
    -- normalizer leaves them alone
    normalizeLine_neverRewritesAKaraokeArgument: (ut) ->
      text = "{\\k50.9}a{\\kf0}b"
      ut\assertEquals normalizeLine(text), text

    -- the tag both renderers refuse to clamp, which reads like the one they do
    normalizeLine_keepsANegativeTheRenderersHold: (ut) ->
      text = "{\\k50}a{\\xshad-2}b"
      ut\assertEquals normalizeLine(text), text

    -- Both renderers put the script's wrap style back for an argument outside the declared four, as
    -- a bare `\q` does. The script has to state the no-wrap style, or restoring and keeping the 9
    -- read alike and the rewrite is accepted without saying anything.
    normalizeLine_writesAnOutOfRangeWrapStyleAsABareTag: (ut) ->
      rewritten, divergences = normalizeLine "{\\q9}{\\k50}aa\\nbb", {targets: renderers, wrapStyle: WrapStyle.NoWordWrap}
      ut\assertEquals rewritten, "{\\q}{\\k50}aa\\nbb"
      ut\assertEquals #divergences, 0

    -- an argument holding no number converts to zero rather than restoring, so zero is its spelling
    normalizeLine_writesAJunkWrapStyleAsZero: (ut) ->
      rewritten, divergences = normalizeLine "{\\qabc}{\\k50}aa\\nbb", {targets: renderers, wrapStyle: WrapStyle.NoWordWrap}
      ut\assertEquals rewritten, "{\\q0}{\\k50}aa\\nbb"
      ut\assertEquals #divergences, 0

    normalizeLine_leavesADeclaredWrapStyleAlone: (ut) ->
      text = "{\\q2}{\\k50}aa\\nbb"
      ut\assertEquals normalizeLine(text, {targets: renderers, wrapStyle: WrapStyle.NoWordWrap}), text

    -- A rewrite reaches a tag through the transform's own token stream, and the transform's argument
    -- text is written back from it. Spelled here with a rewrite that changes no value, since one that
    -- does cannot be made inside a window at all.
    normalizeLine_rectifiesAQuirkInsideATransform: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\t(0,100,\\1c&ffffff&)}b"),
        "{\\k50}a{\\t(0,100,\\1c&HFFFFFF&)}b"

    -- The quirk is rectified through both transforms, and the pair is then written side by side, which
    -- is how the renderers read it. The `)` left over was junk in the line as it arrived and stays so.
    normalizeLine_rectifiesAQuirkInsideANestedTransform: (ut) ->
      ut\assertEquals normalizeLine("{\\k50}a{\\t(0,200,\\t(0,100,\\1c&ffffff&))}b"),
        "{\\k50}a{\\t(0,200,)\\t(0,100,\\1c&HFFFFFF&))}b"

    -- A color literal wearing a prefix with no digits behind it is black to libass and the style's own
    -- to xy-VSFilter, drawn against a style holding neither and alike at block level and inside a
    -- window. No spelling means the same to both, so it stands unless libass is named, and naming it
    -- makes the rewrite one that moves VSFilter's picture on purpose.
    normalizeLine_keepsAColorLiteralTheRenderersReadApart: (ut) ->
      for written in *{"{\\c&&}x", "{\\t(0,1000,\\c&&)}x"}
        ut\assertEquals normalizeLine(written, {targets: renderers}), written

      ut\assertEquals normalizeLine("{\\c&&}x", {targets: renderers, referenceDialect: DialectName.Libass}),
        "{\\c&H000000&}x"
      change = onlyChange "{\\c&&}x", DialectName.Libass
      ut\assertEquals table.concat(change.converged, ","), DialectName.XyVsfilter

    -- digits behind the prefix are read by both, so that one canonicalizes as any other literal does
    normalizeLine_writesALiteralWhoseDigitsBothRead: (ut) ->
      ut\assertEquals normalizeLine("{\\3c&660066&}x", {targets: renderers}), "{\\3c&H660066&}x"

    -- A value the renderers refuse acts as the bare tag where it is written outright, and animates
    -- toward the number itself inside a window: both interpolate what was written and read the result,
    -- so `\bord-2` reaches the floor sooner than `\bord0` does and the two draw differently the whole
    -- way there. Rendered in both, which is what says the rewrite may not be made here.
    normalizeLine_keepsARefusedValueInsideATransform: (ut) ->
      for written in *{"\\t(0,100,\\bord-2)", "\\t(0,2000,\\fs0)", "\\t(0,2000,\\fscx0)"}
        text = "{\\fs40#{written}}b"
        ut\assertEquals normalizeLine(text), text

      -- written outright it is still the bare tag, which is the case the equivalence was read from
      ut\assertEquals normalizeLine("{\\fs40\\fs0}b"), "{\\fs40\\fs}b"

    -- A transform holding another replaces the window it sits in for everything after it, which both
    -- renderers were observed doing, so the two draw what a pair written side by side draws. Writing
    -- them that way is what stops the nesting reading as one animation driving another.
    normalizeLine_splitsATransformHoldingAnother: (ut) ->
      ut\assertEquals normalizeLine("{\\t(0,100,\\fscy150\\t(5000,6000,\\fscx200))}MMMM"),
        "{\\t(0,100,\\fscy150)\\t(5000,6000,\\fscx200))}MMMM"

    -- Splitting one pair can leave another, so the pass repeats until the line holds none.
    -- The pair rule applied twice, so all three end up side by side. Asserted on the text rather than
    -- on how many changes it took, which counts the repairs the same line needs as well as the splits.
    normalizeLine_splitsATransformHoldingTwoMore: (ut) ->
      rewritten = normalizeLine "{\\t(0,100,\\t(200,300,\\t(5000,6000,\\fscx200)))}MMMM"
      ut\assertContains rewritten, "\\t(0,100,)"
      ut\assertContains rewritten, "\\t(200,300,)"
      ut\assertContains rewritten, "\\t(5000,6000,\\fscx200)"

    -- Both renderers read `\fad` and `\fade` as one tag whose shape is picked by how many arguments it
    -- was given, the name being ignored, so the name that states the count is the spelling of what the
    -- tag does. Each of these was drawn in both renderers beside the renamed line and matched it.
    normalizeLine_namesAFadeForItsArgumentCount: (ut) ->
      ut\assertEquals normalizeLine("{\\fade(0,200)}x"), "{\\fad(0,200)}x"
      ut\assertEquals normalizeLine("{\\fad(255,0,255,0,1,2,3)}x"), "{\\fade(255,0,255,0,1,2,3)}x"

    -- a count neither shape takes fades under neither name, so there is no spelling to move it to
    normalizeLine_leavesAFadeNoShapeTakesAlone: (ut) ->
      ut\assertEquals normalizeLine("{\\fad(0,200,400)}x"), "{\\fad(0,200,400)}x"

    -- an argument list runs to the end of its block whether or not it closes, so closing it says what
    -- both renderers already read
    normalizeLine_closesAnArgumentListLeftOpen: (ut) ->
      ut\assertEquals normalizeLine("{\\fad(0,750}x"), "{\\fad(0,750)}x"

    -- A backslash naming no tag is read past by every dialect. It cannot be a marker an automation
    -- script keys on either, being ASS syntax already.
    normalizeLine_takesOutABackslashNamingNoTag: (ut) ->
      ut\assertEquals normalizeLine("{\\fs40\\\\blur0.6}x"), "{\\fs40\\blur0.6}x"
      ut\assertEquals normalizeLine("{\\fs40\\\\\\blur0.6}x"), "{\\fs40\\blur0.6}x"

    -- A tag declaring no bare form reads as nothing when written with no arguments, so it draws like a
    -- backslash naming no tag and goes the same way. Its braces go with it where it stood alone in the
    -- block, since an emptied `{}` would only be a second finding in place of the first.
    normalizeLine_takesOutABareTagWithNoBareForm: (ut) ->
      ut\assertEquals normalizeLine("{\\pos}ab"), "ab"
      ut\assertEquals normalizeLine("{\\clip}ab"), "ab"
      ut\assertEquals normalizeLine("{\\move}{\\org}{\\fad}ab"), "ab"
      -- whitespace and empty parentheses read as the bare form too
      ut\assertEquals normalizeLine("{\\pos   }ab"), "ab"
      ut\assertEquals normalizeLine("{\\pos()}ab"), "ab"
      -- the braces stay where another tag still stands in them
      ut\assertEquals normalizeLine("{\\b1\\pos}ab"), "{\\b1}ab"

    -- Arguments matching no signature read as nothing just as a bare tag does, but which of them were
    -- meant cannot be recovered, so the line keeps them and the finding names them instead.
    normalizeLine_keepsATagWhoseArgumentsMatchNoSignature: (ut) ->
      for text in *{"{\\pos(1,2,3)}ab", "{\\pos(1)}ab", "{\\pos1,2}ab", "{\\fad(1,2,3)}ab"}
        ut\assertEquals normalizeLine(text), text

    -- A transform whose interval has no width steps at the moment it names rather than applying from the
    -- first frame, so a tag inside one is in force between that moment and whatever writes the field
    -- next. Reading it as always-applied let a later transform hide it, and a divergent value inside
    -- one was then rewritten as freely as an agreed one: libass rounds a fractional `\be` where
    -- VSFilter keeps it, so this may only be converged with libass named.
    normalizeLine_keepsADivergentValueInAnIntervalOfNoWidth: (ut) ->
      line = "{\\t(5554,5554,0.5,\\be7.7)\\t(5762,5762,0.5,\\be7.6)}x"
      ut\assertEquals normalizeLine(line), line

    -- The outer transform is left standing where the split empties it. Both renderers switch collision
    -- detection off for a transform whether or not it animates anything, which the descriptor states,
    -- so taking the empty one away parts the line from the one it was rewritten out of.
    normalizeLine_leavesAnEmptiedTransformStanding: (ut) ->
      ut\assertContains normalizeLine("{\\t(0,100,\\t(5000,6000,\\fscx200))}MMMM"), "\\t(0,100,)"

    -- Every split is checked like any other rewrite, so a line the targets read differently afterwards
    -- comes back as it went in.
    normalizeLine_splitsOnlyWhereEveryTargetReadsItAlike: (ut) ->
      for written in *{"{\\t(0,100,\\fscy150\\t(5000,6000,\\fscx200))}MMMM", "{\\t(0,100,\\t(0,200,\\bord2))}a"}
        out = normalizeLine written
        for dialect in *renderers
          ut\assertTrue isEquivalent dialect, written, out

    -- A tag a transform does not interpolate applies whole from the first frame, interval or no
    -- interval, so it does outside the transform what it did inside. Lifted, it stands before the
    -- transform, which keeps its order against everything written outside.
    normalizeLine_liftsATagATransformDoesNotInterpolate: (ut) ->
      ut\assertEquals normalizeLine("{\\t(0,100,\\fscx200\\b1)}MMMM"), "{\\b1\\t(0,100,\\fscx200)}MMMM"
      ut\assertEquals normalizeLine("{\\t(0,100,\\b1\\i1\\fscx200)}MMMM"), "{\\b1\\i1\\t(0,100,\\fscx200)}MMMM"

    -- A tag taking a parenthesized list closes its own once it stands alone, where inside the transform
    -- the single `)` had been closing both at once.
    normalizeLine_closesALiftedTagsArgumentList: (ut) ->
      ut\assertEquals normalizeLine("{\\t(0,100,\\fscx200\\pos(10,20))}MMMM"),
        "{\\pos(10,20)\\t(0,100,\\fscx200))}MMMM"

    -- `\r` resets every field, so lifting it above a tag the transform interpolates would stop it
    -- resetting what that tag wrote. The move is put to the targets like any other and comes back
    -- refused, which is what keeps the rule from having to know about `\r` at all.
    normalizeLine_refusesALiftThatChangesWhatTheLineDraws: (ut) ->
      text = "{\\t(0,100,\\fscx200\\r)}MMMM"
      ut\assertEquals normalizeLine(text), text

    -- A refusal is recorded against the tag rather than the pass, so the tags beside it are still
    -- tried. `\an` survives the lift where `\b` would not: a reset puts a style's weight back and
    -- leaves the alignment alone, so lifting the bold above the reset would lose it and lifting the
    -- alignment loses nothing.
    normalizeLine_keepsLiftingPastARefusedTag: (ut) ->
      ut\assertEquals normalizeLine("{\\t(0,100,\\fscx200\\r\\an7)}MMMM"), "{\\an7\\t(0,100,\\fscx200\\r)}MMMM"
      ut\assertEquals normalizeLine("{\\t(0,100,\\fscx200\\r\\b1)}MMMM"), "{\\t(0,100,\\fscx200\\r\\b1)}MMMM"

    -- The three passes compose on the shape the wild corpus turns up, leaving both transforms holding
    -- only what they interpolate and every other tag where it actually applies.
    normalizeLine_liftsAndSplitsTheShapeTheCorpusHolds: (ut) ->
      text = "{\\an5\\t(0,300,\\fscx65\\t(0,830,\\frx-28\\fad(0,500)\\p1))}m 0 0"
      out = normalizeLine text
      ut\assertContains out, "\\fad(0,500)\\t(0,830,"
      for dialect in *renderers
        ut\assertTrue isEquivalent dialect, text, out

    normalizeLine_leavesAFaceValueArgumentInsideATransformAlone: (ut) ->
      text = "{\\k50}a{\\t(0,100,\\bord2)}b"
      ut\assertEquals normalizeLine(text), text

    -- the targets disagree about the rewrite whether it sits in a transform or not, so it is reported
    normalizeLine_reportsADivergentQuirkInsideATransform: (ut) ->
      rewritten, divergences = normalizeLine "{\\k50}{\\be1}a{\\t(0,100,\\be0.6)}b"
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\t(0,100,\\be0.6)}b"
      ut\assertEquals #divergences, 1

    -- One renderer rounds `\be` and the other keeps the fraction, so writing 0.6 as 1 would change
    -- what the second draws. The rewrite is reported rather than made.
    normalizeLine_reportsATagTheTargetsDisagreeAbout: (ut) ->
      rewritten, divergences = normalizeLine "{\\k50}{\\be1}a{\\be0.6}b"
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be0.6}b"
      ut\assertEquals #divergences, 1
      ut\assertEquals divergences[1].tag, "be0.6"
      ut\assertEquals divergences[1].rewritten, "be1"
      ut\assertEquals table.concat(divergences[1].accepting, "+"), DialectName.Libass

    -- asked to satisfy that renderer alone, the same rewrite becomes available
    normalizeLine_appliesARewriteOneTargetAccepts: (ut) ->
      rewritten, divergences = normalizeLine "{\\k50}{\\be1}a{\\be0.6}b", targets: {DialectName.Libass}
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be1}b"
      ut\assertEquals #divergences, 0

    -- Named as the reference, the rounding renderer's reading defines the line, and the other target
    -- follows it: it reads the rewritten `\be1` at face value and splits the rewritten line as the
    -- reference does, so the rewrite that strict mode reports is applied and the two converge.
    normalizeLine_convergesOnTheReferenceDialect: (ut) ->
      rewritten, divergences = normalizeLine "{\\k50}{\\be1}a{\\be0.6}b", {targets: renderers, referenceDialect: DialectName.Libass}
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be1}b"
      ut\assertEquals #divergences, 0

    -- The keeping renderer as reference reads 0.6 at face value, so the only canonical spelling on
    -- offer is the rounder's, and taking it would change what the reference draws. The line stays
    -- and the disagreement is still reported.
    normalizeLine_keepsAQuirkTheReferenceReadsAtFaceValue: (ut) ->
      rewritten, divergences = normalizeLine "{\\k50}{\\be1}a{\\be0.6}b", {targets: renderers, referenceDialect: DialectName.XyVsfilter}
      ut\assertEquals rewritten, "{\\k50}{\\be1}a{\\be0.6}b"
      ut\assertEquals #divergences, 1

    normalizeLine_rejectsAReferenceOutsideTheTargets: (ut) ->
      ut\assertError -> normalizeLine "{\\k50}ab",
        {targets: {DialectName.Libass}, referenceDialect: DialectName.XyVsfilter}

    -- the reference invariant, checked across every recorded equivalence: whatever converges, the
    -- reference reads the result exactly as it read the input
    normalizeLine_neverChangesWhatTheReferenceReads: (ut) ->
      offenders = {}
      for row in *equivalences
        for reference in *renderers
          rewritten = normalizeLine row.written, {targets: renderers, stylesByName: row.stylesByName, wrapStyle: row.wrapStyle, referenceDialect: reference}
          continue if isEquivalent reference, row.written, rewritten, nil, row.stylesByName, row.wrapStyle
          offenders[#offenders + 1] = "#{row.name}:#{reference}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""

    -- The property the design rests on, checked against every recorded equivalence rather than a
    -- chosen line: whatever comes back, both renderers read it as they read the input.
    normalizeLine_neverChangesWhatATargetReads: (ut) ->
      offenders = {}
      for row in *equivalences
        rewritten = normalizeLine row.written, {targets: renderers, stylesByName: row.stylesByName, wrapStyle: row.wrapStyle}
        for dialect in *renderers
          continue if isEquivalent dialect, row.written, rewritten, nil, row.stylesByName, row.wrapStyle
          offenders[#offenders + 1] = "#{row.name}:#{dialect}"
      table.sort offenders
      ut\assertEquals table.concat(offenders, " "), ""
  }

  -- Every equivalence safe for both renderers records the canonical spelling of a quirk, which is
  -- exactly what rectifying writes, so the rewritten line has to come out as the row says.
  for row in *equivalences
    continue unless #row.dialects == #renderers
    tests["normalizeLine_#{row.name}"] = (ut) ->
      ut\assertEquals normalizeLine(row.written, {targets: renderers, stylesByName: row.stylesByName, wrapStyle: row.wrapStyle}), row.rewritten

  tests
