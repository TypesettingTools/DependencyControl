-- cspell:ignore HAABBGGRR -- the ASS color template, whose letters spell out its byte order
-- cspell:ignore rnds rndx rndy rndz movevc fsvp -- VSFilterMod-only tags
--
-- A finding about how the dialects differ is recorded here as something a test can contradict, rather
-- than as prose that quietly goes stale.
--
-- Whether two lines are equivalent is derived rather than declared. `isEquivalent` asks the scanner,
-- the run state and the karaoke reader how a line reads under one dialect, and the two are
-- equivalent there when those agree. So `equivalences` below states only *which dialects agree*, and
-- `isEquivalent` is free to contradict it, which is what the accompanying tests check.

Enum = require "l0.DependencyControl.Enum"
Scanner = require "l0.AssParser.Scanner"
AssRunState = require "l0.AssParser.RunState"
karaoke = require "l0.AssParser.karaoke"
lineState = require "l0.AssParser.LineState"
{:canonicalArgumentFor, :read} = require "l0.AssParser.arguments"
{:canonicalizeDrawing, :drawingOpensUnder, :countLeftoverCoordinates} = require "l0.AssParser.drawing"
{:emit} = require "l0.AssParser.emit"
{:BorderStyle, :LineClass, :WrapStyle, :defaultStyle} = require "l0.AssParser.ass"
{:ArgumentType, :DialectName, :DrawingCommandName, :RunField, :Syntax, :TagName, :TokenKind,
  :drawingCommands, :dialects, :getArgumentReading, :isKaraokeTagName,
  :overrideTags} = require "l0.AssParser.dialects"

-- Override tags only supported by VSFilterMod and ignored by all supported dialects.
-- Used only to emit a bespoke warning rather than just classifying them as unknown.
-- Longest first, so a prefix match finds `moves4` before `moves` and `rnds` before `rnd`.
sortedVsfilterModTagNames = {
  "1img", "1va", "1vc", "2img", "2va", "2vc", "3img", "3va", "3vc", "4img", "4va", "4vc"
  "distort", "frs", "fsvp", "jitter", "mover", "moves3", "moves4", "movevc"
  "rnd", "rnds", "rndx", "rndy", "rndz", "z"
}
table.sort sortedVsfilterModTagNames, (a, b) -> #a > #b

-- `\t` is left out of the set the whole-line check reads, because it is the tag that check is about:
-- one holding no tags disables collisions like any other, so counting it here would report every empty
-- transform as removable on the strength of itself.
collisionDisablingTagNames = {}
for name, definition in pairs overrideTags
  collisionDisablingTagNames[name] = true if definition.disablesCollisionDetection and name != TagName.Transform

-- `Enum` fills `values` through `pairs`, whose order is unspecified, so a descriptor that walked it
-- raw would differ between runs of the same input
sortedRunFields = [field for field in *RunField.values]
table.sort sortedRunFields

-- The fields every run-comparing dialect tracks. A field only one of them compares is left out, since
-- its presence alone would part every pair of dialects before a value was ever read: only VSFilter
-- compares the character set, so a descriptor holding it never matches libass's on any line at all.
---@type AssRunField[]
comparedByEveryDialect = do
  comparing, tracking = 0, {}
  for name in *DialectName.values
    continue unless dialects[name].runComparison
    comparing += 1
    state = AssRunState defaultStyle, name
    tracking[field] = (tracking[field] or 0) + 1 for field in *sortedRunFields when state.values[field] != nil
  [field for field in *sortedRunFields when tracking[field] == comparing]

---Reads a line into the run state a dialect tracks, applying every tag but the karaoke ones. Karaoke is
---left out because it opens a syllable rather than moving the appearance.
---@param dialect AssDialectName Whose reading to apply.
---@param text string A line's Text field.
---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches.
---@return AssRunState? state Nil for a dialect comparing no runs, which builds no state at all.
buildState = (dialect, text, style, stylesByName) ->
  return nil unless dialects[dialect].runComparison
  state = AssRunState style or defaultStyle, dialect, stylesByName
  for token in *Scanner(dialect)\scan text or ""
    continue unless token.kind == TokenKind.Tag
    state\applyTag token unless isKaraokeTagName token.name
  state

---Serializes the line-level properties into a string two identical readings share. Held apart from the
---run appearance because a rewrite can move a line across the frame without touching a single field a
---renderer compares runs on.
---@param state AssLineState The line-level state a scan produced.
---@return string described Empty where the line states none of it, so an ordinary line is unaffected.
describeLineState = (state) ->
  parts = {}
  if held = state.position
    parts[#parts + 1] = "pos=#{held.x},#{held.y}"
  if held = state.move
    parts[#parts + 1] = "move=#{held.x1},#{held.y1},#{held.x2},#{held.y2}@#{held.startTime},#{held.endTime}"
  parts[#parts + 1] = "an=#{state.alignment}" if state.alignment
  if held = state.origin
    parts[#parts + 1] = "org=#{held.x},#{held.y}"
  if held = state.fade
    parts[#parts + 1] = "fade=#{held.startAlpha},#{held.midAlpha},#{held.endAlpha}@#{held.fadeInStart},#{held.fadeInEnd},#{held.fadeOutStart},#{held.fadeOutEnd}"
  parts[#parts + 1] = "q=#{state.wrapStyle}" if state.wrapStyle
  if held = state.clip
    shape = held.rectangle and
      "#{held.rectangle.x1},#{held.rectangle.y1},#{held.rectangle.x2},#{held.rectangle.y2}" or
      "#{held.scale}:#{held.drawing}"
    parts[#parts + 1] = "#{held.inverse and 'iclip' or 'clip'}=#{shape}"
  -- A line exempt from collision detection stays where it is while one beside it is pushed aside, so
  -- dropping the last tag that exempts it moves the line even though every run is drawn the same.
  parts[#parts + 1] = "collisions=off" if state.collisionsDisabled

  #parts > 0 and "<line #{table.concat parts, ' '}>" or ""

---Picks moments a line should read at to determine equality between two lines when transforms are at play:
---  - the start of the line (zero)
---  - where each of its transforms (if any) opens, stands halfway and closes
---@param tokens AssToken[] The line's tokens, nested children included.
---@param durationMs? integer How long the line is on screen, which a transform naming no interval
---  animates across. When not provided, the duration is assumed to be DEFAULT_EVENT_DURATION
---  or 1 second past the furthest end time of any transform on the line, whichever is greater.
---@return integer[] times Ascending, always holding 0.
---@return integer span What a transform naming no interval was taken to animate across, which the run
---  state has to be given so that it reads those transforms at the moments sampled here.
sampleTimesFor = (tokens, durationMs) ->
  bounds = {}
  bounds[0] = true
  latest = 0

  sawInterval, sawWholeLine = false, false
  collect = (list) ->
    for token in *list
      continue unless token.kind == TokenKind.Tag
      if token.name == TagName.Transform
        args = token.arguments or {}
        -- Only the three- and four-argument forms open with a start and an end; the shorter two animate
        -- across the whole line, as does an end time of zero. A zero-length interval applies the tags at
        -- that instant and they hold until something later writes the same field.
        if #args >= 3 and type(args[1]) == "number" and type(args[2]) == "number" and
            args[2] >= args[1] and args[2] != 0
          bounds[args[1]] = true
          bounds[args[2]] = true
          bounds[math.floor (args[1] + args[2]) / 2] = true
          latest = math.max latest, args[2]
          sawInterval = true
        else
          sawWholeLine = true
      collect token.children if token.children

  collect tokens

  span = durationMs or math.max AssRunState.DEFAULT_EVENT_DURATION, latest + 1000
  if sawWholeLine
    bounds[span] = true
    bounds[math.floor span / 2] = true
    latest = math.max latest, span
    sawInterval = true

  bounds[latest + 1000] = true if sawInterval

  times = [time for time in pairs bounds]
  table.sort times
  return times, span

---Serializes a line's appearance under the given dialect, represented as a string usable to compare two lines
---for equality.
---@param dialect AssDialectName Whose reading to apply.
---@param text string A line's Text field.
---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@param durationMs? integer How long the line is on screen, which a transform with a zero or unset end
---  time animates across. When not provided, the duration is assumed to be DEFAULT_EVENT_DURATION
---  or 1 second past the furthest end time of any transform on the line, whichever is greater.
---@return string descriptor The line's syllables, each drawing in canonical form, and the appearance
---  every run is drawn in where the dialect compares runs.
describeLine = (dialect, text, style, stylesByName, wrapStyle, durationMs) ->
  reader = karaoke.Reader dialect
  parts = ["#{span.tag}@#{span.startTime}+#{span.duration}:#{span.text}" for span in *reader\splitSyllables text, style, stylesByName, wrapStyle]

  tokens = Scanner(dialect)\scan text or ""

  lineLevelState = lineState.readTokens tokens
  for token in *tokens
    continue unless token.kind == TokenKind.Drawing
    drawn = canonicalizeDrawing token.commands or {}, dialect
    -- A drawing this dialect draws no part of is the same picture as no drawing at all.
    parts[#parts + 1] = "<#{drawn}>" if #drawn > 0

  if dialects[dialect].runComparison
    times, wholeLineSpan = sampleTimesFor tokens, durationMs
    for time in *times
      state = AssRunState style or defaultStyle, dialect, stylesByName, wholeLineSpan
      state.time = time
      parts[#parts + 1] = "@t#{time}"

      recorded = nil
      for token in *tokens
        state\applyTag token if token.kind == TokenKind.Tag and not isKaraokeTagName token.name
        -- The appearance is recorded at each run of text (where the run state changed), so a trailing tag
        -- isn't recorded in the descriptor, which matches its lack of impact on the the line's appearance.
        continue unless token.kind == TokenKind.Text or token.kind == TokenKind.Drawing
        held = ["#{field}=#{tostring state.values[field]}" for field in *sortedRunFields when state.values[field] != nil]
        current = "[#{table.concat held, ' '}]"
        if current != recorded
          parts[#parts + 1] = current
          recorded = current

  serializeLineLevelState = describeLineState lineLevelState
  parts[#parts + 1] = serializeLineLevelState if #serializeLineLevelState > 0

  table.concat parts, " "

---Describes every style field a line leaves in force, in the canonical representation `getValue` reads,
---as one string. Two dialects producing the same string draw the line alike, which `describeLine` cannot
---be asked, since it reports each dialect's own representation.
---
---Fields only one dialect tracks are left out, so `\fe` reads alike here even though it ends a run for
---VSFilter and not for libass. `describeKaraokeSyllables` is what answers that half.
---@param dialect AssDialectName Whose reading to apply.
---@param text string A line's Text field.
---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches.
---@return string? descriptor Nil for a dialect comparing no runs, which leaves it nothing to report.
describeCanonicalAppearance = (dialect, text, style, stylesByName) ->
  state = buildState dialect, text, style, stylesByName
  return nil unless state

  held = {}
  for field in *comparedByEveryDialect
    value = state\getValue field
    held[#held + 1] = "#{field}=#{tostring value}" if value != nil
  table.concat held, " "

---Whether one dialect reads two lines alike, which is what makes rewriting the first into the second
---safe for it.
---@param dialect AssDialectName Whose reading to apply.
---@param text string The line as written.
---@param rewritten string The line it would be rewritten to.
---@param style? AegisubStyleLine The style the line is set in.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@param durationMs? integer How long the line is on screen. When not provided, the duration is assumed to be DEFAULT_EVENT_DURATION
---  or 1 second past the furthest end time of any transform on the line, whichever is greater.
---@return boolean equivalent True where the dialect reads the two alike, so the rewrite is safe for it.
isEquivalent = (dialect, text, rewritten, style, stylesByName, wrapStyle, durationMs) ->
  describeLine(dialect, text, style, stylesByName, wrapStyle, durationMs) ==
    describeLine dialect, rewritten, style, stylesByName, wrapStyle, durationMs

---Describes the karaoke syllables a dialect reads a line as, with their timings and stripped text. This
---is the one reading of a line that means the same thing in every dialect, which is what makes it the
---reading to compare two of them by. `describeLine` cannot be: it holds the appearance each dialect
---tracks in that dialect's own representation, so libass holding a weight of 0 where VSFilter holds
---400 would part two dialects that agree about everything a viewer could see.
---@param dialect AssDialectName Whose reading to apply.
---@param text string A line's Text field.
---@param style? AegisubStyleLine The style the line is set in.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@return string descriptor One entry per syllable, holding its tag, timings and stripped text.
describeKaraokeSyllables = (dialect, text, style, stylesByName, wrapStyle) ->
  reader = karaoke.Reader dialect
  syllables = assert reader\parseKaraokeData {class: LineClass.Dialogue, :text}, style, stylesByName, wrapStyle
  described = ["#{syllables[index].tag}@#{syllables[index].start_time}+#{syllables[index].duration}:#{syllables[index].text_stripped}" for index = 1, #syllables]
  table.concat described, " "

---Groups the dialects that report a line as the same syllables. One group holding all three is the
---ordinary case and the one a diagnostic stays quiet on; any other shape is a divergence in timing.
---
---Only the karaoke syllables are compared, so this is blind to a divergence that changes what is drawn
---without moving a syllable boundary — a fractional `\be` on a line holding no karaoke tag, say.
---`describeCanonicalAppearance` answers that half, across the fields every dialect compares.
---@param text string A line's Text field.
---@param style? AegisubStyleLine The style the line is set in.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@return AssDialectName[][] groups Each holding the dialects sharing one reading, ordered by name.
groupDialectsByKaraokeReading = (text, style, stylesByName, wrapStyle) ->
  names = [name for name in *DialectName.values]
  table.sort names

  groups, byDescriptor = {}, {}
  for name in *names
    descriptor = describeKaraokeSyllables name, text, style, stylesByName, wrapStyle
    unless byDescriptor[descriptor]
      byDescriptor[descriptor] = {}
      groups[#groups + 1] = byDescriptor[descriptor]
    group = byDescriptor[descriptor]
    group[#group + 1] = name

  groups

---How much a finding matters, which its code's prefix decides.
---@alias AssFindingSeverity
---| "error" # Error: an element the format defines can't be read in a meaningful way at all and is discarded
---| "warning" # Warning: a tag at least one of the dialects does not read exactly as written
---| "info" # Info: a benign note, safe to surface or drop
Severity = Enum "AssFindingSeverity", {
  Error: "error"
  Warning: "warning"
  Info: "info"
}

---Every finding that can be reported, each prefixed by the severity it carries.
---@alias AssFindingCode
---| "W-RESET-UNKNOWN-STYLE" # ResetToUnknownStyle: a `\r` names a style the script does not declare
---| "W-WHITESPACE-IN-TAG" # WhitespaceInTag: whitespace stands between a tag's backslash and its name
---| "W-UNCLOSED-ARGUMENT-LIST" # UnclosedArgumentList: a parenthesized argument list is never closed
---| "W-LINE-TAG-IGNORED" # LineTagIgnored: a second tag of a kind only the line's first is read from
---| "I-BLOCK-MARKER" # BlockMarker: asterisks an automation script marks its own blocks with
---| "W-STRAY-BACKSLASH" # StrayBackslash: a backslash naming no tag at all
---| "W-UNRECOGNIZED-TAG" # UnrecognizedTag: a backslash and a name no dialect knows as a tag
---| "W-VSFILTERMOD-TAG" # VsfilterModTag: a tag only VSFilterMod implements
---| "W-COLOR-LITERAL-MALFORMED" # ColorLiteralMalformed: a color or alpha written without the `&H…&` a literal needs
---| "W-COLOR-ALPHA-IGNORED" # ColorAlphaIgnored: a style's eight-digit color in a tag that reads six
---| "W-TRANSFORM-NESTED" # TransformNested: a transform inside a transform, which replaces its interval
---| "W-TRANSFORM-PARENTHESIZED-ARGUMENT" # TransformParenthesizedArgument: a parenthesized tag inside a transform ends its argument list early
---| "W-TRANSFORM-EMPTY" # TransformEmpty: a transform holding no tags, on a line whose collision detection something else already switches off
---| "W-TRANSFORM-EMPTY-HOLDS-COLLISIONS" # TransformEmptyHoldsCollisions: a transform holding no tags, and the only thing switching the line's collision detection off
---| "E-UNMATCHED-SIGNATURE" # UnmatchedSignature: a form matching no signature the tag declares, whether the argument count is wrong or a complex tag was written without parentheses
---| "W-ARGUMENT-REFUSED" # ArgumentRefused: the argument is refused, so the tag acts as its bare form
---| "W-VALUE-RESTORES-STYLE" # ValueRestoresStyle: a value at or below zero puts the style's own back
---| "W-VALUE-CLAMPED" # ValueClamped: the value falls outside the range read and is taken as the bound
---| "W-VALUE-ROUNDED" # ValueRounded: a fraction is read as a whole number
---| "W-VALUE-NOT-AS-WRITTEN" # ValueNotAsWritten: the value read differs from the one written, otherwise
---| "W-CHARACTER-SET-NOT-COMPARED" # CharacterSetNotCompared: `\fe` ends a run in one dialect and not another
---| "W-JUNK-IN-BLOCK" # JunkInBlock: characters beside a tag that read as no tag
---| "I-COMMENT-BLOCK" # CommentBlock: an override block holding no tag at all, which nothing draws
---| "E-DRAWING-REJECTED" # DrawingRejected: nothing opens the drawing, so no renderer draws any of it
---| "W-DRAWING-UNRECOGNIZED-TOKEN" # DrawingUnrecognizedToken: a word that is neither a command nor a coordinate
---| "W-DRAWING-INCOMPLETE-ARGUMENTS" # DrawingIncompleteArguments: a command left with coordinates too few to use
---| "W-DRAWING-ORPHANED-POINTS" # DrawingOrphanedPoints: whole points that do not complete a curve's batch
---| "W-DRAWING-ROOT-FROM-OPEN-MOVE" # DrawingRootFromOpenMove: an open move stands in for a move that took no point
---| "W-DRAWING-EXTENSION-WITHOUT-NODES" # DrawingExtensionWithoutNodes: a command reaching back for nodes the drawing has not got, which a spline needing three of them and any command before the first move both do
FindingCode = Enum "AssFindingCode", {
  ResetToUnknownStyle: "W-RESET-UNKNOWN-STYLE"
  WhitespaceInTag: "W-WHITESPACE-IN-TAG"
  UnclosedArgumentList: "W-UNCLOSED-ARGUMENT-LIST"
  LineTagIgnored: "W-LINE-TAG-IGNORED"
  BlockMarker: "I-BLOCK-MARKER"
  StrayBackslash: "W-STRAY-BACKSLASH"
  UnrecognizedTag: "W-UNRECOGNIZED-TAG"
  VsfilterModTag: "W-VSFILTERMOD-TAG"
  ColorLiteralMalformed: "W-COLOR-LITERAL-MALFORMED"
  ColorAlphaIgnored: "W-COLOR-ALPHA-IGNORED"
  TransformNested: "W-TRANSFORM-NESTED"
  TransformParenthesizedArgument: "W-TRANSFORM-PARENTHESIZED-ARGUMENT"
  TransformEmpty: "W-TRANSFORM-EMPTY"
  TransformEmptyHoldsCollisions: "W-TRANSFORM-EMPTY-HOLDS-COLLISIONS"
  UnmatchedSignature: "E-UNMATCHED-SIGNATURE"
  ArgumentRefused: "W-ARGUMENT-REFUSED"
  ValueRestoresStyle: "W-VALUE-RESTORES-STYLE"
  ValueClamped: "W-VALUE-CLAMPED"
  ValueRounded: "W-VALUE-ROUNDED"
  ValueNotAsWritten: "W-VALUE-NOT-AS-WRITTEN"
  CharacterSetNotCompared: "W-CHARACTER-SET-NOT-COMPARED"
  JunkInBlock: "W-JUNK-IN-BLOCK"
  CommentBlock: "I-COMMENT-BLOCK"
  DrawingRejected: "E-DRAWING-REJECTED"
  DrawingUnrecognizedToken: "W-DRAWING-UNRECOGNIZED-TOKEN"
  DrawingIncompleteArguments: "W-DRAWING-INCOMPLETE-ARGUMENTS"
  DrawingOrphanedPoints: "W-DRAWING-ORPHANED-POINTS"
  DrawingRootFromOpenMove: "W-DRAWING-ROOT-FROM-OPEN-MOVE"
  DrawingExtensionWithoutNodes: "W-DRAWING-EXTENSION-WITHOUT-NODES"
}

severityByCodePrefix = {
  E: Severity.Error
  W: Severity.Warning
  I: Severity.Info
}

---@type table<AssFindingCode, string>
templateByCode = {
  [FindingCode.ResetToUnknownStyle]: "`\\r%s` names no style the script declares, so the line's own style comes back."
  [FindingCode.WhitespaceInTag]: "Whitespace stands between the backslash and the name of `\\%s`."
  [FindingCode.UnclosedArgumentList]: "`\\%s` opens an argument list it never closes."
  [FindingCode.BlockMarker]: "`%s` marks the block as one an automation script generated. Every dialect ignores it."
  [FindingCode.StrayBackslash]: "`%s` names no tag, so every dialect reads past it."
  [FindingCode.UnrecognizedTag]: "`%s` names no tag any dialect knows, so every one of them reads past it and it draws nothing."
  [FindingCode.VsfilterModTag]: "`%s` names a tag only VSFilterMod implements. Aegisub, libass and xy-VSFilter all read past it, so the line draws as its author meant only in that fork."
  [FindingCode.ColorLiteralMalformed]: "`\\%s%s` is not a well-formed literal, so it is read as %s and the value written is lost. A color or alpha needs its `&H` and its closing `&`."
  [FindingCode.ColorAlphaIgnored]: "`\\%s%s` states the eight digits of a style's `&HAABBGGRR&`, where a color tag reads the six of `&HBBGGRR&`, so it is read as %s and the alpha is dropped."
  [FindingCode.LineTagIgnored]: "`\\%s` does nothing, since `\\%s` earlier in the line already set it and only the first of them is read."
  [FindingCode.TransformNested]: "`\\%s` holds another `\\t`, whose own interval replaces this one for the tags after it. A transform cannot animate a transform; write the two side by side instead."
  [FindingCode.TransformParenthesizedArgument]: "`\\%s` inside `\\%s` takes a parenthesized argument list, and its `)` closes the transform. Everything written after it lands outside the transform."
  [FindingCode.TransformEmpty]: "`\\%s` holds no tags and animates nothing. %s already switches this line's collision detection off, so the transform can be removed without moving the line."
  [FindingCode.TransformEmptyHoldsCollisions]: "`\\%s` holds no tags and animates nothing, but a `\\t` switches collision detection off whether or not it animates anything, and this line has nothing else that does. Removing it would let the line be pushed aside to clear another, so keep it or write a `\\pos`."
  [FindingCode.UnmatchedSignature]: "`\\%s` is written in a form that matches no signature it declares."
  [FindingCode.ArgumentRefused]: "`\\%s%s` is refused, so the tag acts as the bare `\\%s`."
  [FindingCode.ValueRestoresStyle]: "`\\%s%s` lands at or below zero, so the style's own value comes back."
  [FindingCode.ValueClamped]: "`\\%s%s` falls outside the range read, and is taken as %s."
  [FindingCode.ValueRounded]: "`\\%s%s` is read as the whole number %s."
  [FindingCode.ValueNotAsWritten]: "`\\%s%s` is not read as written, but as %s."
  [FindingCode.CharacterSetNotCompared]: "`\\%s%s` ends a run of text in some dialects and not others, which moves a karaoke syllable boundary."
  [FindingCode.JunkInBlock]: "`%s` stands beside a tag in an override block and reads as no tag."
  [FindingCode.CommentBlock]: "`%s` is a comment: an override block holding no tag, which nothing draws."
  [FindingCode.DrawingRejected]: "No renderer draws any part of the drawing: an `m` has to reach its first point, and here either none does or an `n` reaches one first."
  [FindingCode.DrawingUnrecognizedToken]: "`%s` is neither a drawing command nor a coordinate, so it and anything after it up to the next command is skipped."
  [FindingCode.DrawingIncompleteArguments]: "`%s` is left with %d coordinate(s) too few to draw with, which no renderer reads."
  [FindingCode.DrawingOrphanedPoints]: "`%s` is left with %d coordinate(s) too few to draw a further segment, which libass drops and VSFilter keeps in the path, widening the drawing without drawing them."
  [FindingCode.DrawingRootFromOpenMove]: "`m` reaches no point, so the `n` after it opens the drawing in libass alone."
  [FindingCode.DrawingExtensionWithoutNodes]: "`%s` needs %d node(s) before it and has %d, so no renderer reads it."
}

-- Aegisub draws nothing, so a line is read with the two dialects that do unless a caller asks wider
defaultFindingDialects = {DialectName.Libass, DialectName.XyVsfilter}

---One finding about a line: a tag a dialect does not read as it is written, or one written in a form
---a dialect refuses. Every finding anchors to the tag it is about.
---@class AssFinding
---@field code AssFindingCode Which finding this is an occurrence of.
---@field severity AssFindingSeverity Derived from the code's prefix.
---@field message string The code's template, filled with this occurrence's values.
---@field tag? string The tag as the line wrote it, name and parameters, without the backslash.
---  Absent on a finding about characters that are no tag at all.
---@field startIndex integer 1-based first byte of the tag in the line.
---@field endIndex integer 1-based last byte, inclusive.
---@field dialects AssDialectName[] The dialects that read the tag this way, in the order asked. A
---  finding naming every dialect asked is one they agree on; a shorter list is itself a divergence.

---Maps every token of an unedited stream, nested children included, to the byte range it was read
---from, which the round trip through the emitter being lossless is what makes derivable.
---@param tokens AssToken[] A stream as a scan returns it.
---@return table<AssToken, {startIndex: integer, endIndex: integer}> spans 1-based inclusive ranges, keyed by token.
mapTokenSpans = (tokens) ->
  spans = {}
  walk = (list, offset) ->
    for token in *list
      width = #emit {token}
      spans[token] = {startIndex: offset, endIndex: offset + width - 1}
      if token.kind == TokenKind.Tag and token.children
        -- the characters `emitTag` writes ahead of the parameters, which is where the children start
        {:form} = token
        paramsAt = offset + #Syntax.TagPrefix + #(form and form.whitespaceBeforeName or "") + #token.name
        paramsAt += #Syntax.ArgumentListOpen if form and form.parenthesized
        walk token.children, paramsAt
      offset += width
  walk tokens, 1
  return spans

-- The argument types that are not a single value a reading can be applied to: a run of tags, a shape,
-- and a style name.
valuelessArgumentTypes = {
  [ArgumentType.Tags]: true
  [ArgumentType.Drawing]: true
  [ArgumentType.StyleName]: true
}

---Whether a tag takes exactly one argument that a dialect's reading applies to, which is what the
---argument findings are derived from.
---@param definition AssTagDefinition The tag's entry of the tag table.
---@return boolean
takesOneReadValue = (definition) ->
  signature = definition.signatures[1]
  signature != nil and #signature == 1 and not valuelessArgumentTypes[signature[1]]

---Which finding a dialect's reading of one tag's argument makes, where it does not read it as written.
---The constraint that moved the value is what names the finding, so a clamp, a rounding and a refusal
---are told apart rather than reported as one.
---@param dialect AssDialectName Whose reading to apply.
---@param token AssToken The tag to read.
---@return AssFindingCode? code Nil where the dialect reads the argument exactly as it is written.
---@return string? canonical The spelling of what the dialect reads it as.
argumentFindingFor = (dialect, token) ->
  canonical = canonicalArgumentFor dialect, token
  return nil unless canonical

  return FindingCode.ArgumentRefused, canonical if canonical == ""

  reading = getArgumentReading dialect, token.name
  value = read dialect, token.name, token.params
  written = tonumber token.params

  return FindingCode.ValueRestoresStyle, canonical if reading.requiresPositive
  if written and "number" == type value
    return FindingCode.ValueClamped, canonical if reading.minimum and written < reading.minimum
    return FindingCode.ValueClamped, canonical if reading.maximum and written > reading.maximum
    conversion = reading.conversion
    return FindingCode.ValueRounded, canonical if conversion and conversion.roundsToWhole and written != value
  return FindingCode.ValueNotAsWritten, canonical

---Finds every defect a drawing holds, in the order its commands stand in it.
---@param commands AssDrawingCommand[] A drawing token's parsed commands.
---@return {code: AssFindingCode, values: any[], dialects?: AssDialectName[]}[] defects
findDrawingDefects = (commands) ->
  -- Where a drawing begins is the drawing module's rule. Asking it keeps one statement of that rule,
  -- since a second one here could drift from the reading the normalizer rewrites against.
  return {{code: FindingCode.DrawingRejected, values: {}}} unless drawingOpensUnder commands

  defects, nodes = {}, 0
  for command in *commands
    {:name, :coordinates} = command
    if command.junk
      -- every renderer stops reading a run at its first unreadable word, so the run is one defect
      defects[#defects + 1] = {
        code: FindingCode.DrawingUnrecognizedToken
        values: {command.junk[1]}
      }

    unless name
      -- no renderer reads coordinates written before the first command, having none to apply them to
      if #coordinates > 0
        defects[#defects + 1] = {
          code: FindingCode.DrawingUnrecognizedToken
          values: {tostring coordinates[1]}
        }
      continue

    arity = drawingCommands[name].arity
    if nodes < arity.needsNodes
      defects[#defects + 1] = {
        code: FindingCode.DrawingExtensionWithoutNodes
        values: {name, arity.needsNodes, nodes}
      }
      continue
    continue if arity.opens == 0

    -- A command reaching no coordinate at all is inert, and where a word it could not read is what
    -- left it so, that word is already reported. Only a command holding some but too few is named.
    if #coordinates > 0 and #coordinates < arity.opens and arity.dropsPartialOpening
      -- too few to draw anything at all, which every renderer discards alike
      defects[#defects + 1] = {
        code: FindingCode.DrawingIncompleteArguments
        values: {name, #coordinates}
      }
      continue

    leftover = countLeftoverCoordinates #coordinates, arity
    if leftover > 0
      -- A whole point that completes no segment is what the two part on. libass commits one only in
      -- whole groups and drops the rest. VSFilter holds them in the path. A lone coordinate makes no
      -- point at all, so neither reads it.
      orphaned = leftover >= 2
      defects[#defects + 1] = {
        code: orphaned and FindingCode.DrawingOrphanedPoints or FindingCode.DrawingIncompleteArguments
        values: {name, leftover}
        dialects: orphaned and {DialectName.Libass} or nil
      }
    nodes += math.floor #coordinates / 2

  -- the one place they part on where a drawing begins, which is why it is asked of each of them
  opensForLibassAlone = drawingOpensUnder(commands, DialectName.Libass) and
    not drawingOpensUnder commands, DialectName.XyVsfilter
  if opensForLibassAlone
    defects[#defects + 1] = {
      code: FindingCode.DrawingRootFromOpenMove
      values: {}
      dialects: {DialectName.Libass}
    }

  return defects

---Determines the class of misspelling in a degenerate color or alpha among those rejected by at least
---one of the dialects the dialects refuse was written with, where its shape says.
---Not exhaustive, but based on commonly observed mistakes.
---@param argumentType AssArgumentType What the tag takes.
---@param params string The argument as the line wrote it.
---@return AssFindingCode? code Nil where the shape says nothing the general finding does not.
getColorFinding = (argumentType, params) ->
  return nil unless argumentType == ArgumentType.Color or argumentType == ArgumentType.Alpha
  digits = params\match "^&[Hh](%x+)&$"
  -- ampersands without the shape a literal needs, as `\alpha&20` has, which loses the value outright
  return FindingCode.ColorLiteralMalformed if not digits and params\find "&", 1, true
  return nil unless digits
  return FindingCode.ColorAlphaIgnored if argumentType == ArgumentType.Color and #digits == 8
  return nil

---Reads a line for the tags its dialects do not read as written, and for the forms they refuse.
---
---Every finding names a tag and the bytes it stands on, so acting on one takes no second read of the
---line. A finding naming fewer dialects than were asked is one they part on, which locates a divergence
---at the tag causing it rather than stating it of the whole line.
---@param text string A line's Text field.
---@param findingDialects? AssDialectName[] The dialects to read the line with, both renderers by
---  default. The first is the dialect the line is scanned with.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares. The unknown
---  style check runs only when this is given, since without it every name looks undeclared.
---@param effect? string The line's Effect field. A banner or scroll there switches collision detection
---  off, which decides whether an empty transform is holding the line still on its own.
---@return AssFinding[] findings In the order the tags they name stand in the line, empty for a clean one.
findLineDefects = (text, findingDialects = defaultFindingDialects, stylesByName, effect) ->
  text or= ""
  tokens = Scanner(findingDialects[1])\scan text
  spans = mapTokenSpans tokens
  findings = {}

  record = (code, token, dialectNames, ...) ->
    span = spans[token]
    findings[#findings + 1] = {
      :code
      severity: severityByCodePrefix[code\sub 1, 1]
      message: templateByCode[code]\format ...
      tag: token.kind == TokenKind.Tag and "#{token.name}#{token.params or ''}" or nil
      startIndex: span.startIndex
      endIndex: span.endIndex
      dialects: dialectNames
    }

  everyDialect = [dialect for dialect in *findingDialects]

  -- A block whose content holds no backslash is a comment. Aegisub gives it a block type of its own
  -- and the renderers skip past it, and none of them draws it, so it is an authoring note rather than
  -- a defect. The scan emits it as the block's only token, which is what tells it from the characters
  -- no tag claimed in a block that does hold one.
  commentTokens = {}
  blockContent, holding = nil, 0
  for token in *tokens
    switch token.kind
      when TokenKind.BlockStart
        blockContent, holding = nil, 0
      when TokenKind.BlockEnd
        if holding == 1 and blockContent and not blockContent.text\find Syntax.TagPrefix, 1, true
          commentTokens[blockContent] = true
        blockContent, holding = nil, 0
      when TokenKind.Junk, TokenKind.Comment
        blockContent = token
        holding += 1
      else
        holding += 1

  -- A transform's argument list ends at the first `)`, so a tag inside it that takes a parenthesized
  -- list of its own closes the transform with its own `)`. Everything the author wrote after that tag
  -- lands outside the transform, and the tags between them are reported unclosed as a consequence.
  -- Naming the cause on the transform says what to fix, where the unclosed lists say only what broke,
  -- so those are held back for the tokens this explains.
  explainedFindings = {}
  slotClaimedBy = {}

  -- A `\t` switches collision detection off whether or not it animates anything, so one holding no
  -- tags still decides where the line is drawn. Whether it can be removed turns on what else the line
  -- writes, which is settled here once for the whole line rather than at each transform: `\pos`,
  -- `\move` and `\org` do the same where their arguments are read, as does any transform that animates
  -- something, or a scroll in the Effect field.
  collisionsDisabledBy = nil
  if effect
    lowered = effect\lower!
    collisionsDisabledBy = "The Effect field's scroll" if lowered\match("^%s*banner") or lowered\match("^%s*scroll")

  emptyTransforms = {}
  scanForCollisionState = (list) ->
    for token in *list
      continue unless token.kind == TokenKind.Tag
      if token.name == TagName.Transform
        holdsTag = false
        for child in *(token.children or {})
          holdsTag = true if child.kind == TokenKind.Tag
        if holdsTag
          collisionsDisabledBy or= "Another `\\t`, which does animate something,"
        else emptyTransforms[token] = true
      elseif collisionDisablingTagNames[token.name] and token.arguments
        collisionsDisabledBy or= "`\\#{token.name}`"
      scanForCollisionState token.children if token.children
  scanForCollisionState tokens

  checkTransform = (token) ->
    return unless token.name == TagName.Transform
    if emptyTransforms[token]
      if collisionsDisabledBy
        record FindingCode.TransformEmpty, token, everyDialect, token.name, collisionsDisabledBy
      else record FindingCode.TransformEmptyHoldsCollisions, token, everyDialect, token.name
    return unless token.children
    for child in *token.children
      continue unless child.kind == TokenKind.Tag
      record FindingCode.TransformNested, token, everyDialect, token.name if child.name == TagName.Transform
      continue unless child.form and child.form.parenthesized
      record FindingCode.TransformParenthesizedArgument, child, everyDialect, child.name, token.name
      explainedFindings[child] = true unless child.form.argumentsClosed

  checkTokens = (list, insideArguments) ->
    tagSeen = false
    for token in *list
      if token.kind == TokenKind.Drawing
        for defect in *findDrawingDefects token.commands or {}
          record defect.code, token, defect.dialects or everyDialect, unpack defect.values
        continue
      if token.kind == TokenKind.Junk or token.kind == TokenKind.Comment
        -- A transform's arguments are scanned as an override block, so its timings and their commas
        -- arrive as the junk standing ahead of every tag there. Junk after one is a defect as any is.
        unless insideArguments and not tagSeen
          code = (commentTokens[token] or token.kind == TokenKind.Comment) and
            FindingCode.CommentBlock or FindingCode.JunkInBlock

          -- Each of these describes the whole run, so no two can match one and the first to match is
          -- the finding.
          if token.text\match "^\\+$"
            code = FindingCode.StrayBackslash
          elseif token.text\match "^%*+$"
            -- Asterisks are what unanimated's Colorize marks its own generated blocks with, and both
            -- renderers were observed reading past them wherever they stand, so this is a note rather
            -- than a defect.
            code = FindingCode.BlockMarker
          elseif named = token.text\match "^\\(%w+)"
            -- by prefix, as every renderer matches a tag name, so `\jitter1,2,3` finds `jitter`
            fork = nil
            for name in *sortedVsfilterModTagNames
              if named\sub(1, #name)\lower! == name
                fork = name
                break
            code = fork and FindingCode.VsfilterModTag or FindingCode.UnrecognizedTag

          record code, token, everyDialect, token.text
        continue

      continue unless token.kind == TokenKind.Tag
      tagSeen = true
      params = token.params or ""

      -- Every dialect reads one of these from the line's first instance, so a later one is dead however
      -- far down it stands. Some share a slot with another tag, which is why the earlier one is named
      -- rather than assumed to be this same tag: a `\pos` after a `\move` is dead too.
      -- A tag that matched no signature is not read by any renderer, so it doesn't claim a slot
      -- (e.g. `{\pos}{\pos(300,300)}` is positioned at 300, 300)
      if token.arguments
        if slot = (overrideTags[token.name] or {}).firstWinsSlot
          if claimed = slotClaimedBy[slot]
            record FindingCode.LineTagIgnored, token, everyDialect, token.name, claimed
          else
            slotClaimedBy[slot] = token.name

      if form = token.form
        record FindingCode.WhitespaceInTag, token, everyDialect, token.name if form.whitespaceBeforeName
        if form.parenthesized and not form.argumentsClosed and not explainedFindings[token]
          record FindingCode.UnclosedArgumentList, token, everyDialect, token.name
        -- Characters after a closed argument list reach the renderers as junk of their own, and only
        -- Aegisub keeps them on the tag, so this is the same defect seen through the other scan.
        record FindingCode.JunkInBlock, token, everyDialect, form.trailing if form.trailing

      definition = overrideTags[token.name]
      if definition
        argumentType = definition.signatures[1] and definition.signatures[1][1]

        -- `parse` returns nil where no signature matched and an empty list where a bare tag was
        -- accepted. Whitespace alone trims to nothing and reads as the bare form.
        -- An unparenthesized tag takes the whole run after its name as one argument, so `\b1,2`
        -- matches the signature here and reaches `ValueNotAsWritten` instead.
        if not token.arguments and argumentType != ArgumentType.StyleName
          record FindingCode.UnmatchedSignature, token, everyDialect, token.name

        styleName = token.arguments and token.arguments[1]
        if argumentType == ArgumentType.StyleName and stylesByName and styleName and not stylesByName[styleName]
          record FindingCode.ResetToUnknownStyle, token, everyDialect, styleName

        -- `\fe` is compared by one renderer and not the other, so it moves a syllable boundary in one
        if token.name == TagName.FontEncoding
          comparing = [dialect for dialect in *findingDialects when dialects[dialect].runComparison and
            dialects[dialect].runComparison.comparesCharacterSet]
          if #comparing > 0 and #comparing < #findingDialects
            record FindingCode.CharacterSetNotCompared, token, comparing, token.name, params

        -- group the dialects by the finding each of their readings makes, so a shared one is reported
        -- once naming them all and a divergence falls out as a finding naming only some
        if takesOneReadValue(definition) and not isKaraokeTagName token.name
          byCode, order = {}, {}
          for dialect in *findingDialects
            code, canonical = argumentFindingFor dialect, token
            continue unless code
            key = "#{code}\0#{canonical}"
            unless byCode[key]
              byCode[key] = {:code, :canonical, names: {}}
              order[#order + 1] = byCode[key]
            group = byCode[key].names
            group[#group + 1] = dialect
          for {:code, :canonical, :names} in *order
            spelled = #canonical > 0 and canonical or token.name
            code = getColorFinding(argumentType, params) or code if code == FindingCode.ValueNotAsWritten
            record code, token, names, token.name, params, spelled

      -- ahead of the recursion, so a child's own unclosed list is already accounted for when reached
      checkTransform token
      checkTokens token.children, true if token.children
  checkTokens tokens

  return findings

renderers = {DialectName.Libass, DialectName.XyVsfilter}
libassOnly = {DialectName.Libass}
vsfilterOnly = {DialectName.XyVsfilter}
neither = {}

-- Styles alike but for a border style, which is reachable only through `\r` since no tag writes the
-- field. 2 is a value the format gives no meaning to and both renderers draw as the outline 1 asks for,
-- so one dialect folding it and the other comparing the number is a difference in reading alone. 4 is
-- the one libass draws its own way, as a box behind the whole line, which VSFilter draws as an outline
-- like everything else it does not read as the opaque box.
borderStyles =
  Outlined: {k, v for k, v in pairs defaultStyle}
  Unmeaning: {k, v for k, v in pairs defaultStyle}
  Shadowed: {k, v for k, v in pairs defaultStyle}
borderStyles.Outlined.name, borderStyles.Outlined.borderstyle = "Outlined", 1
borderStyles.Unmeaning.name, borderStyles.Unmeaning.borderstyle = "Unmeaning", 2
borderStyles.Shadowed.name, borderStyles.Shadowed.borderstyle = "Shadowed", BorderStyle.ShadowBox

-- A style declaring bold, which `\r` reaches by name. A refused `\b` puts a style's bold back, and
-- the two renderers read that from different styles once a reset has moved one of them.
weightStyles =
  Regular: {k, v for k, v in pairs defaultStyle}
  Bolded: {k, v for k, v in pairs defaultStyle}
weightStyles.Regular.name = "Regular"
weightStyles.Bolded.name, weightStyles.Bolded.bold = "Bolded", true

---One rewrite a normalizer might make, and the dialects that cannot tell the two forms apart. The
---context is deliberately the same throughout — a karaoke tag, a character, the tag in question,
---another character — so that a row reports the tag's reading and not the shape it was put in.
---@class AssEquivalence
---@field name string
---@field written string The line as it might be found.
---@field rewritten string The line a normalizer would put in its place.
---@field dialects AssDialectName[] Those that read the two alike, so the rewrite is safe for them.
---@field stylesByName? table<string, AegisubStyleLine> Styles the pair reaches by name.
---@field wrapStyle? AssWrapStyle The script's wrap style the pair is read under, for a row that turns on it.
---@field note? string Why the row is worth keeping, where that is not obvious.
equivalences = {
  -- A value outside what a tag accepts puts the style's back, which is what a bare tag does. Both
  -- renderers agree, so these are the rewrites a normalizer can make without asking anything else.
  {name: "weightOutsideItsRange", written: "{\\k50}a{\\b2}b", rewritten: "{\\k50}a{\\b}b", dialects: renderers}
  {name: "weightBelowOneHundred", written: "{\\k50}a{\\b99}b", rewritten: "{\\k50}a{\\b}b", dialects: renderers}
  {name: "negativeFlag", written: "{\\k50}a{\\i-1}b", rewritten: "{\\k50}a{\\i}b", dialects: renderers}
  {name: "flagAboveOne", written: "{\\k50}a{\\i5}b", rewritten: "{\\k50}a{\\i}b", dialects: renderers}
  {name: "fractionalFlag", written: "{\\k50}a{\\u1.5}b", rewritten: "{\\k50}a{\\u1}b", dialects: renderers,
    note: "an argument is read as a whole number, so this switches the underline on rather than being refused"}
  {name: "fontNameZero", written: "{\\k50}a{\\fn0}b", rewritten: "{\\k50}a{\\fn}b", dialects: renderers}

  -- Both renderers hold these at zero or above, so a negative argument is the same as writing zero.
  {name: "negativeBorder", written: "{\\k50}a{\\bord-2}b", rewritten: "{\\k50}a{\\bord0}b", dialects: renderers}
  {name: "negativeBorderAxis", written: "{\\k50}a{\\xbord-2}b", rewritten: "{\\k50}a{\\xbord0}b", dialects: renderers}
  {name: "negativeShadow", written: "{\\k50}a{\\shad-2}b", rewritten: "{\\k50}a{\\shad0}b", dialects: renderers}
  {name: "negativeBlur", written: "{\\k50}a{\\blur-5}b", rewritten: "{\\k50}a{\\blur0}b", dialects: renderers}
  {name: "negativeDrawingScale", written: "{\\k50}a{\\p-1}b", rewritten: "{\\k50}a{\\p0}b", dialects: renderers}
  {name: "zeroSize", written: "{\\k50}a{\\fs0}b", rewritten: "{\\k50}a{\\fs}b", dialects: renderers,
    note: "a size at or below zero puts the style's own back rather than being held at zero"}
  {name: "sizeScaledToZero", written: "{\\k50}a{\\fs-10}b", rewritten: "{\\k50}a{\\fs}b", dialects: renderers,
    note: "a signed size scales the size in force by a tenth of what it names, so -10 lands the scale
      at zero and the restore is what both draw"}

  -- The rewrites that look like the ones above and are not. Each is safe for at most one renderer, so
  -- a normalizer asked to satisfy both has to refuse the line rather than tidy it.
  {name: "negativeShadowAxis", written: "{\\k50}a{\\xshad-2}b", rewritten: "{\\k50}a{\\xshad0}b", dialects: neither,
    note: "the trap of the set: it reads like `\\shad`, and neither renderer clamps it"}
  {name: "fractionalBlurEdges", written: "{\\k50}{\\be1}a{\\be0.6}b", rewritten: "{\\k50}{\\be1}a{\\be1}b", dialects: libassOnly,
    note: "one renderer rounds to a whole pass, and the fraction reaches the other's raster"}
  {name: "negativeBlurEdges", written: "{\\k50}a{\\be-3}b", rewritten: "{\\k50}a{\\be0}b", dialects: libassOnly}
  {name: "explicitWeight", written: "{\\k50}{\\b1}a{\\b700}b", rewritten: "{\\k50}{\\b1}a{\\b1}b", dialects: vsfilterOnly,
    note: "one resolves both spellings to a weight, the other compares the number as written"}
  {name: "refusedWeightAfterReset", written: "{\\k50}a{\\rBolded\\b50}b", rewritten: "{\\k50}a{\\rBolded}b",
    dialects: libassOnly, stylesByName: weightStyles,
    note: "one restores the style the reset put in force, so dropping the refused weight changes nothing;
      the other restores the line's own style and the drop turns the text bold"}
  {name: "shadowBoxBorderStyle", written: "{\\k50}a{\\rShadowed}b", rewritten: "{\\k50}a{\\rOutlined}b",
    dialects: vsfilterOnly, stylesByName: borderStyles,
    note: "the one border style libass draws its own way, which the folding dialect cannot tell from
      the outline it draws for it"}
  {name: "meaninglessBorderStyle", written: "{\\k50}a{\\rUnmeaning}b", rewritten: "{\\k50}a{\\rOutlined}b",
    dialects: vsfilterOnly, stylesByName: borderStyles,
    note: "reachable only through `\\r`, so a style-level divergence is a line-level one too"}
  {name: "outOfRangeWrapStyle", written: "{\\q9}{\\k50}aa\\nbb", rewritten: "{\\q}{\\k50}aa\\nbb",
    dialects: renderers, wrapStyle: WrapStyle.NoWordWrap,
    note: "both renderers put the script's wrap style back for an argument outside the declared four,
      as a bare tag does. The row departs from the shared context because a `\\q` shows only through a
      soft break, and the script has to state the no-wrap style: under any other, restoring and keeping
      the 9 read alike and the row would check nothing"}
}

---Cross-dialect readings of a line, and the rewrites each dialect cannot tell apart. A prototype for
---the diagnostics and normalization layers, which is why nothing requires it yet.
---@class AssDiagnostics
return {
  :describeLine, :describeCanonicalAppearance, :describeKaraokeSyllables, :isEquivalent
  :groupDialectsByKaraokeReading, :equivalences
  :Severity, :FindingCode, :findLineDefects, :mapTokenSpans
}
