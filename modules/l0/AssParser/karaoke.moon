Enum = require "l0.DependencyControl.Enum"
Scanner = require "l0.AssParser.Scanner"
{:TokenKind, :Syntax, :TagName, :DialectName, :dialects, :getOverrideTag, :isKaraokeTagName} = require "l0.AssParser.dialects"
AssRunState = require "l0.AssParser.RunState"
{:emitTag} = require "l0.AssParser.emit"
{:LineClass, :WrapStyle, :defaultStyle, :defaultWrapStyle} = require "l0.AssParser.ass"

msgs = {
  new: {
    unknownModel: "No karaoke model for dialect '%s'."
  }
  parseKaraokeData: {
    notADialogueLine: "Subtitle line must be a dialogue line."
  }
}

-- Aegisub counts a karaoke duration in centiseconds and reports it in milliseconds.
CENTISECONDS_TO_MILLISECONDS_SCALE = 10

-- The tag a line starts under, before any karaoke tag has been seen.
DEFAULT_KARAOKE_TAG = getOverrideTag TagName.Karaoke

---Whether `\n` breaks a line, which turns on the wrap style in force and on the dialect reading it.
---@param dialect AssDialectName Whose reading to apply.
---@param wrapStyle AssWrapStyle The style in force where the escape stands.
---@return boolean breaks true if the escape breaks a line, false if it renders as a space.
softLineBreaksActiveUnder = (dialect, wrapStyle) ->
  return true if wrapStyle == WrapStyle.NoWordWrap
  return false unless dialects[dialect].softLineBreaksActiveAboveDeclaredWrapStylesRange
  return wrapStyle > WrapStyle.SmartBottomWider

-- The escapes that break a line, `\n` only where the wrap style in force lets it. Both renderers read
-- this as they read the character, so a `\q` later in the line does not reach back.
HARD_BREAK_ESCAPE_CHARACTER = "N"
SOFT_BREAK_ESCAPE_CHARACTER = "n"

---Where the next line break sits in a run of text, searching from one byte.
---@param text string
---@param searchFrom integer The byte to search from.
---@param breaksSoftly boolean Whether `\n` breaks as well as `\N`.
---@return integer? at The byte the backslash sits on, nil where no break follows.
findLineBreak = (text, searchFrom, breaksSoftly) ->
  index = searchFrom
  while true
    at = text\find Syntax.EscapePrefix, index, true
    return nil unless at
    escaped = text\sub at + 1, at + 1
    return at if escaped == HARD_BREAK_ESCAPE_CHARACTER or (breaksSoftly and escaped == SOFT_BREAK_ESCAPE_CHARACTER)
    index = at + 1

---How a dialect reads karaoke, which its tag table alone does not settle. All three advance the clock
---the same way for the `\k` family — a syllable starts where the last one ended — and differ over what
---an argument-less tag means and what delimits a syllable at all. Whether a decimal duration keeps
---its fraction is not a model trait: the scan types a karaoke argument per dialect, so `\k50.9` is
---509 milliseconds to the renderers and 500 to Aegisub before any of this is consulted.
---@class AssKaraokeModel
---@field emptyDuration integer Milliseconds a karaoke tag written with no argument lasts.
---@field segmentsByStyleRun boolean Whether a syllable runs for as long as the text keeps one
---  appearance, rather than from one karaoke tag to the next. Three things end one where it does — a
---  karaoke tag declaring a duration, a change of karaoke type, and any tag changing the appearance —
---  so `{\k50}a{\4c&H0000FF&}b` and `{\k50}a{\kf0}b` are two syllables where `{\k50}a{\k0}b` is one.
---  Aegisub reads none of it and opens a syllable per tag, making all three of those two syllables.
modelByDialect = {
  [DialectName.Aegisub]: {emptyDuration: 0}
  [DialectName.Libass]: {emptyDuration: 1000}
  [DialectName.XyVsfilter]: {emptyDuration: 1000}
}

-- a dialect delimits a syllable by a run of text exactly where it compares runs at all, so the two
-- are one fact and the dialect record is where it is declared
for name, model in pairs modelByDialect
  model.segmentsByStyleRun = dialects[name].runComparison != nil

---Reads a karaoke tag's duration off the typed argument the scan attached. Only a missing argument
---takes the dialect's default, so one that is present but holds no number counts as zero in every
---dialect.
---@param token AssToken The karaoke tag.
---@param model AssKaraokeModel The dialect's reading of karaoke.
---@return integer milliseconds The duration, zero where the argument holds no number.
readDuration = (token, model) ->
  return model.emptyDuration if #token.params == 0
  math.floor (token.arguments[1] or 0) * CENTISECONDS_TO_MILLISECONDS_SCALE

---The types of sections that are separated from the plain text in a karaoke span
---to reproduce the `text_stripped` field in each syllable returned by `aegisub.parse_karaoke_data()`
---@alias AssKaraokeSectionKind
---| 1 # OverrideBlock: the braces and everything between them
---| 2 # Drawing: the commands a `\p` before them switched into
SectionKind = Enum "AssKaraokeSectionKind", {
  OverrideBlock: 1
  Drawing: 2
}

---One section of a line `text_stripped` leaves out, and where it sat among a span's plain characters.
---@class AssKaraokeStrippedSection
---@field textOffset integer Characters of the span's text preceding it, so 0 puts it before the first.
---@field text string The characters as the line wrote them.
---@field kind AssKaraokeSectionKind Whether those characters are an override block or a drawing.
---@field closed boolean Whether it takes no more text, as a `}` leaves an override block and a drawing always is.

---One span of a line between karaoke tags: the plain text it renders, and the override blocks and
---drawings that sat between those characters. Keeping them is what lets the span report its text both
---ways, as Aegisub reports a syllable's `text` beside its `text_stripped`.
---@class AssKaraokeSpan
---@field text string Plain text only, which is what renders.
---@field strippedSections AssKaraokeStrippedSection[] Ordered, splicing back what `text_stripped` leaves out.
---@field tag string The override tag that opened it, as the line wrote it.
---@field startTime integer Milliseconds from the line's start.
---@field duration integer Milliseconds.
class AssKaraokeSpan
  ---Creates an empty karaoke span.
  ---@param tag? string The karaoke tag opening this span, `\k` for the one a line starts under.
  ---@param startTime? integer Milliseconds from the line's start, zero by default.
  new: (@tag = DEFAULT_KARAOKE_TAG, @startTime = 0) =>
    @text = ""
    @strippedSections = {}
    @duration = 0

  ---Appends a non-text section after the span's text so far. Two of one kind with no rendered text between them
  ---share an offset, so sections that follow one another directly become a single one, unless the
  ---earlier one has been closed.
  ---@param sectionText string The characters to splice back in at this point.
  ---@param kind AssKaraokeSectionKind Whether they are an override block or a drawing.
  appendStrippedSection: (sectionText, kind) =>
    textOffset = #@text
    last = @strippedSections[#@strippedSections]
    if last and last.textOffset == textOffset and last.kind == kind and not last.closed
      last.text ..= sectionText
    else
      @strippedSections[#@strippedSections + 1] = {:textOffset, text: sectionText, :kind, closed: false}

  ---Marks the last section as taking no more text, so that the next append starts one of its own.
  closeLastStrippedSection: =>
    last = @strippedSections[#@strippedSections]
    last.closed = true if last

  ---Whether the last section is an override block still taking tags.
  ---@return boolean
  hasOpenOverrideBlock: =>
    last = @strippedSections[#@strippedSections]
    last != nil and last.kind == SectionKind.OverrideBlock and not last.closed

  ---Whether a drawing sits among the sections, so an empty `text` is not an empty span.
  ---@return boolean
  hasDrawing: =>
    return true for section in *@strippedSections when section.kind == SectionKind.Drawing
    return false

  ---Splices the stripped sections back between the characters, which is what Aegisub reports as a
  ---syllable's `text` where `text_stripped` leaves them out.
  ---@return string text The span's characters with every section put back where it was found.
  withStrippedSections: =>
    parts, taken = {}, 0
    for section in *@strippedSections
      parts[#parts + 1] = @text\sub taken + 1, section.textOffset
      parts[#parts + 1] = section.text
      taken = section.textOffset
    parts[#parts + 1] = @text\sub taken + 1
    table.concat parts

---Drops the karaoke spans the given predicate rejects, moving their sections into the next span that is kept.
---A dropped span's tags go on applying to the rest of the line, so carrying them is what preserves the
---line's appearance when the syllables are joined back together.
---@param spans AssKaraokeSpan[] Every span a scan produced, in order.
---@param shouldDropPredicate fun(span: AssKaraokeSpan, index: integer, count: integer): boolean Whether to drop this span.
---@return AssKaraokeSpan[] kept The spans the predicate kept, each holding the dropped ones' sections.
foldDroppedSpans = (spans, shouldDropPredicate) ->
  folded, carried = {}, {}
  count = #spans

  for index, span in ipairs spans
    if shouldDropPredicate span, index, count
      carried[#carried + 1] = section for section in *span.strippedSections
      continue

    if #carried > 0
      -- everything carried sat before this span's first character
      merged = [{textOffset: 0, text: s.text, kind: s.kind, closed: s.closed} for s in *carried]
      merged[#merged + 1] = section for section in *span.strippedSections
      span.strippedSections = merged
      carried = {}

    folded[#folded + 1] = span

  folded

---One syllable of `parseKaraokeData`'s result.
---@class AegisubKaraokeSyllable
---@field duration integer Length in milliseconds.
---@field start_time integer Milliseconds from the line's own start, not from zero.
---@field end_time integer `start_time` plus `duration`.
---@field tag string The karaoke tag that opened it, with its backslash, such as `\k` or `\kf`.
---@field text string The syllable's text with its override blocks put back where they were found.
---@field text_stripped string The same text with every override block, comment and drawing removed.

---A 0-based array of syllables. Index 0 is always present and always empty, a filler Aegisub has kept
---since 2.1.x stored everything before the first syllable there, so `#result` counts the real ones.
---@alias AegisubKaraokeData table<integer, AegisubKaraokeSyllable>

---One line's split in progress: the syllables finished so far, the one being filled, and the karaoke
---state the next tag is read against. Every method mutates it, so one is built per line and driven
---by the token loop rather than shared.
---@class AssKaraokeSplit
---@field spans AssKaraokeSpan[] Syllables finished so far, in order.
---@field span AssKaraokeSpan The syllable being filled.
---@field currentName AssTagName The karaoke tag the current syllable runs under.
---@field absoluteStart integer? Where a `\kt` said the next syllable starts, nil where none has.
---@field model AssKaraokeModel The dialect's reading of karaoke.
class AssKaraokeSplit
  ---@param model AssKaraokeModel The dialect's reading of karaoke.
  new: (@model) =>
    @spans = {}
    @span = AssKaraokeSpan!
    @currentName = TagName.Karaoke

  ---Appends rendered text to the syllable being filled.
  ---@param text string The characters as the line wrote them.
  appendText: (text) => @span.text ..= text

  ---Appends a drawing to the stripped sections of the syllable being filled.
  ---@param text string The drawing commands to splice back in at this point.
  appendDrawing: (text) =>
    @span\appendStrippedSection text, SectionKind.Drawing
    @span\closeLastStrippedSection!

  ---Appends override text to the syllable being filled, opening a block first where none is open.
  ---@param text string The characters to splice back in at this point.
  appendToOverrideBlock: (text) =>
    unless @span\hasOpenOverrideBlock!
      @span\appendStrippedSection Syntax.BlockOpen, SectionKind.OverrideBlock
    @span\appendStrippedSection text, SectionKind.OverrideBlock

  ---Closes the override block being filled, where one is open.
  closeOverrideBlock: =>
    return unless @span\hasOpenOverrideBlock!
    @span\appendStrippedSection Syntax.BlockClose, SectionKind.OverrideBlock
    @span\closeLastStrippedSection!

  ---Ends the syllable being filled and opens one starting where it ended, unless an absolute start
  ---was declared via `\kt`.
  ---@param name AssTagName The karaoke tag the new syllable runs under.
  ---@param duration integer How long the new syllable lasts, in milliseconds.
  endSyllable: (name, duration) =>
    @closeOverrideBlock!
    @spans[#@spans + 1] = @span
    @span = AssKaraokeSpan getOverrideTag(name), @absoluteStart or @span.startTime + @span.duration
    @span.duration = duration
    @currentName, @absoluteStart = name, nil

  ---Applies a karaoke tag. Most end the syllable and open one where it finished, with 2 exceptions
  ---that leave it open instead:
  ---  1. `\kt`, which only says where the next syllable starts
  ---  2. a tag without a duration under the karaoke type already in force
  ---@param token AssToken The karaoke tag to apply.
  applyKaraokeTag: (token) =>
    duration = readDuration token, @model

    if token.name == TagName.KaraokeAbsolute
      -- `{\kf50}aaa{\kt100}bbb` sweeps as one syllable, and only a karaoke tag after it takes the
      -- 1000ms. `currentName` is left alone because `\kt` declares no karaoke type.
      @absoluteStart = duration
      @appendToOverrideBlock emitTag token
      return

    leavesSyllableOpen = @model.segmentsByStyleRun and duration == 0 and token.name == @currentName
    return @endSyllable token.name, duration unless leavesSyllableOpen

    -- In `{\k50}{\k0}ab` no text has taken the 500ms yet, so this tag takes it instead and it becomes
    -- a delay: `ab` is sung from 500ms and lasts none. In `{\k50}a{\k0}b` the text took it first, so
    -- the syllable keeps its 500ms and this tag changes nothing.
    if #@span.text == 0
      @span.startTime += @span.duration
      @span.duration = 0
    @appendToOverrideBlock emitTag token

  ---Ends the last syllable and reports what the line split into.
  ---@return AssKaraokeSpan[] spans Always at least one, since a line with no karaoke tag is one span.
  finish: =>
    @spans[#@spans + 1] = @span
    return @spans unless @model.segmentsByStyleRun

    -- Consecutive karaoke tags leave a syllable holding nothing at all, which only moves the clock. A
    -- drawing renders in a run of its own, so a span holding one is never folded into its neighbors.
    foldDroppedSpans @spans, (span, index, count) ->
      #span.text == 0 and not span\hasDrawing! and index < count

---Parse karaoke data in ASS dialogue lines and splits them into syllables.
---
---The reporting shape is always Aegisub's, whichever dialect is used (the index-zero filler, the
---dropping of a zero-duration syllable holding no text and the `\K` to `\kf` rename are its
---normalization). What the dialect changes is where the syllables fall and how the
---clock moves.
---@class AssKaraokeReader
---@field dialect AssDialectName Which dialect this reader applies. Read-only.
---@field model AssKaraokeModel How that dialect reads karaoke. Read-only.
class AssKaraokeReader
  ---@param dialect? AssDialectName Whose karaoke reading to apply, Aegisub's by default.
  ---@param model? AssKaraokeModel That dialect's reading of karaoke, its declared one by default.
  new: (@dialect = DialectName.Aegisub, model) =>
    declared, err = DialectName\validate @dialect, "dialect"
    assert declared, err

    @model = model or modelByDialect[@dialect]
    assert @model, msgs.new.unknownModel\format tostring @dialect
    @scanner = Scanner @dialect

  ---Splits a line's text at the points its dialect ends a syllable.
  ---@param text string A line's Text field.
  ---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent.
  ---  Only read where the dialect ends a syllable at an appearance change, since deciding whether one
  ---  moved needs what the style set to compare against.
  ---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches by name.
  ---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line where
  ---  no `\q` has overridden it. Inert for a dialect that compares no runs, since a break ends nothing
  ---  there. Automatic wrapping is out of reach either way, so a line long enough to wrap splits
  ---  further in a renderer than this reports.
  ---@return AssKaraokeSpan[] spans Always at least one, since a line with no karaoke tag is one span.
  splitSyllables: (text, style, stylesByName, wrapStyle = defaultWrapStyle) =>
    styleState = @model.segmentsByStyleRun and AssRunState(style or defaultStyle, @dialect, stylesByName)
    split = AssKaraokeSplit @model
    breaksRuns = @model.segmentsByStyleRun
    inForce = wrapStyle

    for token in *@scanner\scan text or ""
      switch token.kind
        when TokenKind.Text
          unless breaksRuns
            split\appendText token.text
          else
            index, breaksSoftly = 1, softLineBreaksActiveUnder(@dialect, inForce)
            while true
              at = findLineBreak token.text, index, breaksSoftly
              break unless at
              -- the break belongs to the syllable it ends, and the text after it opens the next
              split\appendText token.text\sub index, at + 1
              split\endSyllable split.currentName, 0
              index = at + 2
            split\appendText token.text\sub index

        when TokenKind.Drawing
          -- Both renderers isolate a drawing in a run of its own, whatever scale it was written at, so
          -- text on either side of one is sung apart from it. A syllable holding no text yet is taken
          -- rather than ended, as under a tag moving the appearance.
          split\endSyllable split.currentName, 0 if styleState and #split.span.text > 0
          split\appendDrawing token.text
          split\endSyllable split.currentName, 0 if styleState

        when TokenKind.BlockEnd
          split\closeOverrideBlock!

        when TokenKind.Comment, TokenKind.Junk
          split\appendToOverrideBlock token.text

        when TokenKind.Tag
          if isKaraokeTagName token.name
            split\applyKaraokeTag token
          else
            -- A tag moving the text's appearance ends the syllable, and the text after it opens one
            -- of zero length under the same karaoke tag: `{\k50}a{\b1}b` is two syllables, `a`
            -- running from 0 to 500ms and `b` sung at 500ms, whereas `{\k50}a{\b0}b` is one syllable
            -- because `\b0` writes the weight the style already set. A syllable a karaoke tag has just
            -- opened holds no text yet, so the text after the tag takes it rather than starting one of
            -- its own: `{\k50}a{\k50}{\b1}b` sings `b` at 500ms, not at 1000.
            if token.name == TagName.WrapStyle
              -- `\qabc` reads as zero, where `\q` and `\q9` both put the script's own style back
              stated = #token.params > 0 and (token.arguments and token.arguments[1] or 0) or nil
              inForce = WrapStyle\validate(stated) and stated or wrapStyle

            moved = styleState and styleState\applyTag token
            split\endSyllable split.currentName, 0 if moved and #split.span.text > 0
            split\appendToOverrideBlock emitTag token

    split\finish!

  ---Splits a dialogue line into karaoke syllables, reproducing `aegisub.parse_karaoke_data`.
  ---
  ---Syllable timings are milliseconds from the line's own start, but may run past the line's end time.
  ---A line without a karaoke tag still yields one syllable.
  ---@param line AegisubDialogueLine A dialogue line. Only `class` and `text` are read.
  ---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent.
  ---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches by name.
  ---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
  ---@return AegisubKaraokeData? syllables
  ---@return string? err When the argument is not a dialogue line.
  parseKaraokeData: (line, style, stylesByName, wrapStyle) =>
    unless type(line) == "table" and line.class == LineClass.Dialogue
      return nil, msgs.parseKaraokeData.notADialogueLine

    -- Aegisub tests a syllable for zero duration and no text only when a further karaoke tag arrives,
    -- so the same empty syllable is dropped mid-line but kept at the end. As a consequence, every line
    -- is guaranteed to report at least one syllable.
    spans = foldDroppedSpans @splitSyllables(line.text, style, stylesByName, wrapStyle),
      (span, index, count) -> span.duration == 0 and #span.text == 0 and index < count

    -- Aegisub has kept a filler syllable at index 0 since 2.1.x for backwards compatibility
    result = {[0]: {duration: 0, start_time: 0, end_time: 0, tag: "", text: "", text_stripped: ""}}

    for span in *spans
      -- `\K` is the older spelling of `\kf`, and Aegisub reports it under the newer one
      tag = span.tag == getOverrideTag(TagName.KaraokeFillLegacy) and
        getOverrideTag(TagName.KaraokeFill) or span.tag

      result[#result + 1] = {
        duration: span.duration
        start_time: span.startTime
        end_time: span.startTime + span.duration
        :tag
        text: span\withStrippedSections!
        text_stripped: span.text
      }

    return result

defaultReader = AssKaraokeReader!

---@class AegisubKaraokeShim
---@field Reader AssKaraokeReader Reads karaoke in one dialect, Aegisub's where its constructor is given none.
---@field parseKaraokeData fun(line: AegisubDialogueLine): AegisubKaraokeData?, string? Aegisub's reading, which is what the shim installs.
---@field splitSyllables fun(text: string): AssKaraokeSpan[] Aegisub's syllable split.
-- Both are installed on the `aegisub` table, which takes plain functions, so neither can be the
-- reader's method as it stands. Neither takes a style either, since Aegisub opens a syllable per
-- karaoke tag and compares no appearance, so only a reader built for another dialect reads one.
return {
  Reader: AssKaraokeReader
  :SectionKind
  parseKaraokeData: (line) -> defaultReader\parseKaraokeData line
  splitSyllables: (text) -> defaultReader\splitSyllables text
}
