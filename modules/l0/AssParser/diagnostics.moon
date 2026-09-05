-- cspell:ignore HAABBGGRR -- the ASS color template, whose letters are its byte order
-- cspell:ignore rnds rndx rndy rndz movevc fsvp -- VSFilterMod-only tags

Enum = require "l0.DependencyControl.Enum"
Scanner = require "l0.AssParser.Scanner"
AssRunState = require "l0.AssParser.RunState"
karaoke = require "l0.AssParser.karaoke"
lineState = require "l0.AssParser.LineState"
{:canonicalArgumentFor, :read, :parseNumber} = require "l0.AssParser.arguments"
{:canonicalizeDrawing, :isDrawn, :countLeftoverCoordinates} = require "l0.AssParser.drawing"
{:emit} = require "l0.AssParser.emitter"
{:BorderStyle, :DEFAULT_STYLE_NAME, :LineField, :WrapStyle, :defaultStyle, :readColorLiteralDigits,
  :resolveStyle} = require "l0.AssParser.ass"
{:ArgumentType, :DialectName, :DrawingCommandName, :RunField, :Syntax, :TagName, :TokenKind,
  :BLUR_LARGEST_RENDERED, :drawingCommands, :dialects, :getArgumentReading, :isKaraokeTagName,
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

-- cspell:ignore fcsx fcsy facx facy -- authors' misspellings, quoted here to be recognized
-- Tag names that are likely a typo and would otherwise be reported as an unknown.
intendedTagByMisspelling = {
  fcsx: TagName.ScaleX
  fcsy: TagName.ScaleY
  facx: TagName.ScaleX
  facy: TagName.ScaleY
}
sortedMisspellings = [name for name in pairs intendedTagByMisspelling]
table.sort sortedMisspellings, (a, b) -> #a > #b

-- Escape sequences that we accept in comment blocks but look like they start override sequences to the parser/dialects.
-- Used to merge junk tokens separated by backslashes into a single comment block.
COMMENT_BLOCK_TEXT_ESCAPE_PATTERN = "#{Syntax.EscapePrefix}[Nnh]"

-- `\t` is left out of the set the whole-line check reads, because it is the tag that check is about:
-- one without tags disables collisions like any other, so counting it here would report every empty
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
---@param tokens AssToken[] The line, scanned under `dialect`.
---@param dialect AssDialectName Whose reading to apply.
---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent. Pass
---  the dialect's own `fallbackStyle` where the script declares no style the line can reach.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@return AssRunState? state Nil for a dialect that compares no runs.
buildState = (tokens, dialect, style, stylesByName) ->
  return nil unless dialects[dialect].runComparison
  state = AssRunState style or defaultStyle, dialect, stylesByName
  for token in *tokens
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
---@param durationMs? integer How long the line is on screen, which a transform without an interval
---  animates across. When not provided, the duration is assumed to be DEFAULT_EVENT_DURATION
---  or 1 second past the furthest end time of any transform on the line, whichever is greater.
---@return integer[] times Ascending, always holding 0.
---@return integer span The span a transform without an interval was taken to animate across, which the run
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

---Serializes a line's appearance under the dialect that read it, represented as a string usable to
---compare two lines for equality.
---@param tokens AssTokenStream The line, scanned. The stream names the dialect it was read under and
---  holds the argument values that dialect read, so scanning the same line under another describes it
---  as that one sees it. Read, never written.
---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent. Pass
---  the dialect's own `fallbackStyle` where the script declares no style the line can reach.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@param durationMs? integer How long the line is on screen, which a transform with a zero or unset end
---  time animates across. When not provided, the duration is assumed to be DEFAULT_EVENT_DURATION
---  or 1 second past the furthest end time of any transform on the line, whichever is greater.
---@param times? integer[] The moments to read the line at, instead of the ones its own transforms ask
---  for. Pass it to compare two lines whose transforms open and close at different moments, which are
---  otherwise described against two different sets of moments and so never match.
---@return string descriptor The line's syllables, each drawing in canonical form, and the appearance
---  every run is drawn in where the dialect compares runs.
describeLine = (tokens, style, stylesByName, wrapStyle, durationMs, times) ->
  dialect = tokens.dialect
  reader = karaoke.Reader dialect
  parts = ["#{span.tag}@#{span.startTime}+#{span.duration}:#{span.text}" for span in *reader\splitSyllables tokens, style, stylesByName, wrapStyle]

  lineLevelState = lineState.readTokens tokens
  for token in *tokens
    continue unless token.kind == TokenKind.Drawing
    drawn = canonicalizeDrawing token.commands or {}, dialect
    -- A drawing this dialect draws no part of is the same picture as no drawing at all.
    parts[#parts + 1] = "<#{drawn}>" if #drawn > 0

  if dialects[dialect].runComparison
    sampled, wholeLineSpan = sampleTimesFor tokens, durationMs
    times or= sampled
    for time in *times
      state = AssRunState style or defaultStyle, dialect, stylesByName, wholeLineSpan
      state.time = time
      parts[#parts + 1] = "@t#{time}"

      -- `applyTag` reports whether it moved a value, and a run whose state has not moved since the last
      -- one formatted describes itself identically, so the descriptor is only rebuilt where something
      -- did move. At a given moment most transforms on a line are outside their own interval and write
      -- nothing, making this the common case.
      recorded, moved = nil, true
      for token in *tokens
        if token.kind == TokenKind.Tag
          moved = true if not isKaraokeTagName(token.name) and state\applyTag token
          continue
        -- The appearance is recorded at each run of text (where the run state changed), so a trailing tag
        -- isn't recorded in the descriptor, which matches its lack of impact on the the line's appearance.
        continue unless token.kind == TokenKind.Text or token.kind == TokenKind.Drawing
        continue unless moved

        held = ["#{field}=#{tostring state.values[field]}" for field in *sortedRunFields when state.values[field] != nil]
        current = "[#{table.concat held, ' '}]"
        moved = false
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
---@param tokens AssToken[] The line, scanned under `dialect`.
---@param dialect AssDialectName Whose reading to apply.
---@param style? AegisubStyleLine The style the line is set in, the format's defaults where absent. Pass
---  the dialect's own `fallbackStyle` where the script declares no style the line can reach.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@return string? descriptor Nil for a dialect that compares no runs.
describeCanonicalAppearance = (tokens, dialect, style, stylesByName) ->
  state = buildState tokens, dialect, style, stylesByName
  return nil unless state

  held = {}
  for field in *comparedByEveryDialect
    value = state\getValue field
    held[#held + 1] = "#{field}=#{tostring value}" if value != nil
  table.concat held, " "

---Checks whether one dialect reads two lines alike, which is what makes rewriting the first into the second
---safe for it.
---@param text string The line as written.
---@param rewritten string The line it would be rewritten to.
---@param dialect AssDialectName Whose reading to apply.
---@param style? AegisubStyleLine The style the line is set in.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@param durationMs? integer How long the line is on screen. When not provided, the duration is assumed to be DEFAULT_EVENT_DURATION
---  or 1 second past the furthest end time of any transform on the line, whichever is greater.
---@return boolean equivalent True where the dialect reads the two alike, so the rewrite is safe for it.
isEquivalent = (text, rewritten, dialect, style, stylesByName, wrapStyle, durationMs) ->
  scanner = Scanner dialect
  describeLine(scanner\scan(text or ""), style, stylesByName, wrapStyle, durationMs) ==
    describeLine scanner\scan(rewritten or ""), style, stylesByName, wrapStyle, durationMs

---Describes the karaoke syllables a dialect reads a line as, with their timings and stripped text. This
---is the one reading of a line that means the same thing in every dialect, which is what makes it the
---reading to compare two of them by. `describeLine` cannot be: it holds the appearance each dialect
---tracks in that dialect's own representation, so libass holding a weight of 0 where VSFilter holds
---400 would part two dialects that agree about everything a viewer could see.
---@param tokens AssToken[] The line, scanned under `dialect`.
---@param dialect AssDialectName Whose reading to apply.
---@param style? AegisubStyleLine The style the line is set in.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@param wrapStyle? AssWrapStyle The script's own, which decides whether `\n` breaks a line.
---@return string descriptor One entry per syllable, holding its tag, timings and stripped text.
describeKaraokeSyllables = (tokens, dialect, style, stylesByName, wrapStyle) ->
  reader = karaoke.Reader dialect
  syllables = reader\toAegisubKaraokeData tokens, style, stylesByName, wrapStyle
  described = ["#{syllables[index].tag}@#{syllables[index].start_time}+#{syllables[index].duration}:#{syllables[index].text_stripped}" for index = 1, #syllables]
  table.concat described, " "

---Groups the dialects that report a line as the same syllables. One group holding all three is the
---ordinary case and the one a diagnostic stays quiet on; any other shape is a divergence in timing.
---
---Only the karaoke syllables are compared, so this is blind to a divergence that changes what is drawn
---without moving a syllable boundary — a fractional `\be` on a line with no karaoke tag, say.
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
    tokens = Scanner(name)\scan text or ""
    descriptor = describeKaraokeSyllables tokens, name, style, stylesByName, wrapStyle
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

---Every finding that can be reported, each prefixed by its severity.
---@alias AssFindingCode
---| "W-RESET-UNKNOWN-STYLE" # ResetToUnknownStyle: a `\r` names a style the script does not declare
---| "W-LINE-UNKNOWN-STYLE" # LineInUnknownStyle: the line's style field names a style the script does not declare
---| "I-STYLE-NAME-FOLDED" # StyleNameFolded: the line's style field spells `Default` in another case, which still reaches it
---| "W-STYLE-NAME-AMBIGUOUS" # StyleNameAmbiguous: the script declares `Default` in two different cases, and only the exact one is ever reached
---| "W-WHITESPACE-IN-TAG" # WhitespaceInTag: whitespace stands between a tag's backslash and its name
---| "W-UNCLOSED-ARGUMENT-LIST" # UnclosedArgumentList: a parenthesized argument list is never closed
---| "W-LINE-TAG-IGNORED" # LineTagIgnored: a second tag of a kind only the line's first is read from
---| "I-BLOCK-MARKER" # BlockMarker: asterisks an automation script marks its own blocks with
---| "W-STRAY-BACKSLASH" # StrayBackslash: a backslash that names no tag at all
---| "W-UNRECOGNIZED-TAG" # UnrecognizedTag: a backslash and a name no dialect knows as a tag
---| "W-VSFILTERMOD-TAG" # VsfilterModTag: a tag only VSFilterMod implements
---| "W-COLOR-LITERAL-MALFORMED" # ColorLiteralMalformed: a color or alpha written without the `&H…&` a literal needs
---| "W-COLOR-ALPHA-IGNORED" # ColorAlphaIgnored: a style's eight-digit color in a tag that reads six
---| "W-TRANSFORM-NESTED" # TransformNested: a transform inside a transform, which replaces its interval
---| "W-TRANSFORM-PARENTHESIZED-ARGUMENT" # TransformParenthesizedArgument: a parenthesized tag inside a transform ends its argument list early
---| "W-TRANSFORM-EMPTY" # TransformEmpty: a transform with no tags, on a line whose collision detection something else already switches off
---| "W-TRANSFORM-EMPTY-HOLDS-COLLISIONS" # TransformEmptyHoldsCollisions: a transform without tags, and
---  the only thing switching the line's collision detection off
---| "E-UNMATCHED-SIGNATURE" # UnmatchedSignature: a form matching no signature the tag declares, whether
---  the argument count is wrong or a complex tag was written without parentheses
---| "W-CLIP-EMPTY" # ClipEmpty: a clip written with an empty argument list, which every renderer draws as though the tag were absent
---| "W-TAG-MISSPELLED" # MisspelledTag: an unknown tag name that is likely a typo of a known tag
---| "W-ARGUMENT-REFUSED" # ArgumentRefused: the argument is refused, so the tag acts as its bare form
---| "W-VALUE-RESTORES-STYLE" # ValueRestoresStyle: a value at or below zero puts the style's own back
---| "W-VALUE-CLAMPED" # ValueClamped: the value falls outside the range read and is taken as the bound
---| "W-TRANSFORM-PAST-BOUND" # TransformAnimatesPastBound: a transform animates toward a value outside
---  the range read, and the interpolation toward it is not clamped, so the value is clamped only once it
---  is drawn
---| "W-VALUE-ROUNDED" # ValueRounded: a fraction is read as a whole number
---| "W-VALUE-NOT-AS-WRITTEN" # ValueNotAsWritten: the value read differs from the one written, otherwise
---| "W-CHARACTER-SET-NOT-COMPARED" # CharacterSetNotCompared: `\fe` ends a run in one dialect and not another
---| "E-BLUR-EXHAUSTS-RENDERER" # BlurExhaustsRenderer: a blur whose overlay xy-VSFilter aborts trying to build
---| "W-JUNK-IN-BLOCK" # JunkInBlock: characters beside a tag that read as no tag
---| "I-COMMENT-BLOCK" # CommentBlock: an override block without any tag, ignored by renderers, and used for inline comments by script authors
---| "E-DRAWING-REJECTED" # DrawingRejected: nothing opens the drawing, so no renderer draws any of it
---| "W-DRAWING-UNRECOGNIZED-TOKEN" # DrawingUnrecognizedToken: a word that is neither a command nor a coordinate
---| "W-DRAWING-INCOMPLETE-ARGUMENTS" # DrawingIncompleteArguments: a command left with coordinates too few to use
---| "W-DRAWING-ORPHANED-POINTS" # DrawingOrphanedPoints: whole points that do not complete a curve's batch
---| "W-DRAWING-ROOT-FROM-OPEN-MOVE" # DrawingRootFromOpenMove: an open move stands in for a move that took no point
---| "W-DRAWING-EXTENSION-WITHOUT-NODES" # DrawingExtensionWithoutNodes: a command with fewer nodes before
---  it than it needs, which a spline needing three of them and any command before the first move both do
---| "E-KARAOKE-TEMPLATE-SYNTAX" # KaraokeTemplateSyntax: the line is a karaoke templater's source, whose text is expanded before any renderer sees it
FindingCode = Enum "AssFindingCode", {
  ResetToUnknownStyle: "W-RESET-UNKNOWN-STYLE"
  LineInUnknownStyle: "W-LINE-UNKNOWN-STYLE"
  StyleNameFolded: "I-STYLE-NAME-FOLDED"
  StyleNameAmbiguous: "W-STYLE-NAME-AMBIGUOUS"
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
  ClipEmpty: "W-CLIP-EMPTY"
  MisspelledTag: "W-TAG-MISSPELLED"
  ArgumentRefused: "W-ARGUMENT-REFUSED"
  ValueRestoresStyle: "W-VALUE-RESTORES-STYLE"
  ValueClamped: "W-VALUE-CLAMPED"
  TransformAnimatesPastBound: "W-TRANSFORM-PAST-BOUND"
  ValueRounded: "W-VALUE-ROUNDED"
  ValueNotAsWritten: "W-VALUE-NOT-AS-WRITTEN"
  CharacterSetNotCompared: "W-CHARACTER-SET-NOT-COMPARED"
  BlurExhaustsRenderer: "E-BLUR-EXHAUSTS-RENDERER"
  JunkInBlock: "W-JUNK-IN-BLOCK"
  CommentBlock: "I-COMMENT-BLOCK"
  DrawingRejected: "E-DRAWING-REJECTED"
  DrawingUnrecognizedToken: "W-DRAWING-UNRECOGNIZED-TOKEN"
  DrawingIncompleteArguments: "W-DRAWING-INCOMPLETE-ARGUMENTS"
  DrawingOrphanedPoints: "W-DRAWING-ORPHANED-POINTS"
  DrawingRootFromOpenMove: "W-DRAWING-ROOT-FROM-OPEN-MOVE"
  DrawingExtensionWithoutNodes: "W-DRAWING-EXTENSION-WITHOUT-NODES"
  KaraokeTemplateSyntax: "E-KARAOKE-TEMPLATE-SYNTAX"
}

-- The first word of the Effect fields a templater marks its own lines with, as in `template syl` and
-- `code once`.
karaokeTemplateEffects = {template: true, code: true}

-- The substitutions a templater writes into a line's text: a variable as `$start`, and an expression
-- as `!line.duration!` or `!star[math.random(3)]!`. A bare `!` and an expression holding an operator,
-- as `!line.left + 10!` does, are left out to avoid false positives on dialogue: `Stop! Wait!` would
-- otherwise match.
karaokeTemplateTextPatterns = {"%$%a[%w_]*", "![%a_%$][%w_%.%$]*[%(%)%[%]%w_%.%$,\"' ]*!"}

---Determines whether a line is a karaoke templater's source that inadvertently became an active dialogue
---line in the final script.
---Performs pattern matching against both the Effect field and the line's text for karaoke templater syntax.
---@param text? string A line's Text field.
---@param effect? string A line's Effect field.
---@return boolean isSource
---@return string? matched What said so, for a message to quote. Nil where nothing did.
isKaraokeTemplateSource = (text, effect) ->
  if effect
    word = effect\lower!\match "^%s*(%a+)"
    return true, effect\match "^%s*(.-)%s*$" if karaokeTemplateEffects[word]
  return false, nil unless text
  for pattern in *karaokeTemplateTextPatterns
    matched = text\match pattern
    return true, matched if matched
  false, nil

severityByCodePrefix = {
  E: Severity.Error
  W: Severity.Warning
  I: Severity.Info
}

---@type table<AssFindingCode, string>
templateByCode = {
  [FindingCode.ResetToUnknownStyle]: "`\\r%s` names no style the script declares, so the line's own style comes back."
  [FindingCode.LineInUnknownStyle]: "The line uses style `%s`, which reaches no declaration in the script, so it is drawn in `%s`."
  [FindingCode.StyleNameFolded]: "The line uses style `%s`, which is read as `Default` and reaches the style declared under that name."
  [FindingCode.StyleNameAmbiguous]: "The line uses style `%s`, which is read as `Default`, so it reaches that style and never the `%s` the script also declares."
  [FindingCode.WhitespaceInTag]: "Whitespace stands between the backslash and the name of `\\%s`."
  [FindingCode.UnclosedArgumentList]: "`\\%s` opens an argument list it never closes."
  [FindingCode.BlockMarker]: "`%s` marks the block as one an automation script generated. Every dialect ignores it."
  [FindingCode.StrayBackslash]: "`%s` names no tag, so every dialect reads past it."
  [FindingCode.UnrecognizedTag]: "`%s` names no tag any dialect knows, so every one of them reads past it and it draws nothing."
  [FindingCode.MisspelledTag]: "`%s` is not a known tag and therefore ignored, but looks like a typo of `\\%s`."
  [FindingCode.VsfilterModTag]: "`%s` names a tag only VSFilterMod implements. Aegisub, libass and xy-VSFilter all read past it, so the line draws as its author meant only in that fork."
  [FindingCode.ColorLiteralMalformed]: "`\\%s%s` is not a well-formed literal, so it is read as %s and the value written is lost. A color or alpha needs its `&H` and its closing `&`."
  [FindingCode.ColorAlphaIgnored]: "`\\%s%s` states the eight digits of a style's `&HAABBGGRR&`, where a color tag reads the six of `&HBBGGRR&`, so it is read as %s and the alpha is dropped."
  [FindingCode.LineTagIgnored]: "`\\%s` does nothing, since `\\%s` earlier in the line already set it and only the first of them is read."
  [FindingCode.TransformNested]: "`\\%s` holds another `\\t`, whose own interval replaces this one for the tags after it. A transform cannot animate a transform; write the two side by side instead."
  [FindingCode.TransformParenthesizedArgument]: "`\\%s` inside `\\%s` takes a parenthesized argument list, and its `)` closes the transform. Everything written after it lands outside the transform."
  [FindingCode.TransformEmpty]: "`\\%s` holds no tags and animates nothing. %s already switches this line's collision detection off, so the transform can be removed without moving the line."
  [FindingCode.TransformEmptyHoldsCollisions]: "`\\%s` holds no tags and animates nothing, but a `\\t` switches collision detection off whether or not it animates anything, and this line has nothing else that does. Removing it would let the line be pushed aside to clear another, so keep it or write a `\\pos`."
  [FindingCode.UnmatchedSignature]: "`\\%s` is written in a form that matches no signature it declares."
  [FindingCode.ClipEmpty]: "`\\%s()` is empty and has no effect. Likely an artifact of deleting the last control point in the Aegisub visual clip editor."
  [FindingCode.ArgumentRefused]: "`\\%s%s` is refused, so the tag acts as the bare `\\%s`."
  [FindingCode.ValueRestoresStyle]: "`\\%s%s` lands at or below zero, so the style's own value comes back."
  [FindingCode.ValueClamped]: "`\\%s%s` falls outside the range read, and is taken as %s."
  [FindingCode.TransformAnimatesPastBound]: "`\\%s%s` animates toward a value outside the range read. The interpolation is not clamped, so the value moves at the rate that target sets, reaches %s partway through the window, and is clamped there for the remainder."
  [FindingCode.ValueRounded]: "`\\%s%s` is read as the whole number %s."
  [FindingCode.ValueNotAsWritten]: "`\\%s%s` is not read as written, but as %s."
  [FindingCode.CharacterSetNotCompared]: "`\\%s%s` ends a run of text in some dialects and not others, which moves a karaoke syllable boundary."
  [FindingCode.KaraokeTemplateSyntax]: "`%s` makes this a karaoke template, which the templater expands into the lines that are drawn. Its text is read as written by nothing, so it is left alone."
  [FindingCode.BlurExhaustsRenderer]: "`\\%s%s` asks xy-VSFilter for an overlay whose memory grows with the square of the radius, and it aborts rather than drawing the line at all. libass holds a blur to 100, so writing this one at most #{BLUR_LARGEST_RENDERED} draws the same there and draws at all here."
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
---@field field AegisubLineField Which field of the line the finding is about. `text` for everything the
---  scan turns up, `style` for the checks on the style the line uses.
---@field tag? string The tag as the line wrote it, name and parameters, without the backslash. Absent
---  if the finding is about stray characters that are no tag at all.
---@field startIndex? integer 1-based first byte of the tag in the line. Absent unless `field` is `text`.
---@field endIndex? integer 1-based last byte, inclusive. Absent unless `field` is `text`.
---@field dialects AssDialectName[] The dialects that read the tag this way, in the order asked. A
---  finding that lists every dialect asked is one they agree on; a shorter list is itself a divergence.

---Maps every token of an unedited stream, nested children included, to the byte range it was read from.
---The ranges are derived by emitting the tokens, which reproduces the source byte for byte as long as
---nothing in the stream has been edited.
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

---Checks whether a tag takes exactly one argument that a dialect's reading applies to, which is what the
---argument findings are derived from.
---@param definition AssTagDefinition The tag's entry of the tag table.
---@return boolean
takesOneReadValue = (definition) ->
  signature = definition.signatures[1]
  signature != nil and #signature == 1 and not valuelessArgumentTypes[signature[1]]

---Returns the finding a dialect's reading of one tag's argument makes, where it does not read it as written.
---The constraint that moved the value is what names the finding, so a clamp, a rounding and a refusal
---are told apart rather than reported as one.
---@param token AssToken The tag to read.
---@param dialect AssDialectName Whose reading to apply.
---@return AssFindingCode? code Nil where the dialect reads the argument exactly as it is written.
---@return string? canonical The canonical form of what the dialect reads it as.
argumentFindingFor = (token, dialect) ->
  canonical = canonicalArgumentFor token, dialect
  return nil unless canonical

  return FindingCode.ArgumentRefused, canonical if canonical == ""

  reading = getArgumentReading token.name, dialect
  value = read token.params, dialect, token.name, nil != (token.form and token.form.parenthesized)
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
  return {{code: FindingCode.DrawingRejected, values: {}}} unless isDrawn commands

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

    -- A command with no coordinate at all is inert, and where a word it could not read is what
    -- left it so, that word is already reported. Only a command with some but too few is reported.
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
  opensForLibassAlone = isDrawn(commands, DialectName.Libass) and
    not isDrawn commands, DialectName.XyVsfilter
  if opensForLibassAlone
    defects[#defects + 1] = {
      code: FindingCode.DrawingRootFromOpenMove
      values: {}
      dialects: {DialectName.Libass}
    }

  return defects

---Determines which finding a malformed color or alpha literal earns, from the shape of what was written.
---Not exhaustive, but based on commonly observed mistakes.
---@param argumentType AssArgumentType What the tag takes.
---@param params string The argument as the line wrote it.
---@return AssFindingCode? code Nil where the shape says nothing the general finding does not.
getColorFinding = (argumentType, params) ->
  return nil unless argumentType == ArgumentType.Color or argumentType == ArgumentType.Alpha
  digits = readColorLiteralDigits params
  -- ampersands without the shape a literal needs, as `\alpha&20` has, which loses the value outright
  return FindingCode.ColorLiteralMalformed if not digits and params\find "&", 1, true
  return nil unless digits
  return FindingCode.ColorAlphaIgnored if argumentType == ArgumentType.Color and #digits == 8
  return nil

---Finds override blocks without tags in the given token stream. These sequences are universally understood
---as comment blocks by ASS script authors, but while they are inert in all dialects, only Aegisub actually
---recognizes them as such. However, escape sequences (`\N`, `\n`, `\h`) within these blocks look like they
---start tag sequences to all dialects, causing the scanner to break a comment sequence and tokenize them
---to junk.
---With the help of this function the normalizer merges tokens semantically belonging to one comment block
---into a single comment block token, making the stream much easier to work with.
---
---@param tokens AssToken[] The line, scanned.
---@return table<AssToken, true> commentTokens The run each comment block is reported against, which is
---  the first in that block.
---@return table<AssToken, string> commentText What each of those blocks holds, joined, so the finding
---  can quote the whole comment and not just the run it is keyed to.
---@return table<AssToken, true> runsInsideComment Every other run of a comment block, which is reported
---  on neither as prose nor as a defect.
findCommentBlocks = (tokens) ->
  commentTokens, commentText, runsInsideComment = {}, {}, {}
  blockTokens = nil
  for token in *tokens
    switch token.kind
      when TokenKind.BlockStart
        blockTokens = {}
      when TokenKind.BlockEnd
        if blockTokens and #blockTokens > 0
          holdsTag = false
          holdsTag = true for t in *blockTokens when t.kind == TokenKind.Tag
          joined = table.concat [t.text or "" for t in *blockTokens]
          withoutTextEscapes = joined\gsub COMMENT_BLOCK_TEXT_ESCAPE_PATTERN, ""
          unless holdsTag or withoutTextEscapes\find Syntax.TagPrefix, 1, true
            commentTokens[blockTokens[1]] = true
            commentText[blockTokens[1]] = joined
            runsInsideComment[blockTokens[index]] = true for index = 2, #blockTokens
        blockTokens = nil
      else
        blockTokens[#blockTokens + 1] = token if blockTokens
  return commentTokens, commentText, runsInsideComment

---Reads a line for the tags its dialects do not read as written, and for the forms they refuse.
---
---Every finding names a tag and the bytes it stands on, so acting on one takes no second read of the
---line. A finding that lists fewer dialects than were asked is one they part on, which locates a divergence
---at the tag causing it rather than stating it of the whole line.
---@param line string|AegisubDialogueLine The line to read, or just its text. Given only the text,
---  nothing is reported about the style the line is set in or about its being a karaoke template, as both
---  of those require additional line fields to be read.
---@param findingDialects? AssDialectName[] The dialects to read the line with, both renderers by
---  default. The first is the dialect the line is scanned with.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares. The unknown
---  style check runs only when this is given, since without it every name looks undeclared.
---@return AssFinding[] findings In the order the tags they name stand in the line, empty for a clean one.
findLineDefects = (line, findingDialects = defaultFindingDialects, stylesByName) ->
  text, styleName, effect = line, nil, nil
  unless "string" == type line
    text, styleName, effect = line and line.text, line and line.style, line and line.effect
  text or= ""
  scanner = Scanner findingDialects[1]
  tokens = scanner\scan text
  spans = mapTokenSpans tokens
  findings = {}

  recordForField = (code, field, dialectNames, ...) ->
    findings[#findings + 1] = {
      :code
      :field
      severity: severityByCodePrefix[code\sub 1, 1]
      message: templateByCode[code]\format ...
      dialects: dialectNames
    }
    findings[#findings]

  record = (code, token, dialectNames, ...) ->
    span = spans[token]
    with recordForField code, LineField.Text, dialectNames, ...
      .tag = token.kind == TokenKind.Tag and "#{token.name}#{token.params or ''}" or nil
      .startIndex = span.startIndex
      .endIndex = span.endIndex

  everyDialect = [dialect for dialect in *findingDialects]

  -- A template's text is a program the templater runs, and the lines it writes are what a renderer is
  -- given. Reading it as ASS reports the substitution markers as defects and every tag around them as
  -- read wrong, so the whole line is reported once and the tag checks below never run on it.
  isTemplate, declaredBy = isKaraokeTemplateSource text, effect
  if isTemplate
    findings[1] = {
      code: FindingCode.KaraokeTemplateSyntax
      field: LineField.Text
      severity: severityByCodePrefix.E
      message: templateByCode[FindingCode.KaraokeTemplateSyntax]\format declaredBy
      startIndex: 1
      endIndex: #text
      dialects: everyDialect
    }
    return findings

  if stylesByName and styleName != nil
    _, declaredStyleName, declarationFound = resolveStyle stylesByName, styleName
    recordForField FindingCode.LineInUnknownStyle, LineField.Style, everyDialect,
      tostring(styleName), declaredStyleName unless declarationFound

    lineStyleName = tostring styleName
    if declarationFound and lineStyleName != DEFAULT_STYLE_NAME and lineStyleName\lower! == "default"
      unreachableStyleName = nil
      for name in pairs stylesByName
        continue unless "string" == type(name) and name != DEFAULT_STYLE_NAME
        unreachableStyleName = name if name\lower! == "default"
      if unreachableStyleName
        recordForField FindingCode.StyleNameAmbiguous, LineField.Style, everyDialect, lineStyleName,
          unreachableStyleName
      else recordForField FindingCode.StyleNameFolded, LineField.Style, everyDialect, lineStyleName

  commentTokens, commentBlockText, tokensInsideComment = findCommentBlocks tokens

  -- A transform's argument list ends at the first `)`, so a tag inside it that takes a parenthesized
  -- list of its own closes the transform with its own `)`. Everything the author wrote after that tag
  -- lands outside the transform, and the tags between them are reported unclosed as a consequence.
  -- Naming the cause on the transform says what to fix, where the unclosed lists say only what broke,
  -- so those are held back for the tokens this explains.
  explainedFindings = {}
  slotClaimedBy = {}

  -- A `\t` switches collision detection off whether or not it animates anything, so one with no
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
        continue if tokensInsideComment[token]
        -- A transform's arguments are scanned as an override block, so its timings and their commas
        -- arrive as the junk standing ahead of every tag there. Junk after one is a defect as any is.
        unless insideArguments and not tagSeen
          code = (commentTokens[token] or token.kind == TokenKind.Comment) and
            FindingCode.CommentBlock or FindingCode.JunkInBlock
          intendedTag = nil

          -- Each of these describes the whole run, so no two can match one and the first to match is
          -- the finding.
          if token.text\match "^\\+$"
            code = FindingCode.StrayBackslash
          elseif token.text\match "^%*+$"
            -- Asterisks are what unanimated's Colorize marks its own generated blocks with, and both
            -- renderers were observed reading past them wherever they stand, so this is a note rather
            -- than a defect.
            code = FindingCode.BlockMarker

          elseif code != FindingCode.CommentBlock
            if undeclared = scanner\detectUnknownTag token.text
              lowered = undeclared\lower!
              -- by prefix, as every renderer matches a tag name, so `\jitter1,2,3` finds `jitter`
              fork = nil
              for name in *sortedVsfilterModTagNames
                if lowered\sub(1, #name) == name
                  fork = name
                  break
              intendedTag = nil
              for misspelling in *sortedMisspellings
                if lowered\sub(1, #misspelling) == misspelling
                  intendedTag = intendedTagByMisspelling[misspelling]
                  break
              code = fork and FindingCode.VsfilterModTag or
                intendedTag and FindingCode.MisspelledTag or FindingCode.UnrecognizedTag

          if intendedTag and code == FindingCode.MisspelledTag
            record code, token, everyDialect, token.text, intendedTag
          else
            record code, token, everyDialect, commentBlockText[token] or token.text
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
        -- Characters after a closed argument list are read by the renderers as junk of their own, and only
        -- Aegisub keeps them on the tag, so this is the same defect seen through the other scan.
        record FindingCode.JunkInBlock, token, everyDialect, form.trailing if form.trailing

      definition = overrideTags[token.name]
      if definition
        argumentType = definition.signatures[1] and definition.signatures[1][1]

        -- `parse` returns nil where no signature matched and an empty list where a bare tag was
        -- accepted. Whitespace alone trims to nothing and reads as the bare form.
        -- An unparenthesized tag takes the whole run after its name as one argument, so `\b1,2`
        -- matches the signature here and is reported as `ValueNotAsWritten` instead.
        if not token.arguments and argumentType != ArgumentType.StyleName
          isEmptyClip = (token.name == TagName.Clip or token.name == TagName.InverseClip) and
            token.form and token.form.parenthesized and token.form.argumentsClosed and
            (token.params or "")\match("^%s*$") != nil
          record isEmptyClip and FindingCode.ClipEmpty or FindingCode.UnmatchedSignature,
            token, everyDialect, token.name

        styleName = token.arguments and token.arguments[1]
        if argumentType == ArgumentType.StyleName and stylesByName and styleName and not stylesByName[styleName]
          record FindingCode.ResetToUnknownStyle, token, everyDialect, styleName

        -- The radius as written, since VSFilter's own reading is held to the largest it draws and so
        -- never reports one above it. A NaN is greater than nothing, and draws as no ink rather than
        -- taking the renderer down, so it is left to the readings to part over.
        if token.name == TagName.Blur and parseNumber(token.params) > BLUR_LARGEST_RENDERED
          aborting = [dialect for dialect in *findingDialects when dialect == DialectName.XyVsfilter]
          record FindingCode.BlurExhaustsRenderer, token, aborting, token.name, params if #aborting > 0

        -- `\fe` is compared by one renderer and not the other, so it moves a syllable boundary in one
        if token.name == TagName.FontEncoding
          comparing = [dialect for dialect in *findingDialects when dialects[dialect].runComparison and
            dialects[dialect].runComparison.comparesCharacterSet]
          if #comparing > 0 and #comparing < #findingDialects
            record FindingCode.CharacterSetNotCompared, token, comparing, token.name, params

        -- group the dialects by the finding each of their readings makes, so a shared one is reported
        -- once listing them all, and a divergence falls out as a finding listing only some
        if takesOneReadValue(definition) and not isKaraokeTagName token.name
          byCode, order = {}, {}
          for dialect in *findingDialects
            code, canonical = argumentFindingFor token, dialect
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
            code = FindingCode.TransformAnimatesPastBound if code == FindingCode.ValueClamped and insideArguments
            record code, token, names, token.name, params, spelled

      -- ahead of the recursion, so a child's own unclosed list is already accounted for when reached
      checkTransform token
      checkTokens token.children, true if token.children
  checkTokens tokens

  return findings

---Derives a line's appearance under each supported dialect, and reports the values a dialect reads
---differently from the way the line writes them.
---
---Checks the line's tag and block structure, its tag arguments, its drawings, its transforms, karaoke,
---styled text runs and style references as well as global state against a collection of known defects
---encountered in the wild.
---Each defect is located in the line, graded by severity, and indicates whether all dialects read it
---that way or diverge.
---
---Do note that this relies entirely on this parser's ASS model and does *not* render the line. As a
---consequence, it cannot detect renderer divergences that only affect font matching, layout, shaping,
---compositing or rasterization, and it is blind to bugs and limitations of this implementation.
---
---Used by the normalizer to check whether a proposed rewrite retains the original appearance of the line.
---@class AssDiagnostics
return {
  :describeLine, :describeCanonicalAppearance, :describeKaraokeSyllables, :isEquivalent
  :groupDialectsByKaraokeReading, :sampleTimesFor
  :Severity, :FindingCode, :findLineDefects, :mapTokenSpans, :isKaraokeTemplateSource
  :findCommentBlocks
}
