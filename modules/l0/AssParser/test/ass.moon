-- Pins the line and style shapes Aegisub's automation API hands over, and the color notation a style
-- and the color tags share. The notation has three shapes holding different things — a style names a
-- color and its alpha in one value, the tags name them apart — so the pair is asserted in both
-- directions and against the defaults, which are themselves written through the emitter.
-- Called from test.moon as: (controls\requireTest "ass")!
->
  Ass = require "l0.AssParser.ass"
  {:BorderStyle, :ColorNotation, :LineClass, :createStyle, :defaultStyle,
  :emitColor, :packStyleColor, :parseColor, :splitStyleColor, :validateStyle,
  :defaultWrapStyle, :getWrapStyle, :WrapStyle} = Ass

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
      ut\assertEquals getWrapStyle({makeInfoLine "Title", "something else"}), defaultWrapStyle
      ut\assertEquals getWrapStyle({}), defaultWrapStyle

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
      ut\assertEquals getWrapStyle(lines), defaultWrapStyle

    createStyle_takesTheOverridesGiven: (ut) ->
      ut\assertEquals createStyle(fontsize: 72).fontsize, 72

    validateStyle_acceptsOneItBuilt: (ut) ->
      ut\assertTrue validateStyle createStyle!

    validateStyle_rejectsANonStyleLine: (ut) ->
      valid, err = validateStyle {class: LineClass.Dialogue}
      ut\assertNil valid
      ut\assertString err

    validateStyle_rejectsAFieldOfTheWrongType: (ut) ->
      valid, err = validateStyle createStyle bold: 1
      ut\assertNil valid
      ut\assertString err

    -- Aegisub reads whatever integer the file held and writes it back, so a value the format gives no
    -- meaning to still has to pass. `BorderStyle\validate` is what asks the stricter question.
    validateStyle_acceptsABorderStyleTheFormatDoesNotDefine: (ut) ->
      ut\assertTrue validateStyle createStyle borderstyle: 2
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
  }
