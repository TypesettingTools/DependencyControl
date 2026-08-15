-- The normalizer rectifies rather than simplifies. A tag whose argument reads at face value is kept
-- byte for byte however redundant it sits beside its neighbors, because authored tags are input to
-- later transformations and their layout can carry structure no renderer sees; a cleaner that merges
-- and drops them belongs after authoring, the way `l0.ASSWipe` is run over finished lines, and none
-- of that is attempted here. What is rewritten is a spelling the dialects read as something other than
-- what it says — a refused value that acts as the bare tag, a negative a renderer holds at zero, a
-- fraction that becomes a whole count of passes — and each becomes the spelling of what it means, so
-- a script reading the result at face value reads it as the renderers do.
--
-- Every rewrite is derived and then checked. The canonical spelling comes from the same reading the
-- run state applies to a tag, and it is kept only where every target dialect reads the rewritten
-- line exactly as it read the original. The check shares its model with the derivation, so what it
-- actually guards is the machinery in between — the spelling, the emission, the interplay with
-- karaoke tags — while the model itself is pinned by the probe-backed equivalences in `diagnostics`.

Enum = require "l0.DependencyControl.Enum"
Scanner = require "l0.AssParser.Scanner"
diagnostics = require "l0.AssParser.diagnostics"
{:canonicalizeDrawing, :readDrawing} = require "l0.AssParser.drawing"
{:emit, :emitTag} = require "l0.AssParser.emit"
AssRunState = require "l0.AssParser.RunState"
{:canonicalArgumentFor, :emitSingleArgument} = require "l0.AssParser.arguments"
{:defaultStyle} = require "l0.AssParser.ass"
{:DialectName, :TagName, :TokenKind, :TransformBehavior, :dialects, :overrideTags,
  :isKaraokeTagName} = require "l0.AssParser.dialects"

msgs = {
  normalizeLine: {
    referenceOutsideTargets: "Reference dialect '%s' must be one of the targets."
  }
}

-- Aegisub draws nothing, so a rewrite is held to the two dialects that do
defaultTargets = {DialectName.Libass, DialectName.XyVsfilter}

-- Walked once per tag of every transform the lifting pass visits, so a set is worth the line.
appliedWholeTagNames = {}
for name, definition in pairs overrideTags
  appliedWholeTagNames[name] = true if definition.transform == TransformBehavior.AppliedWhole

---One tag a canonical spelling exists for that could not be applied, because the targets disagree
---about whether it would change anything.
---@alias AssNormalizeChangeKind string
---| "tag" # Tag: an override tag whose argument was rewritten
---| "drawing" # Drawing: a drawing rewritten or taken out
ChangeKind = Enum "AssNormalizeChangeKind", {
  Tag: "tag"
  Drawing: "drawing"
}

---Details on a rewrite the normalizer performed for reporting and diagnostics purposes.
---@class AssNormalizeChange
---@field kind AssNormalizeChangeKind Whether a tag or a drawing was rewritten.
---@field before string What the line held, a tag with its argument or a drawing's text.
---@field after string What it now holds, empty for a drawing taken out.
---@field startIndex integer 1-based first byte of `before` in the line as it arrived.
---@field endIndex integer 1-based last byte, inclusive.
---@field converged? AssDialectName[] The targets that accepted this only by following the reference,
---  so each of them draws the line differently after it. Absent where every target read it alike
---  already, which is the ordinary case and the one that changes no picture anywhere.

---What a line is normalized against. Every field is optional, and the defaults answer for a line read
---on its own: both renderers as targets, the format's own style, no reference to converge on.
---@class AssNormalizeOptions
---@field targets? AssDialectName[] The dialects the result has to satisfy, both renderers by default.
---@field style? AegisubStyleLine The style the line is set in.
---@field stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@field wrapStyle? AssWrapStyle The script's own. A line holding `\n` splits differently under
---  different wrap styles, and above the declared four the two renderers split it differently from one
---  another, so a rewrite checked under the wrong one can be accepted where it does not hold.
---@field referenceDialect? AssDialectName The dialect the line was authored against and must be one of the
---  targets. When set, the normalizer may make changes that converge readings under other dialects
---  on the reference, where the original line read differently between them. When unset, only changes
---  that every target reads the same as the original are applied.
---@field durationMs? integer How long the line is on screen, which is what a transform naming no interval
---  animates across. Pass it where the line's timings are to hand: without it such a transform is read
---  as animating across a span standing in for the event, and a rewrite that changes what one animates
---  past that span can be accepted where it does not hold.

---@class AssNormalizeDivergence
---@field tag string The tag as the line wrote it, with its argument.
---@field rewritten string The canonical spelling that was refused.
---@field accepting AssDialectName[] The targets the rewrite held for — reading the two alike, or
---  following the reference where one was named. Always a proper subset of the targets.

---Every tag in a stream, the ones nested in a transform's arguments included, each with the transforms
---it sits inside from the outermost in.
---@param tokens AssToken[] A stream as a scan returns it.
---@return fun(): AssToken?, AssToken[]? iterator The tag, and the transforms holding it.
iterateTags = (tokens) ->
  stack = {{siblings: tokens, index: 1, transforms: {}}}
  ->
    while #stack > 0
      frame = stack[#stack]
      token = frame.siblings[frame.index]
      unless token
        stack[#stack] = nil
        continue

      frame.index += 1
      continue unless token.kind == TokenKind.Tag

      if token.children
        transforms = [transform for transform in *frame.transforms]
        transforms[#transforms + 1] = token
        stack[#stack + 1] = {siblings: token.children, index: 1, :transforms}

      return token, frame.transforms
    nil

---Regenerates each transform's raw parameters from its parsed children, so that any edits to nested
---tags are picked up when emitting the parent tag. Starts from the back to ensure nested children
---are updated before their parents.
---@param transforms AssToken[] The transforms the edited tag sits inside, outermost first.
regenerateTransformArguments = (transforms) ->
  for index = #transforms, 1, -1
    transforms[index].params = emit transforms[index].children

---Moves a tag its transform does not interpolate out of it, to stand just before it.
---
---Standing before the transform keeps the tag's order against everything written outside it, and
---changes its order against the tags left inside. That can change what the line does: a `\r` moved out
---from behind an interpolated tag no longer resets what that tag wrote.
---@param siblings AssToken[] The tokens the transform sits among, which the moved tag joins just before it.
---@param refused table<AssToken, true> Tags already tried and refused, so one of them stops nothing else.
---@return AssToken? transform The transform the tag came out of.
---@return AssToken? liftedTag The tag moved out of the transform and before it.
---@return fun()? undo Puts the tokens back as they were, for a move the targets do not accept.
liftAppliedWholeTagOutOfTransform = (siblings, refused) ->
  for index = 1, #siblings
    token = siblings[index]
    continue unless token.kind == TokenKind.Tag and token.name == TagName.Transform
    children = token.children or {}

    childIndex = nil
    for i = 1, #children
      child = children[i]
      if child.kind == TokenKind.Tag and appliedWholeTagNames[child.name] and not refused[child]
        childIndex = i
        break
    continue unless childIndex

    liftedTag = children[childIndex]
    retainedTags = [children[i] for i = 1, #children when i != childIndex]
    wasClosed = liftedTag.form and liftedTag.form.argumentsClosed

    undo = ->
      table.remove siblings, index
      token.children = children
      token.params = emit children
      liftedTag.form.argumentsClosed = wasClosed if liftedTag.form

    token.children = retainedTags
    token.params = emit retainedTags
    -- Both renderers end a transform's argument list at the first `)`, stealing it from a multi-argument tag
    -- inside (e.g. `\t(0,500,\fad(0,100))`). Once moved out, the tag needs its own closing parenthesis, so
    -- it does not run on into what follows.
    liftedTag.form.argumentsClosed = true if liftedTag.form
    table.insert siblings, index, liftedTag
    return token, liftedTag, undo

  for token in *siblings
    continue unless token.children
    transform, liftedTag, undo = liftAppliedWholeTagOutOfTransform token.children, refused
    return transform, liftedTag, undo if transform

-- Which of the pair's two names states a given argument count. Both renderers run `\fad` and `\fade`
-- through one reading that branches on how many arguments it was given and never on which name was
-- written, so a count either name may take has one spelling that says what the tag does.
fadeNameByArgumentCount = {
  [2]: TagName.Fade
  [7]: TagName.FadeComplex
}

---Names a fade by the number of arguments it was given, which is what both renderers read it by. A
---count neither name takes fades under neither, so nothing is renamed there and the tag stands.
---@param siblings AssToken[] The tokens the tag sits among.
---@param refused table<AssToken, true> A set of tags already tried and refused, so one of them stops nothing else.
---@return AssToken? token The tag now named for what it does.
---@return fun()? undo Puts the name written back.
renameFadeByArgumentCount = (siblings, refused) ->
  for token in *siblings
    if token.kind == TokenKind.Tag and not refused[token] and
        (token.name == TagName.Fade or token.name == TagName.FadeComplex)
      -- we can only determine the right fade tag if the arguments provided match any of either tag's signatures.
      wanted = token.arguments and fadeNameByArgumentCount[#token.arguments]
      if wanted and wanted != token.name
        written = token.name
        token.name = wanted
        return token, -> token.name = written

    continue unless token.children
    renamed, undo = renameFadeByArgumentCount token.children, refused
    if renamed
      written = token.params
      token.params = emit token.children
      return renamed, ->
        undo!
        token.params = written

---Closes an argument list left open, which both renderers read to the end of the block regardless.
---@param siblings AssToken[] The tokens the tag sits among.
---@param refused table<AssToken, true> Tags already tried and refused, so one of them stops nothing else.
---@return AssToken? token The tag whose argument list now closes.
---@return fun()? undo Leaves it open again.
closeArgumentList = (siblings, refused) ->
  for token in *siblings
    if token.kind == TokenKind.Tag and token.form and token.form.parenthesized and
        not token.form.argumentsClosed and not refused[token]
      token.form.argumentsClosed = true
      return token, -> token.form.argumentsClosed = nil

    continue unless token.children
    closed, undo = closeArgumentList token.children, refused
    if closed
      written = token.params
      token.params = emit token.children
      return closed, ->
        undo!
        token.params = written

---Takes out a backslash naming no tag, which every dialect reads past.
---@param siblings AssToken[] The tokens the run sits among.
---@param refused table<AssToken, true> Runs already tried and refused, so one of them stops nothing else.
---@return AssToken? token The run taken out.
---@return fun()? undo Puts it back where it stood.
removeStrayBackslash = (siblings, refused) ->
  for index = 1, #siblings
    token = siblings[index]
    if token.kind == TokenKind.Junk and token.text and token.text\match("^\\+$") and not refused[token]
      table.remove siblings, index
      return token, -> table.insert siblings, index, token

    continue unless token.children
    removed, undo = removeStrayBackslash token.children, refused
    if removed
      written = token.params
      token.params = emit token.children
      return removed, ->
        undo!
        token.params = written

---Takes out a tag written with no arguments that declares no bare form, which every dialect reads as
---nothing. Its braces go with it where it stood alone in the block, so the rewrite leaves no empty one
---behind. A tag holding arguments that match no signature is left alone: it reads as nothing just the
---same, but which of the arguments were meant cannot be recovered, so it is left for the author to settle.
---@param siblings AssToken[] The tokens the tag sits among.
---@param refused table<AssToken, true> Tags already tried and refused, so one of them stops nothing else.
---@return AssToken? token The tag taken out.
---@return fun()? undo Puts it back where it stood, braces included.
removeUnreadBareTag = (siblings, refused) ->
  for index = 1, #siblings
    token = siblings[index]
    definition = token.kind == TokenKind.Tag and overrideTags[token.name]
    if definition and not definition.acceptsBareTag and not refused[token] and
        (token.params or "")\match "^%s*$"
      table.remove siblings, index
      opensAt = index - 1
      if siblings[opensAt] and siblings[opensAt].kind == TokenKind.BlockStart and
          siblings[index] and siblings[index].kind == TokenKind.BlockEnd
        blockEnd = table.remove siblings, index
        blockStart = table.remove siblings, opensAt
        return token, ->
          table.insert siblings, opensAt, blockStart
          table.insert siblings, index, token
          table.insert siblings, index + 1, blockEnd
      return token, -> table.insert siblings, index, token

    continue unless token.children
    removed, undo = removeUnreadBareTag token.children, refused
    if removed
      written = token.params
      token.params = emit token.children
      return removed, ->
        undo!
        token.params = written

---Flattens nested transforms into the siblings both renderers read them as. While inner transforms
---do work, the nesting doesn't enable any kind of composition behavior this degenerate form may suggest.
---The outer is left standing even when the split leaves it empty, since the mere presence of a transform
---tag switches collision detection off whether it animates anything or not.
---@param siblings AssToken[] The tokens the pair will sit among, which the inner one is inserted into.
---@return AssToken? outer The transform that was split, nil where the tokens hold no such pair.
---@return AssToken? inner The transform now standing beside it.
---@return fun()? undo Puts the tokens back as they were, for a split the targets do not accept.
splitNestedTransform = (siblings) ->
  for index = 1, #siblings
    token = siblings[index]
    continue unless token.kind == TokenKind.Tag and token.name == TagName.Transform
    children = token.children or {}

    at = nil
    for childIndex = 1, #children
      child = children[childIndex]
      if child.kind == TokenKind.Tag and child.name == TagName.Transform
        at = childIndex
        break
    continue unless at

    inner = children[at]
    innerChildren = inner.children or {}
    formAsWritten = inner.form
    wasParenthesized = inner.form and inner.form.parenthesized
    wasClosed = inner.form and inner.form.argumentsClosed

    kept = [children[i] for i = 1, at - 1]
    -- Tags written after the inner transform animate over the inner's interval rather than the outer's,
    -- so the split moves them in beside the inner's own: `\t(0,500,\fscx50\t(100,200,\fscy80)\frz30)`
    -- becomes `\t(0,500,\fscx50)\t(100,200,\fscy80\frz30)`.
    moved = [child for child in *innerChildren]
    moved[#moved + 1] = children[i] for i = at + 1, #children

    undo = ->
      table.remove siblings, index + 1
      token.children, inner.children = children, innerChildren
      inner.form = formAsWritten
      if formAsWritten
        formAsWritten.parenthesized = wasParenthesized
        formAsWritten.argumentsClosed = wasClosed
      token.params, inner.params = emit(children), emit innerChildren

    token.children, inner.children = kept, moved
    -- Both renderers end a transform's argument list at the first `)`, stealing it from a transform
    -- nested inside (e.g. `\t(0,500,\t(100,200,\fscx50))`). Once split out, the inner one needs its own
    -- closing parenthesis, so it does not run on into what follows. Written without parentheses at all
    -- (e.g. `\t(0,500,\t\fscx50)`) it needs an opening one too, or the tags moved into it stand at
    -- block level and apply whole.
    inner.form or= {}
    inner.form.parenthesized = true
    inner.form.argumentsClosed = true
    token.params, inner.params = emit(kept), emit moved
    table.insert siblings, index + 1, inner
    return token, inner, undo

  for token in *siblings
    continue unless token.children
    outer, inner, undo = splitNestedTransform token.children
    return outer, inner, undo if outer

---What each bare tag restores, per dialect, at the point in the line where it stands.
---
---Both renderers accept a bare form for far more tags than the specification advertises, and where
---they agree on what one means this treats that spelling as canonical. A handful of names restore a
---fixed value whatever precedes them, which each states as its `bareTagDefault`. Every other bare tag
---restores what seeded its field, and the dialects can part there: a `\r` naming another style leaves
---libass restoring that style and VSFilter the line's own, so one bare tag stands for two values and
---neither is wrong. Naming a reference dialect settles which of the two the line meant.
---@param tokens AssToken[] A stream as a scan returns it.
---@param targets AssDialectName[] The dialects to read the seeds under.
---@param style? AegisubStyleLine The style the line is set in.
---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches.
---@return table<AssToken, table<AssDialectName, any>> seeds Keyed by the bare tag, then by dialect.
---  Holds nothing for a dialect comparing no runs, and nothing for a tag naming no field.
readBareTagSeeds = (tokens, targets, style, stylesByName) ->
  seeds = {}
  for dialect in *targets
    continue unless dialects[dialect].runComparison
    state = AssRunState style or defaultStyle, dialect, stylesByName
    readState = (siblings) ->
      for token in *siblings
        if token.kind == TokenKind.Tag
          definition = overrideTags[token.name]
          if definition and definition.runFields and token.arguments and #token.arguments == 0
            seeds[token] or= {}
            seeds[token][dialect] = state.seeded[definition.runFields[1]]
          state\applyTag token unless isKaraokeTagName token.name
        readState token.children if token.children
    readState tokens
  return seeds

---The value a bare tag has to be written as for every target to draw what the reference draws.
---@param seeds table<AssToken, table<AssDialectName, any>> What each bare tag restores, per dialect.
---@param targets AssDialectName[] The dialects the result has to satisfy.
---@param referenceDialect? AssDialectName The dialect the others converge on, where one is named.
---@param token AssToken The bare tag.
---@return string? params Nil where the targets already agree, which leaves the bare tag as the
---  spelling of what they agree on.
getConvergingArgumentForBareTag = (seeds, targets, referenceDialect, token) ->
  return nil unless referenceDialect
  values = seeds[token]
  return nil unless values
  reference = values[referenceDialect]
  return nil if reference == nil

  parted = false
  for dialect in *targets
    parted = true if values[dialect] != nil and values[dialect] != reference
  return nil unless parted
  return emitSingleArgument referenceDialect, token.name, reference

---Whether a tag may be rewritten at all. It has to write a field a run comparison reads, so that the
---check has something to hold a rewrite to, or be one of the three eligible by name: `\q` decides
---whether `\n` breaks the line, `\p` ends a karaoke syllable, and `\r` rewrites every field at once.
---A karaoke tag qualifies only through a bare form with one spelling, since its argument is a duration.
---@param token AssToken The tag.
---@param definition AssTagDefinition The tag's definition.
---@return boolean eligible
isEligibleForCanonicalization = (token, definition) ->
  bareWithASpelling = token.arguments and #token.arguments == 0 and
    definition.bareTagDefault != nil

  return false if isKaraokeTagName(token.name) and not bareWithASpelling
  return true if bareWithASpelling or definition.runFields
  token.name == TagName.WrapStyle or token.name == TagName.Drawing or token.name == TagName.Reset

---Rewrites the tags of a line that do not mean what they say into the spelling of what they mean,
---leaving every tag that reads at face value byte for byte — redundant or not, since tidying a
---well-formed line is a separate concern from repairing a quirky one.
---
---Karaoke tags are never touched, since their argument is a duration rather than an appearance, so
---rewriting one would move the timing rather than repair it. A tag writing nothing a run comparison
---reads is left alone for the opposite reason: the check would find the two lines alike whatever the
---rewrite said, and accept it without evidence. `\q` is the exception, since it decides whether `\n`
---breaks the line and a break ends a karaoke syllable, which the check does compare.
---@param text string A line's Text field.
---@param options? AssNormalizeOptions What to read the line against, all of it optional.
---@return string text The rewritten line, identical to the input where nothing wanted rectifying.
---@return AssNormalizeDivergence[] divergences Tags whose canonical spelling only some targets accepted.
---@return AssNormalizeChange[] changes What was rewritten, in the order the line holds it, each keyed to
---  the original line indices (just like the findings).
normalizeLine = (text, options = {}) ->
  {:style, :stylesByName, :wrapStyle, :referenceDialect, :durationMs} = options
  targets = options.targets or defaultTargets

  if referenceDialect
    isTarget = false
    isTarget = true for dialect in *targets when dialect == referenceDialect
    assert isTarget, msgs.normalizeLine.referenceOutsideTargets\format tostring(referenceDialect)

  tokens = Scanner(targets[1])\scan text or ""
  divergences, changes = {}, {}
  spans = diagnostics.mapTokenSpans tokens

  -- A pre-processing pass that fixes syntax and tag name issues for the subsequent argument
  -- canonicalization to rely on.
  for findRepair in *{renameFadeByArgumentCount, closeArgumentList, removeStrayBackslash, removeUnreadBareTag}
    refused = {}
    while true
      token, undo = findRepair tokens, refused
      break unless token

      before = text\sub spans[token].startIndex + 1, spans[token].endIndex
      rewritten = emit tokens
      accepting = [dialect for dialect in *targets when diagnostics.isEquivalent dialect, text, rewritten, style, stylesByName, wrapStyle, durationMs]

      if #accepting == #targets
        changes[#changes + 1] = {
          kind: ChangeKind.Tag
          :before
          after: token.kind == TokenKind.Tag and emitTag(token)\sub(2) or "" -- without the backslash, just like `before`
          startIndex: spans[token].startIndex
          endIndex: spans[token].endIndex
        }
      else
        undo!
        -- prevents a repair that not every target accepted from being proposed again in the next pass
        refused[token] = true
        divergences[#divergences + 1] = {tag: before, rewritten: "", :accepting} if #accepting > 0

  seeds = readBareTagSeeds tokens, targets, style, stylesByName

  for token, transforms in iterateTags tokens
    definition = overrideTags[token.name]
    continue unless definition
    continue unless isEligibleForCanonicalization token, definition

    canonical = referenceDialect and canonicalArgumentFor(referenceDialect, token) or nil
    -- Two targets can canonicalize one tag differently, e.g. a color literal holding no digit: the
    -- dialect refusing it writes the bare tag where the other writes the value it reads. Sorting the
    -- offers keeps the choice off the order the targets arrived in, and puts a stated value ahead of a
    -- bare tag, so `\1a&H&` is rewritten to `\1a&H00&` wherever the check accepts it.
    if canonical == nil
      offers = {}
      for dialect in *targets
        offered = canonicalArgumentFor dialect, token
        offers[#offers + 1] = offered if offered != nil
      table.sort offers, (a, b) ->
        return #a > #b if #a != #b
        a < b
      canonical = offers[1]

    if token.arguments and #token.arguments == 0
      canonical or= getConvergingArgumentForBareTag seeds, targets, referenceDialect, token
    continue unless canonical != nil

    written = token.params
    token.params = canonical
    regenerateTransformArguments transforms
    rewritten = emit tokens

    accepting = [dialect for dialect in *targets when diagnostics.isEquivalent dialect, text, rewritten, style, stylesByName, wrapStyle, durationMs]
    acceptedBy = {dialect, true for dialect in *accepting}
    converged = {}

    -- a rewrite must not change how the reference reads the line
    if referenceDialect and acceptedBy[referenceDialect]
      referenceReading = diagnostics.describeKaraokeSyllables referenceDialect, rewritten, style, stylesByName, wrapStyle
      referenceAppearance = diagnostics.describeCanonicalAppearance referenceDialect, rewritten, style, stylesByName
      for dialect in *targets
        continue if acceptedBy[dialect]

        -- A target follows the reference on three counts: the rewritten argument reads at face value
        -- under it, it cuts the line into the same karaoke syllables, and it leaves the same run state.
        continue unless nil == canonicalArgumentFor dialect, token
        continue unless referenceReading == diagnostics.describeKaraokeSyllables dialect, rewritten, style, stylesByName, wrapStyle

        -- a dialect comparing no runs states no appearance, so there is nothing to hold it to
        appearance = diagnostics.describeCanonicalAppearance dialect, rewritten, style, stylesByName
        continue unless referenceAppearance == nil or appearance == nil or referenceAppearance == appearance

        acceptedBy[dialect] = true
        accepting[#accepting + 1] = dialect
        converged[#converged + 1] = dialect

    if #accepting != #targets
      token.params = written
      regenerateTransformArguments transforms
      if #accepting > 0
        divergences[#divergences + 1] = {
          tag: "#{token.name}#{written}"
          rewritten: "#{token.name}#{canonical}"
          :accepting
        }
    else
      changes[#changes + 1] = {
        kind: ChangeKind.Tag
        before: "#{token.name}#{written}"
        after: "#{token.name}#{canonical}"
        startIndex: spans[token].startIndex
        endIndex: spans[token].endIndex
        converged: #converged > 0 and converged or nil
      }

  -- A drawing ends a karaoke syllable whether or not it draws anything, so removing one moves the
  -- timing of every syllable after it. A line with no karaoke tag has no timing to move.
  containsKaraokeTag = false
  containsKaraokeTag = true for tag in iterateTags tokens when isKaraokeTagName tag.name

  -- Drawings, which carry no arguments a tag reading applies to and so are visited on their own.
  for token in *tokens
    continue unless token.kind == TokenKind.Drawing
    commands = token.commands or {}

    -- With a reference named, the drawing is written as that dialect reads it, which is what the other
    -- targets are then converged onto. A drawing the reference draws no part of reads as the empty
    -- drawing, so converging on that reading takes the drawing out.
    canonical, reduced = canonicalizeDrawing commands, referenceDialect
    continue unless reduced

    -- Removing the drawing is the reference's reading of it where the reference draws no part of it,
    -- and a drawing writes no style field, so the syllable it ends is the only thing its removal
    -- disturbs. That leaves the appearance to check and the karaoke reading to have ruled out.
    if referenceDialect and #canonical == 0
      continue if containsKaraokeTag
      written = token.text
      token.text = ""
      rewritten = emit tokens
      appearanceHolds = true
      for dialect in *targets
        before = diagnostics.describeCanonicalAppearance dialect, text, style, stylesByName
        after = diagnostics.describeCanonicalAppearance dialect, rewritten, style, stylesByName
        appearanceHolds = false unless before == after
      if appearanceHolds
        token.commands = nil
        changes[#changes + 1] = {
          kind: ChangeKind.Drawing, before: written, after: ""
          startIndex: spans[token].startIndex, endIndex: spans[token].endIndex
          converged: {referenceDialect}
        }
      else
        token.text = written
        divergences[#divergences + 1] = {tag: written, rewritten: "", accepting: {referenceDialect}}
      continue

    written = token.text
    token.text = canonical
    rewritten = emit tokens

    accepting = [dialect for dialect in *targets when diagnostics.isEquivalent dialect, text, rewritten, style, stylesByName, wrapStyle, durationMs]
    acceptedBy = {dialect, true for dialect in *accepting}
    converged = {}

    if referenceDialect and acceptedBy[referenceDialect]
      -- A target follows the reference where it now reads the rewritten drawing as the reference
      -- reads it, which is the only thing a dialect can disagree about here.
      referenceReading = canonicalizeDrawing readDrawing(canonical), referenceDialect
      for dialect in *targets
        continue if acceptedBy[dialect]
        continue unless referenceReading == canonicalizeDrawing readDrawing(canonical), dialect
        acceptedBy[dialect] = true
        accepting[#accepting + 1] = dialect
        converged[#converged + 1] = dialect

    if #accepting == #targets
      token.commands = nil
      changes[#changes + 1] = {
        kind: ChangeKind.Drawing, before: written, after: canonical
        startIndex: spans[token].startIndex, endIndex: spans[token].endIndex
        converged: #converged > 0 and converged or nil
      }
    else
      token.text = written
      if #accepting > 0
        divergences[#divergences + 1] = {tag: written, rewritten: canonical, :accepting}

  -- flatten nested transforms into the siblings both renderers read them as
  while true
    outer, inner, undo = splitNestedTransform tokens
    break unless outer

    before = text\sub spans[outer].startIndex + 1, spans[outer].endIndex
    rewritten = emit tokens
    accepting = [dialect for dialect in *targets when diagnostics.isEquivalent dialect, text, rewritten, style, stylesByName, wrapStyle, durationMs]

    if #accepting == #targets
      changes[#changes + 1] = {
        kind: ChangeKind.Tag
        :before
        after: (emitTag(outer) .. emitTag inner)\sub 2
        startIndex: spans[outer].startIndex
        endIndex: spans[outer].endIndex
      }
    else
      undo!
      divergences[#divergences + 1] = {tag: before, rewritten: "", :accepting} if #accepting > 0
      break

  -- A tag the transform does not interpolate is applied whole from the first frame, so we lift it out of the transform.
  refused = {}
  while true
    transform, lifted, undo = liftAppliedWholeTagOutOfTransform tokens, refused
    break unless transform

    before = text\sub spans[transform].startIndex + 1, spans[transform].endIndex
    rewritten = emit tokens
    accepting = [dialect for dialect in *targets when diagnostics.isEquivalent dialect, text, rewritten, style, stylesByName, wrapStyle, durationMs]

    if #accepting == #targets
      changes[#changes + 1] = {
        kind: ChangeKind.Tag
        :before
        after: (emitTag(lifted) .. emitTag transform)\sub 2
        startIndex: spans[transform].startIndex
        endIndex: spans[transform].endIndex
      }
    else
      undo!
      -- prevents a lift that not every target accepted from being proposed again in the next pass
      refused[lifted] = true
      divergences[#divergences + 1] = {tag: before, rewritten: "", :accepting} if #accepting > 0

  emit(tokens), divergences, changes

---Repairing the tags of a line that do not mean what they say, checked against the dialects rather
---than declared. A prototype for the normalization layer, which is why nothing requires it yet.
---@class AssNormalize
return {
  :normalizeLine
}
