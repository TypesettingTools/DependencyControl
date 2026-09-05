-- Pins the line and style shapes Aegisub's automation API hands over, and the color notation a style
-- and the color tags share. The notation has three shapes holding different things — a style names a
-- color and its alpha in one value, the tags name them apart — so the pair is asserted in both
-- directions and against the defaults, which are themselves written through the emitter.
-- Called from test.moon as: (controls\requireTest "ass")!
->
  Ass = require "l0.AssParser.ass"
  {:BorderStyle, :ColorNotation, :FieldTyping, :LineClass, :createStyle, :defaultStyle,
  :emitColor, :packStyleColor, :parseColor, :splitStyleColor, :validateLine,
  :DEFAULT_WRAP_STYLE, :getWrapStyle, :WrapStyle} = Ass

  ---Creates a Script Info line, as Aegisub reports the header.
  ---@param key string
  ---@param value string
  ---@return AegisubInfoLine
  makeInfoLine = (key, value) -> {class: LineClass.Info, :key, :value}

  {
    _description: "The subtitle line shapes, the style checks Aegisub applies before it will take one
      back, and the color notation a style and the color tags share."

    parseColor_readsTheStyleNotation: (ut) ->
      ut\assertEquals parseColor("&H00FFFFFF&"), 0x00FFFFFF

    parseColor_readsBareHexDigits: (ut) ->
      ut\assertEquals parseColor("FF0000"), 0xFF0000

    parseColor_readsEitherCase: (ut) ->
      ut\assertEquals parseColor("&Hff0000&"), parseColor "&HFF0000&"

    parseColor_toleratesAMissingCloser: (ut) ->
      ut\assertEquals parseColor("&HFF0000"), 0xFF0000

    -- what every implementation converts unreadable text to, rather than refusing it
    parseColor_readsTextHoldingNoDigitsAsZero: (ut) ->
      ut\assertEquals parseColor("nonsense"), 0

    -- Each expectation below is what both renderers were observed to draw, the literal having been
    -- rendered beside candidate readings of it and matched on the picture. The prefix is a run of `&`
    -- and uppercase `H`, however many of each and in whatever order, and what stands behind it goes to
    -- C's `strtoll` at base 16.
    parseColor_readsPastAPrefixMissingACharacter: (ut) ->
      ut\assertEquals parseColor("&20"), 0x20
      ut\assertEquals parseColor("HFF"), 0xFF

    parseColor_readsPastADoubledPrefix: (ut) ->
      ut\assertEquals parseColor("&&HH00FF00&"), 0x00FF00

    -- the skip is case-sensitive, so the h stands where a digit may not and nothing is converted
    parseColor_readsALowercasePrefixAsZero: (ut) ->
      ut\assertEquals parseColor("&hFF0000&"), 0
      ut\assertEquals parseColor("&h80&"), 0

    parseColor_honorsAZeroXPrefix: (ut) ->
      ut\assertEquals parseColor("&H0x40&"), 0x40

    emitColor_writesTheStyleNotationByDefault: (ut) ->
      ut\assertEquals emitColor(0x00FFFFFF), "&H00FFFFFF&"

    -- a color tag takes six digits and an alpha tag two, so the shape is not cosmetic
    emitColor_writesEachNotationToItsOwnWidth: (ut) ->
      ut\assertEquals emitColor(0xFF0000, ColorNotation.Color), "&HFF0000&"
      ut\assertEquals emitColor(0x80, ColorNotation.Alpha), "&H80&"

    emitColor_padsRatherThanTruncates: (ut) ->
      ut\assertEquals emitColor(0x00FFFFFF, ColorNotation.Alpha), emitColor 0x00FFFFFF, ColorNotation.Color

    emitColor_roundTripsThroughParseColor: (ut) ->
      for value in *{0, 0x80, 0xFF0000, 0x00FFFFFF, 0xFFFFFFFF}
        ut\assertEquals parseColor(emitColor value), value

    -- a style names both in one value where the tags write them apart, which is the whole reason the
    -- comparison holds them separately
    splitStyleColor_takesTheAlphaOffTheTopByte: (ut) ->
      color, alpha = splitStyleColor 0x80FF0000
      ut\assertEquals color, 0xFF0000
      ut\assertEquals alpha, 0x80

    packStyleColor_putsThemBack: (ut) ->
      ut\assertEquals packStyleColor(0xFF0000, 0x80), 0x80FF0000

    packStyleColor_defaultsToFullyOpaque: (ut) ->
      ut\assertEquals packStyleColor(0xFF0000), 0x00FF0000

    -- the defaults are written through the emitter, so this is what stops the two drifting apart
    defaultStyle_colorsRoundTripThroughTheNotation: (ut) ->
      for index = 1, 4
        text = defaultStyle["color#{index}"]
        ut\assertEquals emitColor(parseColor text), text

    defaultStyle_matchesWhatAegisubReports: (ut) ->
      ut\assertEquals defaultStyle.color1, "&H00FFFFFF&"
      ut\assertEquals defaultStyle.color2, "&H000000FF&"
      ut\assertEquals defaultStyle.borderstyle, BorderStyle.Outline

    createStyle_sharesNothingWithTheDefaults: (ut) ->
      style = createStyle!
      style.fontname = "Comic Sans MS"
      ut\assertEquals defaultStyle.fontname, "Arial"

    getWrapStyle_takesTheStatedValue: (ut) ->
      ut\assertEquals getWrapStyle({makeInfoLine "WrapStyle", "2"}), WrapStyle.NoWordWrap

    getWrapStyle_defaultsWhereTheScriptStatesNone: (ut) ->
      ut\assertEquals getWrapStyle({makeInfoLine "Title", "something else"}), DEFAULT_WRAP_STYLE
      ut\assertEquals getWrapStyle({}), DEFAULT_WRAP_STYLE

    -- Neither renderer range-checks the header, unlike the `\q` tag, so the value reaches the line as
    -- written. It is the whole of where the two part on a soft break, so clamping it here would hide a
    -- divergence rather than resolve one.
    getWrapStyle_keepsAValueOutsideTheDeclaredRange: (ut) ->
      ut\assertEquals getWrapStyle({makeInfoLine "WrapStyle", "9"}), 9
      ut\assertEquals getWrapStyle({makeInfoLine "WrapStyle", "-1"}), -1

    getWrapStyle_lastStatementWins: (ut) ->
      lines = {makeInfoLine("WrapStyle", "1"), makeInfoLine "WrapStyle", "3"}
      ut\assertEquals getWrapStyle(lines), WrapStyle.SmartBottomWider

    getWrapStyle_ignoresALineOfAnotherClass: (ut) ->
      lines = {{class: LineClass.Dialogue, key: "WrapStyle", value: "2"}}
      ut\assertEquals getWrapStyle(lines), DEFAULT_WRAP_STYLE

    createStyle_takesTheOverridesGiven: (ut) ->
      ut\assertEquals createStyle(fontsize: 72).fontsize, 72

    validateLine_acceptsAStyleItBuilt: (ut) ->
      ut\assertTrue validateLine createStyle!
      ut\assertTrue validateLine createStyle!, LineClass.Style

    validateLine_rejectsALineOfAnotherClass: (ut) ->
      valid, err = validateLine createStyle!, LineClass.Dialogue
      ut\assertNil valid
      ut\assertMatches err, "Expected a 'dialogue' line, got a 'style' one"

    -- a class is only asked about where one is named, so an unasked line passes on its own fields
    validateLine_acceptsAnyDeclaredClassWhereNoneIsNamed: (ut) ->
      ut\assertTrue validateLine {class: LineClass.Info, key: "WrapStyle", value: "2"}

    validateLine_rejectsAnUndeclaredClass: (ut) ->
      valid, err = validateLine {class: "comment"}
      ut\assertNil valid
      ut\assertMatches err, "'comment' is not a subtitle line class"

    validateLine_rejectsAFieldOfTheWrongType: (ut) ->
      valid, err, faults = validateLine createStyle bold: 1
      ut\assertNil valid
      ut\assertMatches err, "'bold' %(expected boolean%)"
      ut\assertEquals #faults, 1
      ut\assertEquals faults[1].field, "bold"
      ut\assertEquals faults[1].kind, "boolean"

    -- every field at fault is reported, so a style built by hand is repaired in one pass rather than
    -- one failure at a time
    validateLine_reportsEveryFieldAtFault: (ut) ->
      partial = createStyle!
      partial.fontname, partial.margin_r = nil, nil
      valid, err, faults = validateLine partial
      ut\assertNil valid
      ut\assertEquals #faults, 2
      ut\assertEquals faults[1].field, "fontname"
      ut\assertEquals faults[2].field, "margin_r"
      ut\assertMatches err, "'fontname' %(expected string%), 'margin_r' %(expected number%)"

    -- Aegisub reads every field through a check that coerces, which is what the shims stand in for.
    -- The shapes declared here promise the real type, so a value needing coercion is refused by default.
    validateLine_holdsAValueToItsDeclaredTypeUnlessAskedOtherwise: (ut) ->
      numericName = createStyle fontname: 42
      ut\assertNil validateLine numericName
      ut\assertTrue validateLine numericName, nil, FieldTyping.Coerced

      numericStringSize = createStyle fontsize: "48"
      ut\assertNil validateLine numericStringSize
      ut\assertTrue validateLine numericStringSize, nil, FieldTyping.Coerced

      -- a boolean is held to its type either way, zero being truthy in Lua
      ut\assertNil validateLine createStyle(bold: 0), nil, FieldTyping.Coerced

    -- Aegisub reads whatever integer the file held and writes it back, so a value the format gives no
    -- meaning to still has to pass. `BorderStyle\validate` is what asks the stricter question.
    validateLine_acceptsABorderStyleTheFormatDoesNotDefine: (ut) ->
      ut\assertTrue validateLine createStyle borderstyle: 2
      ut\assertNil (BorderStyle\validate 2)

    -- Both renderers were rendered against every keypad alignment for each source. The two sources
    -- agree everywhere SSA defines a number, and part on the two it does not: written as a style's
    -- `Alignment` those draw bottom-right and middle-right, written as `\a` they both draw top-left.
    getKeypadAlignment_readsTheTwoSourcesApartOnWhatSsaLeavesUndefined: (ut) ->
      {:StyleField, :OverrideTag} = Ass.AlignmentSource
      forSource = (source) -> [Ass.getKeypadAlignment value, source for value = 1, 11]
      ut\assertItemsEqual forSource(StyleField), {1, 2, 3, 6, 7, 8, 9, 3, 4, 5, 6}
      ut\assertItemsEqual forSource(OverrideTag), {1, 2, 3, 7, 7, 8, 9, 7, 4, 5, 6}

    -- `\a` puts the style's own alignment back for a number outside the range, and a style field
    -- holding one is drawn differently by each renderer, so neither source reports a reading.
    getKeypadAlignment_reportsNothingOutsideTheNumbering: (ut) ->
      for source in *{Ass.AlignmentSource.StyleField, Ass.AlignmentSource.OverrideTag}
        ut\assertNil Ass.getKeypadAlignment value, source for value in *{0, 12, 99}
      ut\assertError -> Ass.getKeypadAlignment 1, 99

    -- Each row was rendered in both renderers, a tall style beside a short one, and read off which size
    -- the ink came out. The two agreed everywhere: `observe-style-name-matching.moon` holds the probe.
    resolveStyle_reachesTheStyleEachRendererDraws: (ut) ->
      stylesByName =
        "*Target": createStyle name: "*Target", fontsize: 80
        Default: createStyle name: "Default", fontsize: 20
      sizeOf = (named) -> select(1, Ass.resolveStyle stylesByName, named).fontsize

      -- the declaration spells the star and the reference need not, and neither is counted
      ut\assertEquals sizeOf("Target"), 80
      ut\assertEquals sizeOf("*Target"), 80
      ut\assertEquals sizeOf("**Target"), 80
      -- the field split eats what stands before the name, and nothing eats what stands after it
      ut\assertEquals sizeOf(" Target"), 80
      ut\assertEquals sizeOf("Target "), 20
      -- the comparison is exact otherwise, so another case reaches nothing and falls to Default
      ut\assertEquals sizeOf("target"), 20
      ut\assertEquals sizeOf("TARGET"), 20
      ut\assertEquals sizeOf("Missing"), 20

    -- Rendered against a script declaring a tall `default` beside a short `Default`, and again against
    -- one declaring the lowercase spelling alone. Every spelling a line asks in reaches the capitalized
    -- declaration, and where only the lowercase one is declared nothing reaches it at all.
    resolveStyle_foldsEverySpellingOfDefaultOntoTheOneCapitalization: (ut) ->
      both =
        default: createStyle name: "default", fontsize: 80
        Default: createStyle name: "Default", fontsize: 20
      for asked in *{"default", "Default", "DEFAULT", "*Default"}
        style, declaredName, reached = Ass.resolveStyle both, asked
        ut\assertEquals style.fontsize, 20
        ut\assertEquals declaredName, "Default"
        ut\assertTrue reached

      -- the folding is the asking side's alone, so a declaration spelled any other way is out of reach
      lowercase = default: createStyle name: "default", fontsize: 80
      for asked in *{"default", "Default"}
        style, _, reached = Ass.resolveStyle lowercase, asked
        ut\assertEquals style.fontsize, defaultStyle.fontsize
        ut\assertFalse reached

    -- Rendered with a 200px style declared and nothing named Default: neither renderer reached for the
    -- one style the script did declare, both drawing the one each keeps for itself. Which one that is
    -- parts between them, so it is the caller's to name and a style's own defaults stand in for it.
    resolveStyle_fallsToTheStyleNamedRatherThanToAnythingDeclared: (ut) ->
      {:dialects, :DialectName} = require "l0.AssParser.dialects"
      only = "Only": createStyle name: "Only", fontsize: 200
      for named in *{DialectName.Libass, DialectName.XyVsfilter}
        keptByRenderer = dialects[named].fallbackStyle
        style, declaredName, reached = Ass.resolveStyle only, "Missing", keptByRenderer
        ut\assertEquals style, keptByRenderer
        ut\assertEquals declaredName, "Default"
        ut\assertFalse reached

      ut\assertEquals (Ass.resolveStyle {}, "Missing"), defaultStyle
      ut\assertEquals (Ass.resolveStyle nil, "Missing"), defaultStyle

    -- Rendering a script declaring nothing beside one declaring the fallback matched only where the
    -- weight was left at none and the secondary color was cyan for libass, and where it was bold and
    -- yellow for xy-VSFilter. Those two fields are the whole of where the renderers part.
    fallbackStyle_partsBetweenTheRenderersOnTheWeightAndTheSecondaryColor: (ut) ->
      {:dialects, :DialectName} = require "l0.AssParser.dialects"
      libass = dialects[DialectName.Libass].fallbackStyle
      vsfilter = dialects[DialectName.XyVsfilter].fallbackStyle
      ut\assertFalse libass.bold
      ut\assertTrue vsfilter.bold
      ut\assertNotEquals libass.color2, vsfilter.color2
      ut\assertNil dialects[DialectName.Aegisub].fallbackStyle

      parted = [key for key, value in pairs(vsfilter) when libass[key] != value]
      table.sort parted
      ut\assertItemsEqual parted, {"bold", "color2"}

    resolveStyle_reportsWhetherTheNameReachedADeclaration: (ut) ->
      stylesByName = Karaoke: createStyle name: "Karaoke"
      ut\assertTrue select 3, Ass.resolveStyle stylesByName, "Karaoke"
      ut\assertFalse select 3, Ass.resolveStyle stylesByName, "Missing"
      ut\assertFalse select 3, Ass.resolveStyle stylesByName, nil
  }
