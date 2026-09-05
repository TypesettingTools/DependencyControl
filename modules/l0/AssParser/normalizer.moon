-- A rewrite's canonical form is derived from the same reading of a tag that the run state applies,
-- and the check that accepts the rewrite reads the line through that reading too. So the check cannot
-- catch a wrong reading, only a fault between the reading and the emitted line: the canonical form,
-- the emission, and the interplay with karaoke tags. The readings themselves are pinned by the
-- probe-backed equivalences in `test/value-equivalences.moon`.

Enum = require "l0.DependencyControl.Enum"
Scanner = require "l0.AssParser.Scanner"
diagnostics = require "l0.AssParser.diagnostics"
{:canonicalizeDrawing, :parseDrawing} = require "l0.AssParser.drawing"
{:emit, :emitTag} = require "l0.AssParser.emitter"
AssRunState = require "l0.AssParser.RunState"
tagArguments = require "l0.AssParser.arguments"
{:canonicalArgumentFor, :emitSingleArgument} = tagArguments
{:defaultStyle, :resolveStyle} = require "l0.AssParser.ass"
{:DialectName, :Syntax, :TagName, :TokenKind, :TransformBehavior, :dialects, :getArgumentReading,
  :overrideTags, :isKaraokeTagName} = require "l0.AssParser.dialects"

msgs = {
  normalizeLine: {
    referenceOutsideTargets: "Reference dialect '%s' must be one of the targets."
    tokensDialectMismatch: "A stream read under dialect '%s' cannot be normalized against reference dialect '%s'."
    treeDescribesDifferently: "Describing a rewrite from a kept stream differs from scanning it back, under '%s'.\nLine: %s\nFrom the stream: %s\nFrom a scan:     %s"
  }
}

-- Aegisub draws nothing, so a rewrite is held to the two dialects that do
defaultTargets = {DialectName.Libass, DialectName.XyVsfilter}

scannerByDialectName = {}

---Returns a scanner for the given dialect. A scanner keeps no state between scans, so one is created
---per dialect and reused by every later call.
---@param dialect AssDialectName
---@return AssOverrideScanner scanner
getScanner = (dialect) ->
  held = scannerByDialectName[dialect]
  return held if held
  held = Scanner dialect
  scannerByDialectName[dialect] = held
  return held

-- looked up for every tag inside every transform the lifting pass visits
appliedWholeTagNames = {}
for name, definition in pairs overrideTags
  appliedWholeTagNames[name] = true if definition.transform == TransformBehavior.AppliedWhole

---What a recorded change rewrote.
---@alias AssNormalizeChangeKind string
---| "tag" # Tag: an override tag whose argument was rewritten
---| "drawing" # Drawing: a drawing rewritten or taken out
ChangeKind = Enum "AssNormalizeChangeKind", {
  Tag: "tag"
  Drawing: "drawing"
}

---A rewrite the normalizer kept.
---@class AssNormalizeChange
---@field kind AssNormalizeChangeKind Whether a tag or a drawing was rewritten.
---@field before AssToken[] The tokens of the original stream the rewrite replaced, in stream order. A
---  single token for most rewrites, and the transform itself where a tag was lifted out of it.
---@field after AssToken[] The tokens of the rewritten stream that replaced them, in stream order. Two
---  where a transform was split or a tag lifted out of one, and empty where the tokens were removed.
---@field converged? AssDialectName[] The targets that accepted the rewrite only by following the
---  reference, and so draw the line differently after it. Absent where every target already read the
---  rewritten line alike, which leaves every picture unchanged.

---Options for `normalizeLine`, all optional. By default a line is checked against both renderers, set in
---the default style, with no reference dialect.
---@class AssNormalizeOptions
---@field targets? AssDialectName[] The dialects the result has to satisfy, both renderers by default.
---@field style? AegisubStyleLine The style to set the line in, overriding the one its Style field
---  resolves to, for every target. Without it the Style field is resolved separately for each target,
---  and where the script does not declare that style, each renderer falls back to its own default style.
---@field allowApproximateNormalizations? boolean Whether a rewrite may change the picture by a bounded
---  amount. Off by default. Enables closing a transform where its value crosses the bound its field is
---  clamped to, which removes out-of-range values. Even an exact crossing changes the interpolation in
---  its last bits, so the rendered frames can differ where the equivalence check reads the lines alike.
---@field allowRoundedTransformCrossings? boolean Whether a transform may be closed at the nearest whole
---  millisecond where its value crosses the bound between two. Transform times are whole milliseconds,
---  so the rounded window animates slightly faster or slower than the exact one. Requires
---  `allowApproximateNormalizations`.
---@field largestAcceptedError? number How far a rounded crossing may move the animated value, in the
---  units the tag itself writes, so 1 is one percent of scale or one pixel of border. Any error is
---  accepted where absent. Ignored without `allowRoundedTransformCrossings`.
---@field tokens? AssTokenStream The line already scanned, to save scanning it again. It is rewritten in
---  place, the line's Text field is not read, and the result is in the dialect it was scanned under.
---  Throws where a reference dialect is also given and differs from that dialect.
---@field stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@field wrapStyle? AssWrapStyle The script's wrap style. Where `\n` breaks a line depends on it, and for
---  values outside the four the format defines the two renderers break differently, so a rewrite checked
---  under the wrong wrap style can be accepted where it does not hold.
---@field referenceDialect? AssDialectName The dialect the line was authored against, which must be one of
---  the targets. When set, a rewrite may change what the other targets draw, bringing them onto the
---  reference's reading, as long as the reference's own picture is unchanged. When unset, a rewrite is
---  kept only where every target's picture is unchanged.
---@field verifyDescriptionTrees? boolean Whether to describe each rewrite both from the kept description
---  stream and from a scan of its emitted text, throwing where the two differ. A stale kept stream gives
---  a wrong description without failing, so enable this when changing how the streams are kept, and run
---  a corpus through it. Adds a second description per rewrite.

---A rewrite that only some of the targets accepted, and that was undone.
---@class AssNormalizeDivergence
---@field tag string The tag as the line wrote it, with its arguments but without its backslash. For a
---  drawing, the drawing's text.
---@field rewritten string The refused rewrite in the same form. Empty for the syntax repairs and the
---  transform passes, which do not record one.
---@field accepting AssDialectName[] The targets that accepted the rewrite, by reading the line alike or by
---  following the reference dialect. A non-empty proper subset of the targets.

---Checks whether a token's text is backslashes and nothing else, which every dialect skips inside an
---override block.
---@param token AssToken A junk token.
---@return boolean isBackslashes False where the token has no text.
isBackslashRun = (token) -> token.text != nil and token.text\match("^#{Syntax.TagPrefix}+$") != nil

---Iterates over every tag in a stream, including those nested in a transform's arguments, yielding each
---with the transforms that hold it, outermost first.
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
---@param dialect? AssDialectName Whose reading to type the regenerated arguments under.
regenerateTransformArguments = (transforms, dialect) ->
  for index = #transforms, 1, -1
    transforms[index].params = emit transforms[index].children
    tagArguments.reparseToken transforms[index], dialect if dialect

---Calculates when a transform animating a field downward crosses the lower bound the field is clamped to.
---Renderers interpolate toward the written value and clamp only when drawing, so the drawn value stays at
---the bound from the crossing until the window closes.
---@param startValue number The field's value when the window opens.
---@param target number The value the transform animates toward.
---@param bound number The lower bound the dialect clamps the field to.
---@param openedAt number When the window opens.
---@param closedAt number When it closes.
---@param acceleration number The transform's acceleration, 1 where none is given.
---@return number? crossing The crossing moment, or nil where the value does not cross the bound within
---  the window.
getBoundCrossingTime = (startValue, target, bound, openedAt, closedAt, acceleration) ->
  return nil unless acceleration > 0 and closedAt > openedAt
  return nil unless target < bound and startValue >= bound
  return openedAt + (closedAt - openedAt) * ((startValue - bound) / (startValue - target)) ^ (1 / acceleration)

---Calculates the largest difference between the values animated over the rounded window and over the
---exact one. Both follow `startValue * (1 - (u / window) ^ acceleration)` and differ only in window
---length, so they are furthest apart where the shorter window closes.
---@param startValue number The field's value when the window opens.
---@param trueCrossing number The exact moment the value crosses the bound.
---@param roundedCrossing number The crossing rounded to a whole millisecond.
---@param openedAt number When the window opens.
---@param acceleration number The transform's acceleration.
---@return number apart The largest difference, in the tag's own units.
getLargestCrossingError = (startValue, trueCrossing, roundedCrossing, openedAt, acceleration) ->
  trueWindow, roundedWindow = trueCrossing - openedAt, roundedCrossing - openedAt
  return 0 if trueWindow == roundedWindow or trueWindow <= 0 or roundedWindow <= 0
  shorter = math.min trueWindow, roundedWindow
  return math.abs startValue *
    ((shorter / trueWindow) ^ acceleration - (shorter / roundedWindow) ^ acceleration)

---Returns a transform's timing prefix with its closing time replaced, so `0,500,1.15,` becomes
---`0,3000,1.15,`. The prefix is the text before the tags the transform animates, which the scan keeps
---as a single junk token.
---
---Every timing other than the closing time keeps its written form, `0.00` included.
---@param transform AssToken The transform, with both its parsed arguments and their text.
---@param closedAt integer The moment to close the window at.
---@return string? rewritten The rewritten prefix, or nil where the transform's text and its parsed
---  arguments disagree on the argument count.
withTransformClosingTime = (transform, closedAt) ->
  arguments = transform.arguments
  return nil unless arguments and #arguments >= 3

  parts = tagArguments.splitArguments transform.params or "", #arguments
  return nil unless #parts == #arguments

  -- every argument but the last, which holds the animated tags and is emitted from `children`
  timings = [parts[index] for index = 1, #arguments - 1]
  timings[2] = tagArguments.emitNumber closedAt
  return table.concat(timings, Syntax.ArgumentSeparator) .. Syntax.ArgumentSeparator

---Collects every tag in a stream with the transforms holding it, in walk order, so that an index
---identifies the same tag in any two streams scanned from the same text.
---@param tokens AssToken[]
---@return {token: AssToken, transforms: AssToken[]}[] tags In walk order.
collectTags = (tokens) ->
  collected = {}
  for token, transforms in iterateTags tokens
    collected[#collected + 1] = {:token, :transforms}
  return collected

---Scans the line once per target, so that checking a rewrite can describe a kept stream instead of
---scanning the emitted text again. Each target needs its own stream, because a stream holds the values
---its dialect read, and none of them can be the tree the rewrites are applied to, whose parsed arguments
---are left as first scanned.
---@param targets AssDialectName[] The dialects to scan for.
---@param tokens AssToken[] The tree the rewrites are applied to, which the trees have to line up with.
---@param text string The line as the syntax repairs left it.
---@return table<AssDialectName, {tree: AssToken[], tags: table}>? trees One stream per target with its
---  tags in walk order. Nil where a target scans the line into different tags or does not emit it back
---  unchanged, since an edit could not then be mirrored into it.
buildDescriptionTrees = (targets, tokens, text) ->
  primary = collectTags tokens
  trees = {}
  for dialect in *targets
    tree = getScanner(dialect)\scan text or ""
    return nil unless emit(tree) == text
    tags = collectTags tree
    return nil unless #tags == #primary
    for at = 1, #tags
      return nil unless tags[at].token.name == primary[at].token.name and
        tags[at].token.params == primary[at].token.params and
        #tags[at].transforms == #primary[at].transforms
    trees[dialect] = {:tree, :tags}
  return trees

---Finds the junk token after a transform that holds the closing parentheses taken from tags nested in
---it. Both renderers end a transform's argument list at the first `)`, so a parenthesized tag inside it
---is left unclosed, and the `)` written for that tag ends up after the transform. A pass that closes such
---a tag or drops its parentheses has to remove one `)` from this token.
---@param siblings AssToken[] The stream the transform is in.
---@param index integer The transform's index in it.
---@return AssToken? run The junk token, or nil where the token after the transform is not junk starting
---  with `)`.
findStolenCloserRun = (siblings, index) ->
  run = siblings[index + 1]
  return nil unless run and run.kind == TokenKind.Junk and run.text
  return nil unless run.text\sub(1, 1) == Syntax.ArgumentListClose
  run

---Moves a tag its transform does not interpolate out of it, to stand just before it.
---
---Standing before the transform keeps the tag's order against everything written outside it, and
---changes its order against the tags left inside. That can change what the line does: a `\r` moved out
---from behind an interpolated tag no longer resets what that tag wrote.
---@param siblings AssToken[] The tokens the transform sits among, which the moved tag joins just before it.
---@param refused table<AssToken, true> Tags already tried and refused, which are skipped so that they do
---  not block the rest.
---@param stolenCloserRun? AssToken The junk token after the outermost transform, holding the `)` its
---  argument list took. Passed down while recursing, since only the outermost transform has one after it.
---@return AssToken? transform The transform the tag came out of.
---@return AssToken? liftedTag The tag moved out of the transform and before it.
---@return fun()? undo Puts the tokens back as they were, for a move the targets do not accept.
liftAppliedWholeTagOutOfTransform = (siblings, refused, stolenCloserRun) ->
  for index = 1, #siblings
    token = siblings[index]
    continue unless token.kind == TokenKind.Tag and token.name == TagName.Transform
    children = token.children or {}
    closerRun = stolenCloserRun or findStolenCloserRun siblings, index

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

    -- Outside the transform the tag needs its own `)`, or its arguments run on into what follows. In
    -- `\t(0,500,\fad(0,100))` the first `)` ends the transform's arguments and the second is junk after
    -- it, so lifting `\fad` out removes that junk `)` and the line keeps the number it was written with.
    takesCloser = liftedTag.form and liftedTag.form.parenthesized and not wasClosed and closerRun
    closerAsWritten = takesCloser and closerRun.text

    undo = ->
      table.remove siblings, index
      token.children = children
      token.params = emit children
      liftedTag.form.argumentsClosed = wasClosed if liftedTag.form
      closerRun.text = closerAsWritten if takesCloser

    token.children = retainedTags
    token.params = emit retainedTags
    liftedTag.form.argumentsClosed = true if liftedTag.form
    closerRun.text = closerAsWritten\sub(2) if takesCloser
    table.insert siblings, index, liftedTag
    return token, liftedTag, undo

  for index = 1, #siblings
    token = siblings[index]
    continue unless token.children
    transform, liftedTag, undo = liftAppliedWholeTagOutOfTransform token.children, refused,
      stolenCloserRun or findStolenCloserRun siblings, index
    return transform, liftedTag, undo if transform

-- The fade name matching each argument count. Both renderers parse `\fad` and `\fade` identically and
-- choose between the simple and the complex fade by argument count alone, so each count has one name
-- that describes what the tag does.
fadeNameByArgumentCount = {
  [2]: TagName.Fade
  [7]: TagName.FadeComplex
}

---Renames a fade tag to the name matching its argument count, which is what both renderers go by. A tag
---whose argument count matches neither name is left as written.
---@param siblings AssToken[] The tokens the tag sits among.
---@param refused table<AssToken, true> Tags already tried and refused, which are skipped so that they do
---  not block the rest.
---@return AssToken? token The renamed tag.
---@return fun()? undo Restores the written name.
renameFadeByArgumentCount = (siblings, refused) ->
  for token in *siblings
    if token.kind == TokenKind.Tag and not refused[token] and
        (token.name == TagName.Fade or token.name == TagName.FadeComplex)
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

---Closes an unclosed argument list, which both renderers read to the end of the block either way.
---
---Only a tag directly in the block is considered. A transform's argument list ends at the first
---`)`, so a parenthesized tag nested in one has no closer of its own to write: the `)` that would close
---it is the transform's. Writing one there puts a stray `)` in the block, which is text rather than
---syntax and moves the line.
---@param siblings AssToken[] The tokens the tag sits among.
---@param refused table<AssToken, true> Tags already tried and refused, which are skipped so that they do
---  not block the rest.
---@return AssToken? token The tag whose argument list now closes.
---@return fun()? undo Leaves it open again.
closeArgumentList = (siblings, refused) ->
  for token in *siblings
    if token.kind == TokenKind.Tag and token.form and token.form.parenthesized and
        not token.form.argumentsClosed and not refused[token]
      token.form.argumentsClosed = true
      return token, -> token.form.argumentsClosed = nil

---Removes a run of backslashes that starts no tag, which every dialect skips.
---@param siblings AssToken[] The tokens the run sits among.
---@param refused table<AssToken, true> Runs already tried and refused, which are skipped so that they do
---  not block the rest.
---@return AssToken? token The removed run.
---@return fun()? undo Puts it back where it stood.
removeStrayBackslash = (siblings, refused) ->
  for index = 1, #siblings
    token = siblings[index]
    if token.kind == TokenKind.Junk and isBackslashRun(token) and not refused[token]
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

---Removes a tag written without arguments whose definition does not accept a bare form, which every
---dialect ignores. Where the tag was alone in its block, the braces are removed with it. A tag whose
---arguments match none of its signatures is ignored by every dialect too, but it is kept, since the
---arguments the author intended cannot be recovered.
---@param siblings AssToken[] The tokens the tag sits among.
---@param refused table<AssToken, true> Tags already tried and refused, which are skipped so that they do
---  not block the rest.
---@return AssToken? token The removed tag.
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

---Moves a transform nested in another out to stand after it, which is how both renderers read the pair.
---While inner transforms do work, the nesting doesn't enable any kind of composition behavior this
---degenerate form may suggest.
---The outer is left standing even when the split leaves it empty, since the mere presence of a transform
---tag switches collision detection off whether it animates anything or not.
---@param siblings AssToken[] The tokens the pair will sit among, which the inner one is inserted into.
---@param stolenCloserRun? AssToken The junk token after the outermost transform, holding the `)` its
---  argument list took. Passed down while recursing, since only the outermost transform has one after it.
---@return AssToken? outer The transform that was split, or nil where no transform is nested in another.
---@return AssToken? inner The inner transform, now after the outer one.
---@return fun()? undo Puts the tokens back as they were, for a split the targets do not accept.
splitNestedTransform = (siblings, stolenCloserRun) ->
  for index = 1, #siblings
    token = siblings[index]
    continue unless token.kind == TokenKind.Tag and token.name == TagName.Transform
    children = token.children or {}
    closerRun = stolenCloserRun or findStolenCloserRun siblings, index

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

    -- Outside the outer transform the inner one needs its own `)`, or its arguments run on into what
    -- follows. In `\t(0,500,\t(100,200,\fscx50))` the first `)` ends the outer transform's arguments and
    -- the second is junk after it, so the split removes that junk `)` and the line keeps the number it
    -- was written with.
    takesCloser = wasParenthesized and not wasClosed and closerRun
    closerAsWritten = takesCloser and closerRun.text

    undo = ->
      table.remove siblings, index + 1
      token.children, inner.children = children, innerChildren
      inner.form = formAsWritten
      if formAsWritten
        formAsWritten.parenthesized = wasParenthesized
        formAsWritten.argumentsClosed = wasClosed
      token.params, inner.params = emit(children), emit innerChildren
      closerRun.text = closerAsWritten if takesCloser

    token.children, inner.children = kept, moved
    -- An inner transform written without parentheses (`\t(0,500,\t\fscx50)`) needs an opening one too,
    -- or the tags moved into it apply in full at block level.
    inner.form or= {}
    inner.form.parenthesized = true
    inner.form.argumentsClosed = true
    closerRun.text = closerAsWritten\sub(2) if takesCloser
    token.params, inner.params = emit(kept), emit moved
    table.insert siblings, index + 1, inner
    return token, inner, undo

  for index = 1, #siblings
    token = siblings[index]
    continue unless token.children
    outer, inner, undo = splitNestedTransform token.children,
      stolenCloserRun or findStolenCloserRun siblings, index
    return outer, inner, undo if outer

---The state of a `normalizeLine` call: its resolved inputs, the values the helpers cache, and the results
---the passes accumulate. Built once per call and passed to every helper as its first argument.
---@class AssNormalizeContext
---@field text string The line as it arrived, which every rewrite is checked against.
---@field tokens AssTokenStream The stream the passes rewrite in place, and what the call returns.
---@field original? AssTokenStream A copy of the stream from before any pass edited it, taken by
---  `snapshotOriginal` and absent until some pass is about to make its first edit.
---@field copyOf? table<AssToken, AssToken> The token of `original` each token of `tokens` was copied
---  to, filled alongside `original`.
---@field spans? table<AssToken, {startIndex: integer, endIndex: integer}> The byte range of `text` each
---  token of `original` was read from, mapped by `getWrittenTag` on the first refusal and absent until
---  then.
---@field targets AssDialectName[] The dialects a rewrite has to satisfy.
---@field referenceDialect? AssDialectName The dialect the line was authored against, where one was given.
---@field style? AegisubStyleLine The style given in the options, which takes precedence over the line's
---  Style field.
---@field styleName? string The line's Style field.
---@field stylesByName? table<string, AegisubStyleLine> Every style the script declares.
---@field wrapStyle? AssWrapStyle The script's wrap style.
---@field durationMs? integer How long the line is on screen.
---@field scannerByDialect table<AssDialectName, AssOverrideScanner> A scanner for each target.
---@field verifyDescriptionTrees? boolean Copied from the options.
---@field allowApproximateNormalizations? boolean Copied from the options.
---@field allowRoundedTransformCrossings? boolean Copied from the options.
---@field largestAcceptedError? number Copied from the options.
---@field styleByDialect table<AssDialectName, AegisubStyleLine> The style resolved for each dialect so
---  far, filled by `styleFor`.
---@field describedOriginal table<AssDialectName, string> The description of `text` under each dialect
---  that has asked for it, filled by `readsTheSame`.
---@field scannedOriginal table<AssDialectName, AssTokenStream> The line as it arrived, read under each
---  dialect that has asked for it, filled by `getScannedOriginal`. The entry for the dialect that read
---  `tokens` is `original` itself once a pass has taken it.
---@field descriptionTrees? table<AssDialectName, {tree: AssToken[], tags: table}> One stream per target,
---  kept in step with the rewrites while arguments are settled. Nil before that pass and after it.
---@field changes AssNormalizeChange[] Every rewrite accepted so far, in the order the passes made them.
---@field divergences AssNormalizeDivergence[] Every rewrite refused because only some targets accepted it.
---@field candidates AssNormalizeCandidate[] The tags a canonical form was found for, in walk order.
---@field closerRunAsWritten table<AssToken, string> The written text of each junk token after a transform
---  that has had a `)` removed, keyed by that token. Rewrites are applied and undone repeatedly, and each
---  application starts from this text, not from what the previous one left.

---Returns the style a dialect draws the line in, resolved on first use and cached per dialect. Where
---the script does not declare the style the Style field refers to, each renderer falls back to its own
---default style, so the result can differ by dialect.
---@param context AssNormalizeContext
---@param dialect AssDialectName
---@return AegisubStyleLine style The resolved style.
styleFor = (context, dialect) ->
  held = context.styleByDialect[dialect]
  return held if held
  {:style, :styleName} = context
  held = if style or not styleName
    style or defaultStyle
  else resolveStyle context.stylesByName, styleName, dialects[dialect].fallbackStyle or defaultStyle
  context.styleByDialect[dialect] = held
  return held

---Returns the line as it arrived, scanned under the given dialect and cached. Each check describes it at
---its own sample moments, so the stream is cached, not a description of it.
---
---For the dialect that scanned `tokens`, this is `original` once a pass has taken it, which is the same
---line under the same reading. Every other dialect reads the text differently and gets its own scan.
---@param context AssNormalizeContext
---@param dialect AssDialectName Whose reading to take.
---@return AssTokenStream tokens Shared by every check, so it must not be written to.
getScannedOriginal = (context, dialect) ->
  held = context.scannedOriginal[dialect]
  return held if held
  held = dialect == context.tokens.dialect and context.original or
    context.scannerByDialect[dialect]\scan context.text
  context.scannedOriginal[dialect] = held
  return held

---Checks whether a dialect reads the rewritten line as it read the original. The original's description
---is cached per dialect. The rewrite is described from the kept description stream while one exists,
---and from a scan of the rewritten text otherwise.
---@param context AssNormalizeContext
---@param dialect AssDialectName Whose reading to apply.
---@param rewrittenText string The line the rewrite would produce.
---@return boolean equivalent True where the two descriptions match.
readsTheSame = (context, dialect, rewrittenText) ->
  {:stylesByName, :wrapStyle, :durationMs} = context
  scanner = context.scannerByDialect[dialect]
  style = styleFor context, dialect
  context.describedOriginal[dialect] or= diagnostics.describeLine getScannedOriginal(context, dialect),
    style, stylesByName, wrapStyle, durationMs
  held = context.descriptionTrees and context.descriptionTrees[dialect]
  described = diagnostics.describeLine held and held.tree or scanner\scan(rewrittenText), style,
    stylesByName, wrapStyle, durationMs

  if held and context.verifyDescriptionTrees
    scanned = diagnostics.describeLine scanner\scan(rewrittenText), style, stylesByName, wrapStyle,
      durationMs
    assert described == scanned, msgs.normalizeLine.treeDescribesDifferently\format tostring(dialect),
      rewrittenText, described, scanned

  context.describedOriginal[dialect] == described

---Returns the value a run field holds at a given moment, applying the line's tags up to the given tag.
---@param context AssNormalizeContext
---@param dialect AssDialectName Whose reading to apply.
---@param until_ AssToken The tag to stop before.
---@param field AssRunField The field to read.
---@param atMs number The moment to read it at.
---@return any? value The field's value, or nil for a dialect without run comparison, which does not
---  track fields.
getValueInForce = (context, dialect, until_, field, atMs) ->
  return nil unless dialects[dialect].runComparison
  state = AssRunState styleFor(context, dialect), dialect, context.stylesByName
  state.time = atMs
  for token in *context.tokens
    break if token == until_
    continue unless token.kind == TokenKind.Tag
    state\applyTag token unless isKaraokeTagName token.name
  return state\getValue field

---Checks whether a dialect reads the original and the rewritten line alike when both are described at
---the same moments. Required to prevent rewrites that move a transform's end time (where it doesn't
---matter visually) from being rejected due to `diagnostics.describeLine()` picking different sample times.
---@param context AssNormalizeContext
---@param dialect AssDialectName Whose reading to apply.
---@param rewrittenText string The line the rewrite would produce.
---@param times integer[] The moments to describe both lines at.
---@return boolean equivalent True where the two descriptions match.
readsTheSameAtMoments = (context, dialect, rewrittenText, times) ->
  {:stylesByName, :wrapStyle, :durationMs} = context
  scanner = context.scannerByDialect[dialect]
  style = styleFor context, dialect
  return diagnostics.describeLine(getScannedOriginal(context, dialect), style, stylesByName, wrapStyle,
    durationMs, times) == diagnostics.describeLine scanner\scan(rewrittenText), style, stylesByName,
    wrapStyle, durationMs, times

---Returns the sample moments of the original and the rewritten line combined, under the first target.
---@param context AssNormalizeContext
---@param rewrittenText string The line the rewrite would produce.
---@return integer[] times Ascending.
getSampleTimesUnion = (context, rewrittenText) ->
  dialect = context.targets[1]
  scanner = context.scannerByDialect[dialect]
  merged, seen = {}, {}
  for tokens in *{getScannedOriginal(context, dialect), scanner\scan rewrittenText}
    for moment in *diagnostics.sampleTimesFor tokens, context.durationMs
      continue if seen[moment]
      seen[moment] = true
      merged[#merged + 1] = moment
  table.sort merged
  return merged

---Finds which syntax repairs could apply to the line, so that the others are not run.
---
---Each test here is deliberately weaker than the repair's own, leaving out whether a token was already
---refused and whether the rename would land on a different name, so a repair can be reported worth
---trying and then find nothing. Being wrong the other way would silently skip a repair the line wanted.
---@param tokens AssToken[] The stream as the scan left it.
---@param worthTrying? table<function, boolean> Filled in while recursing into nested streams.
---@return table<function, boolean> worthTrying The repairs that could apply, keyed by repair function.
findApplicableRepairs = (tokens, worthTrying = {}) ->
  for token in *tokens
    if token.kind == TokenKind.Tag
      worthTrying[renameFadeByArgumentCount] = true if token.name == TagName.Fade or
        token.name == TagName.FadeComplex
      worthTrying[closeArgumentList] = true if token.form and token.form.parenthesized and
        not token.form.argumentsClosed
      definition = overrideTags[token.name]
      worthTrying[removeUnreadBareTag] = true if definition and not definition.acceptsBareTag and
        (token.params or "")\match "^%s*$"
    elseif token.kind == TokenKind.Junk
      worthTrying[removeStrayBackslash] = true if isBackslashRun token
    findApplicableRepairs token.children, worthTrying if token.children
  return worthTrying

---Checks whether the line has a tag written without arguments that sets a run field, the only kind of
---tag seeds are read for.
---@param tokens AssToken[]
---@return boolean found True where such a tag exists, nested tags included.
hasBareRunFieldTag = (tokens) ->
  for token in *tokens
    if token.kind == TokenKind.Tag
      definition = overrideTags[token.name]
      return true if definition and definition.runFields and token.arguments and #token.arguments == 0
    return true if token.children and hasBareRunFieldTag token.children
  false

---Records the seed of each bare tag's run field at the tag's position, applying the line's tags in order
---so that a `\r` before the tag has changed the seeds.
---@param tokens AssToken[]
---@param seeds table<AssToken, table<AssDialectName, any>> Filled in as the walk goes.
---@param state AssRunState The run state the tags are applied to.
---@param dialect AssDialectName Whose reading that state holds.
readSeedsInto = (tokens, seeds, state, dialect) ->
  for token in *tokens
    if token.kind == TokenKind.Tag
      definition = overrideTags[token.name]
      if definition and definition.runFields and token.arguments and #token.arguments == 0
        seeds[token] or= {}
        seeds[token][dialect] = state.seeded[definition.runFields[1]]
      state\applyTag token unless isKaraokeTagName token.name
    readSeedsInto token.children, seeds, state, dialect if token.children

---Reads, under each target, the value each bare tag's run field was seeded with, which is what the tag
---restores unless it has a fixed `bareTagDefault`. The seed can differ by dialect: after a `\r` to another
---style, libass restores that style's value and VSFilter the line's own style's value. A reference dialect
---decides which one the line meant.
---@param context AssNormalizeContext
---@return table<AssToken, table<AssDialectName, any>> seeds Keyed by bare tag, then by dialect. Dialects
---  without run comparison and tags without a run field have no entry.
readBareTagSeeds = (context) ->
  -- Most lines have no bare tag setting a run field, so a cheap check skips the full walk, which applies
  -- every tag of the line once per target.
  {:tokens, :targets, :stylesByName} = context
  return {} unless hasBareRunFieldTag tokens

  seeds = {}
  for dialect in *targets
    continue unless dialects[dialect].runComparison
    state = AssRunState styleFor(context, dialect), dialect, stylesByName
    readSeedsInto tokens, seeds, state, dialect
  return seeds

---Returns the argument a bare tag has to be given for every target to draw what the reference dialect
---draws.
---@param seeds table<AssToken, table<AssDialectName, any>> The seed of each bare tag's run field, per
---  dialect.
---@param targets AssDialectName[] The dialects the result has to satisfy.
---@param referenceDialect? AssDialectName The reference dialect, if any.
---@param token AssToken The bare tag.
---@return string? params The argument, or nil where there is no reference dialect or the targets already
---  agree, in which case the tag stays bare.
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
  return emitSingleArgument reference, referenceDialect, token.name

---Checks whether a tag may be rewritten at all. It must set a field the run comparison reads, so the check
---has something to compare, or be one of three tags eligible by name: `\q` decides whether `\n` breaks the
---line, `\p` ends a karaoke syllable, and `\r` resets every field. A karaoke tag is eligible only when
---written bare with a `bareTagDefault`, since its argument is a duration.
---@param token AssToken The tag.
---@param definition AssTagDefinition The tag's definition.
---@return boolean eligible True where the tag may be rewritten.
isEligibleForCanonicalization = (token, definition) ->
  bareWithASpelling = token.arguments and #token.arguments == 0 and
    definition.bareTagDefault != nil

  return false if isKaraokeTagName(token.name) and not bareWithASpelling
  return true if bareWithASpelling or definition.runFields
  token.name == TagName.WrapStyle or token.name == TagName.Drawing or token.name == TagName.Reset

---Copies a stream deeply enough that rewriting one of them leaves the other alone, and pairs each
---token with its copy. `commands` and `signature` are shared, being documented read-only; `form` is
---copied, since the repairs and the argument rewrites write to it in place.
---@param tokens AssTokenStream The stream to copy.
---@param copyOf? table<AssToken, AssToken> Filled in as the copy is made, nested tags included.
---@return AssTokenStream copy With the same `dialect` as the stream given.
---@return table<AssToken, AssToken> copyOf The copy's token for each token of the stream given.
copyStream = (tokens, copyOf = {}) ->
  copy = {}
  for index, token in ipairs tokens
    one = {key, value for key, value in pairs token}
    one.arguments = [value for value in *token.arguments] if token.arguments
    one.form = {key, value for key, value in pairs token.form} if token.form
    one.children = copyStream token.children, copyOf if token.children
    copy[index] = one
    copyOf[token] = one
  copy.dialect = tokens.dialect
  copy, copyOf

---Collects every token a stream holds into a set, the ones nested in a tag's arguments included.
---@param tokens AssToken[]
---@param found? table<AssToken, true> Filled in while recursing into nested streams.
---@return table<AssToken, true> found The set of every token.
collectTokens = (tokens, found = {}) ->
  for token in *tokens
    found[token] = true
    collectTokens token.children, found if token.children
  found

---Collapses each comment block into a single comment token, in place.
---
---Only Aegisub scans such a block as a comment, and only where it contains no backslash. The renderers
---scan it as junk, split into several tokens wherever it contains a line break. Collapsing it gives every
---dialect the same token, holding exactly the text of the tokens it replaces, so the line emits unchanged.
---@param tokens AssTokenStream Rewritten in place.
mergeCommentBlocks = (tokens) ->
  commentTokens, commentText, runsInsideComment = diagnostics.findCommentBlocks tokens
  return unless next commentTokens

  kept = {}
  for token in *tokens
    continue if runsInsideComment[token]
    kept[#kept + 1] = commentTokens[token] and
      {kind: TokenKind.Comment, text: commentText[token]} or token

  held = #tokens
  tokens[index] = kept[index] for index = 1, #kept
  tokens[index] = nil for index = #kept + 1, held

---A tag a canonical form was found for, recorded before any rewrite is applied.
---@class AssNormalizeCandidate
---@field token AssToken The tag.
---@field transforms AssToken[] The transforms holding it.
---@field tagIndex integer Its index in walk order, which identifies the same tag in every description tree.
---@field written string The arguments as written.
---@field canonical string The arguments to write in their place.
---@field parenthesesDropped? boolean Whether the canonical form leaves out the parentheses the line wrote.
---@field stealsCloser? boolean Whether the `)` that closed those parentheses was taken by the transform
---  holding the tag for its own argument list, so it has to go with them.
---@field writtenClosed? boolean Whether the line closed the tag's own argument list.

---Writes a candidate's canonical or written arguments into a tag.
---@param token AssToken The candidate's tag, or its counterpart in a description tree.
---@param candidate AssNormalizeCandidate
---@param inCanonicalForm boolean Whether to write the canonical arguments rather than restore the written ones.
applyCandidate = (token, candidate, inCanonicalForm) ->
  token.params = inCanonicalForm and candidate.canonical or candidate.written
  if candidate.parenthesesDropped and token.form
    token.form.parenthesized = not inCanonicalForm and true or nil
    token.form.argumentsClosed = not inCanonicalForm and candidate.writtenClosed or nil

---Compares two canonical forms the targets offer for a tag, for sorting: the longer first, so an explicit
---value precedes a bare tag, and alphabetically where the lengths are equal.
---@param a string
---@param b string
---@return boolean aFirst True where `a` sorts before `b`.
compareOffers = (a, b) ->
  return #a > #b if #a != #b
  a < b

---Removes the `)` a transform took from a nested tag from the junk token after that transform, or
---restores it.
---@param context AssNormalizeContext
---@param siblings AssToken[] The stream the transform is in.
---@param transform AssToken The outermost transform holding the rewritten tag.
---@param canonical boolean Whether the tag is being written without its parentheses.
writeStolenCloser = (context, siblings, transform, canonical) ->
  closerRunAsWritten = context.closerRunAsWritten
  for index = 1, #siblings - 1
    continue unless siblings[index] == transform
    run = siblings[index + 1]
    break unless run and run.kind == TokenKind.Junk and run.text
    written = closerRunAsWritten[run] or run.text
    break unless written\sub(1, 1) == Syntax.ArgumentListClose
    closerRunAsWritten[run] = written
    run.text = canonical and written\sub(2) or written
    break

---Writes a candidate's canonical or written arguments into the stream being rewritten and into every
---description tree, so that all of them match the emitted line.
---@param context AssNormalizeContext
---@param candidate AssNormalizeCandidate The tag being rewritten and where it sits.
---@param inCanonicalForm boolean Whether to write the canonical arguments rather than restore the written ones.
writeArgument = (context, candidate, inCanonicalForm) ->
  applyCandidate candidate.token, candidate, inCanonicalForm
  regenerateTransformArguments candidate.transforms
  writeStolenCloser context, context.tokens, candidate.transforms[1], inCanonicalForm if candidate.stealsCloser
  trees = context.descriptionTrees
  return unless trees
  for dialect, held in pairs trees
    mirrored = held.tags[candidate.tagIndex]
    applyCandidate mirrored.token, candidate, inCanonicalForm
    tagArguments.reparseToken mirrored.token, dialect
    regenerateTransformArguments mirrored.transforms, dialect
    writeStolenCloser context, held.tree, mirrored.transforms[1], inCanonicalForm if candidate.stealsCloser

---Records an accepted rewrite as a change.
---@param context AssNormalizeContext
---@param candidate AssNormalizeCandidate
---@param converged AssDialectName[] The targets that accepted it only by following the reference.
recordAccepted = (context, candidate, converged) ->
  token = candidate.token
  changes = context.changes
  changes[#changes + 1] = {
    kind: ChangeKind.Tag
    before: {context.copyOf[token]}
    after: {token}
    converged: #converged > 0 and converged or nil
  }

---Applies a single candidate and keeps it where every target accepts it. This is where a reference
---dialect can bring the targets that read the line differently onto its reading. Only called for a
---candidate whose batch was refused.
---@param context AssNormalizeContext
---@param candidate AssNormalizeCandidate
---@return boolean accepted Whether it was kept, in which case it is left applied.
settleOne = (context, candidate) ->
  {:targets, :referenceDialect, :scannerByDialect, :stylesByName, :wrapStyle} = context
  {:token, :written, :canonical} = candidate
  writeArgument context, candidate, true
  rewrittenText = emit context.tokens

  accepting = [dialect for dialect in *targets when readsTheSame context, dialect, rewrittenText]
  acceptedBy = {dialect, true for dialect in *accepting}
  converged = {}

  -- a rewrite must not change how the reference reads the line
  if referenceDialect and acceptedBy[referenceDialect]
    referenceTokens = scannerByDialect[referenceDialect]\scan rewrittenText
    referenceReading = diagnostics.describeKaraokeSyllables referenceTokens, referenceDialect, styleFor(context, referenceDialect), stylesByName, wrapStyle
    referenceAppearance = diagnostics.describeCanonicalAppearance referenceTokens, referenceDialect, styleFor(context, referenceDialect), stylesByName
    for dialect in *targets
      continue if acceptedBy[dialect]

      -- A target follows the reference on three counts: the rewritten argument reads at face value
      -- under it, it cuts the line into the same karaoke syllables, and it leaves the same run state.
      continue unless nil == canonicalArgumentFor token, dialect
      targetTokens = scannerByDialect[dialect]\scan rewrittenText
      continue unless referenceReading == diagnostics.describeKaraokeSyllables targetTokens, dialect, styleFor(context, dialect), stylesByName, wrapStyle

      -- a dialect without run comparison has no appearance to compare
      appearance = diagnostics.describeCanonicalAppearance targetTokens, dialect, styleFor(context, dialect), stylesByName
      continue unless referenceAppearance == nil or appearance == nil or referenceAppearance == appearance

      acceptedBy[dialect] = true
      accepting[#accepting + 1] = dialect
      converged[#converged + 1] = dialect

  if #accepting != #targets
    writeArgument context, candidate, false
    if #accepting > 0
      divergences = context.divergences
      divergences[#divergences + 1] = {
        tag: "#{token.name}#{written}"
        rewritten: "#{token.name}#{canonical}"
        :accepting
      }
    return false

  recordAccepted context, candidate, converged
  return true

---Settles the candidates from `first` to `last` by applying them together and checking the line once.
---Most lines accept every candidate, so a line usually costs a single check instead of one per tag. A
---refused batch is undone and halved, and the halves settled in order, so the candidates that spoil it
---are found in a number of checks proportional to how many there are, and each candidate is still checked
---against those kept before it.
---@param context AssNormalizeContext
---@param first integer First candidate in the run, inclusive.
---@param last integer Last, inclusive.
settleRange = (context, first, last) ->
  return if first > last
  candidates = context.candidates
  if first == last
    settleOne context, candidates[first]
    return

  writeArgument context, candidates[at], true for at = first, last
  rewrittenText = emit context.tokens

  -- Stops at the first target that reads the batch differently. Every halving of a refused batch comes
  -- through here, so the early exit saves more than the number of refusals suggests.
  accepted = true
  for dialect in *context.targets
    continue if readsTheSame context, dialect, rewrittenText
    accepted = false
    break

  if accepted
    recordAccepted context, candidates[at], {} for at = first, last
    return

  writeArgument context, candidates[at], false for at = first, last
  middle = math.floor (first + last) / 2
  settleRange context, first, middle
  settleRange context, middle + 1, last

---Returns a tag as the line wrote it, without its backslash, for a divergence to be reported against.
---@param context AssNormalizeContext
---@param token AssToken A token of the stream being rewritten.
---@return string written The tag's written text.
getWrittenTag = (context, token) ->
  -- Mapped over `original`, since a kept rewrite moves the stream being rewritten off the byte offsets
  -- of `text`, and only on first use, since most lines have no refusal to report.
  spans = context.spans
  unless spans
    spans = diagnostics.mapTokenSpans context.original
    context.spans = spans
  span = spans[context.copyOf[token]]
  context.text\sub span.startIndex + 1, span.endIndex

---Keeps an already applied rewrite where every target reads the line as it read the original, and undoes
---it otherwise. Where only some targets accept it, the refusal is reported as a divergence.
---@param context AssNormalizeContext
---@param token AssToken The token of the stream the rewrite started from, which the change and any
---  divergence are reported against.
---@param after AssToken[] The tokens now in its place, in stream order.
---@param undo fun() Puts the stream back as it was.
---@return boolean accepted True where the rewrite was kept.
settleRewrite = (context, token, after, undo) ->
  {:targets, :changes} = context
  rewrittenText = emit context.tokens
  accepting = [dialect for dialect in *targets when readsTheSame context, dialect, rewrittenText]
  if #accepting == #targets
    changes[#changes + 1] = {kind: ChangeKind.Tag, before: {context.copyOf[token]}, :after}
    return true

  undo!
  if #accepting > 0
    divergences = context.divergences
    divergences[#divergences + 1] = {tag: getWrittenTag(context, token), rewritten: "", :accepting}
  return false

---Copies the stream into `original`, unless a copy was already taken.
---
---Every pass calls this right before it first edits the stream. Where no pass edits anything, which is
---most lines, no copy is made and `normalizeLine` returns the stream itself as the original.
---@param context AssNormalizeContext
snapshotOriginal = (context) ->
  return if context.original
  context.original, context.copyOf = copyStream context.tokens

---Checks whether any top-level token has nested children, which the transform passes need in order to find
---anything to do.
---@param tokens AssToken[]
---@return boolean found True where some top-level token has children.
hasNestedStream = (tokens) ->
  return true for token in *tokens when token.children
  return false

syntaxRepairs = {renameFadeByArgumentCount, closeArgumentList, removeStrayBackslash, removeUnreadBareTag}

---Repairs malformed syntax and tag names, so that the argument canonicalization after it works on
---well-formed tags. Each repair scans the whole line and usually finds nothing, so a single walk first
---finds which of the four could apply.
---@param context AssNormalizeContext
repairSyntax = (context) ->
  tokens = context.tokens
  worthTrying = findApplicableRepairs tokens
  return unless next worthTrying
  snapshotOriginal context
  for findRepair in *syntaxRepairs
    continue unless worthTrying[findRepair]
    refused = {}
    while true
      token, undo = findRepair tokens, refused
      break unless token
      -- prevents a repair that not every target accepted from being proposed again in the next pass
      refused[token] = true unless settleRewrite context, token, {token}, undo

---Closes each transform at the moment its animated value crosses the lower bound its field is clamped to,
---and animates it to the bound. The renderers draw the bound from the crossing onward, so the line draws
---the same and leaves no out-of-range value behind. The acceleration is kept as written, since shortening
---the window scales the progress by exactly the factor that the bound's share of the distance cancels.
---
---Runs only with approximate normalizations allowed, since a crossing rounded to a whole millisecond
---moves the picture by a bounded amount.
---@param context AssNormalizeContext
clampTransforms = (context) ->
  return unless context.allowApproximateNormalizations
  -- `copyOf` is not unpacked here, since it stays nil until this pass takes the snapshot
  {:tokens, :targets, :changes, :divergences, :allowRoundedTransformCrossings,
    :largestAcceptedError} = context
  for transform in *tokens
    continue unless transform.kind == TokenKind.Tag and transform.name == TagName.Transform
    children = transform.children or {}
    -- A timing prefix and a single animated tag. With several tags, each would cross its bound at a
    -- different moment.
    continue unless #children == 2 and children[1].kind == TokenKind.Junk and children[2].kind == TokenKind.Tag
    animated = children[2]
    definition = overrideTags[animated.name]
    continue unless definition and definition.runFields
    field = definition.runFields[1]

    arguments = transform.arguments or {}
    continue unless #arguments >= 3 and "number" == type(arguments[1]) and "number" == type arguments[2]
    openedAt, closedAt = arguments[1], arguments[2]
    acceleration = #arguments >= 4 and "number" == type(arguments[3]) and arguments[3] or 1

    -- A transform has a single closing time, so every target has to cross the bound at the same rounded
    -- millisecond. The exact crossing is kept to measure the rounding error.
    crossing, closingTime, bound, startValue = nil, nil, nil, nil
    for dialect in *targets
      reading = getArgumentReading animated.name, dialect
      dialectBound = reading and reading.minimum
      held = dialectBound and getValueInForce context, dialect, transform, field, openedAt
      written = tagArguments.parseNumber animated.params or "",
        dialects[dialect].readsHexAndNonFiniteNumbers
      moment = "number" == type(held) and
        getBoundCrossingTime held, written, dialectBound, openedAt, closedAt, acceleration
      unless moment
        closingTime = nil
        break
      rounded = math.floor moment + 0.5
      if closingTime == nil
        crossing, closingTime, bound, startValue = moment, rounded, dialectBound, held
      elseif closingTime != rounded or bound != dialectBound
        closingTime = nil
        break
    continue unless closingTime and closingTime > openedAt and closingTime < closedAt

    writtenPrefix, writtenParams = children[1].text, animated.params

    -- Transform times are whole milliseconds, so a fractional crossing is rounded, which slightly changes
    -- the interpolated values before it.
    roundingError = getLargestCrossingError startValue, crossing, closingTime, openedAt, acceleration
    if roundingError > 0
      continue unless allowRoundedTransformCrossings
      continue if largestAcceptedError and roundingError > largestAcceptedError

    rewrittenPrefix = withTransformClosingTime transform, closingTime
    continue unless rewrittenPrefix

    snapshotOriginal context
    children[1].text = rewrittenPrefix
    animated.params = emitSingleArgument bound, targets[1], animated.name
    regenerateTransformArguments {transform}, targets[1]

    -- A rounded crossing moves the picture, so the check would refuse it
    local accepting
    accepted = roundingError > 0
    unless accepted
      rewrittenText = emit tokens
      times = getSampleTimesUnion context, rewrittenText
      accepting = [dialect for dialect in *targets when readsTheSameAtMoments context, dialect, rewrittenText, times]
      accepted = #accepting == #targets

    if accepted
      changes[#changes + 1] = {
        kind: ChangeKind.Tag
        before: {context.copyOf[transform]}
        after: {transform}
      }
    else
      -- An exact crossing draws every moment identically, so this catches defects other than rounding.
      children[1].text, animated.params = writtenPrefix, writtenParams
      regenerateTransformArguments {transform}, targets[1]
      if #accepting > 0
        divergences[#divergences + 1] = {tag: getWrittenTag(context, transform), rewritten: "", :accepting}

---Rewrites each tag whose arguments do not read at face value into their canonical form, settling the
---candidates in batches against every target's reading of the line.
---@param context AssNormalizeContext
settleArguments = (context) ->
  {:tokens, :targets, :referenceDialect, :candidates} = context
  seeds = readBareTagSeeds context
  tagIndex = 0

  for token, transforms in iterateTags tokens
    tagIndex += 1
    definition = overrideTags[token.name]
    continue unless definition
    continue unless isEligibleForCanonicalization token, definition

    local canonical, parenthesesDropped
    canonical, parenthesesDropped = canonicalArgumentFor token, referenceDialect if referenceDialect
    -- Targets can canonicalize a tag differently. For a color literal without digits, a dialect that
    -- refuses it offers the bare tag while the other offers the value it reads. Sorting makes the choice
    -- independent of target order and prefers the explicit value, so `\1a&H&` becomes `\1a&H00&` where
    -- the check accepts it.
    if canonical == nil
      offers = {}
      for dialect in *targets
        offered, offeredParensDropped = canonicalArgumentFor token, dialect
        continue if offered == nil
        offers[#offers + 1] = offered
        -- every offer agrees on dropping parentheses, since that depends only on the tag
        parenthesesDropped = offeredParensDropped
      table.sort offers, compareOffers
      canonical = offers[1]

    if token.arguments and #token.arguments == 0
      canonical or= getConvergingArgumentForBareTag seeds, targets, referenceDialect, token
    continue unless canonical != nil

    stealsCloser = parenthesesDropped and #transforms > 0 and token.form and
      token.form.parenthesized and not token.form.argumentsClosed

    candidates[#candidates + 1] = {:token, :transforms, :tagIndex, written: token.params, :canonical
      :parenthesesDropped, :stealsCloser, writtenClosed: token.form and token.form.argumentsClosed}

  -- Built after the syntax repairs, which change the tags the trees have to match, and only where there
  -- are candidates, which most lines do not have. Each rewrite then edits the trees along with the
  -- stream, so a check describes a kept tree instead of re-scanning the text for every target.
  if #candidates > 0
    snapshotOriginal context
    context.descriptionTrees = buildDescriptionTrees targets, tokens, emit tokens
    settleRange context, 1, #candidates

  -- Later passes edit drawings and move tags, which `writeArgument` does not mirror into the trees, so
  -- later checks scan the text instead.
  context.descriptionTrees = nil

---Checks whether the line has a karaoke tag, including tags nested in transforms.
---@param tokens AssToken[]
---@return boolean found True where the line has a karaoke tag.
hasKaraokeTag = (tokens) ->
  for token in *tokens
    return true if token.kind == TokenKind.Tag and isKaraokeTagName token.name
    return true if token.children and hasKaraokeTag token.children
  false

---Rewrites each drawing into its canonical form, which is the reference dialect's reading where one is
---given. A drawing the reference does not draw at all is removed. The other targets are brought onto the
---reference's reading where they can follow it.
---@param context AssNormalizeContext
rewriteDrawings = (context) ->
  -- `copyOf` is not unpacked here, since it stays nil until this pass takes the snapshot
  {:tokens, :targets, :referenceDialect, :text, :scannerByDialect, :stylesByName, :changes,
    :divergences} = context

  -- set on first use, since the answer is the same for every drawing of the line
  local holdsKaraoke

  for token in *tokens
    continue unless token.kind == TokenKind.Drawing
    commands = token.commands or {}

    canonical, reduced = canonicalizeDrawing commands, referenceDialect
    continue unless reduced

    if referenceDialect and #canonical == 0
      -- A drawing sets no style field, so removing it can only change the appearance and the karaoke
      -- timing. A drawing ends a karaoke syllable whether or not it draws anything, so it is kept on any
      -- line with a karaoke tag, and elsewhere only the appearance is checked.
      holdsKaraoke = hasKaraokeTag tokens if holdsKaraoke == nil
      continue if holdsKaraoke
      snapshotOriginal context
      written = token.text
      token.text = ""
      rewrittenText = emit tokens
      appearanceHolds = true
      for dialect in *targets
        scanner = scannerByDialect[dialect]
        before = diagnostics.describeCanonicalAppearance scanner\scan(text), dialect, styleFor(context, dialect), stylesByName
        after = diagnostics.describeCanonicalAppearance scanner\scan(rewrittenText), dialect, styleFor(context, dialect), stylesByName
        appearanceHolds = false unless before == after
      if appearanceHolds
        token.commands = nil
        changes[#changes + 1] = {
          kind: ChangeKind.Drawing, before: {context.copyOf[token]}, after: {token}
          converged: {referenceDialect}
        }
      else
        token.text = written
        divergences[#divergences + 1] = {tag: written, rewritten: "", accepting: {referenceDialect}}
      continue

    snapshotOriginal context
    written = token.text
    token.text = canonical
    rewrittenText = emit tokens

    accepting = [dialect for dialect in *targets when readsTheSame context, dialect, rewrittenText]
    acceptedBy = {dialect, true for dialect in *accepting}
    converged = {}

    if referenceDialect and acceptedBy[referenceDialect]
      -- A target follows the reference where it now reads the rewritten drawing as the reference
      -- reads it, which is the only thing a dialect can disagree about here.
      referenceReading = canonicalizeDrawing parseDrawing(canonical), referenceDialect
      for dialect in *targets
        continue if acceptedBy[dialect]
        continue unless referenceReading == canonicalizeDrawing parseDrawing(canonical), dialect
        acceptedBy[dialect] = true
        accepting[#accepting + 1] = dialect
        converged[#converged + 1] = dialect

    if #accepting == #targets
      token.commands = nil
      changes[#changes + 1] = {
        kind: ChangeKind.Drawing, before: {context.copyOf[token]}, after: {token}
        converged: #converged > 0 and converged or nil
      }
    else
      token.text = written
      if #accepting > 0
        divergences[#divergences + 1] = {tag: written, rewritten: canonical, :accepting}

---Moves each transform nested in another out to stand after it, which is how both renderers read them,
---until a split is refused.
---@param context AssNormalizeContext
flattenNestedTransforms = (context) ->
  tokens = context.tokens
  return unless hasNestedStream tokens
  snapshotOriginal context
  while true
    outer, inner, undo = splitNestedTransform tokens
    break unless outer
    break unless settleRewrite context, outer, {outer, inner}, undo

---Lifts each tag a transform does not interpolate out of the transform and in front of it, since such a
---tag applies in full from the first frame.
---@param context AssNormalizeContext
liftAppliedWholeTags = (context) ->
  tokens = context.tokens
  return unless hasNestedStream tokens
  snapshotOriginal context
  refused = {}
  while true
    transform, lifted, undo = liftAppliedWholeTagOutOfTransform tokens, refused
    break unless transform
    -- prevents a lift that not every target accepted from being proposed again in the next pass
    refused[lifted] = true unless settleRewrite context, transform, {lifted, transform}, undo

---Fixes the defects in a line's override tags and drawings, such as an unclosed argument
---list, a refused value that acts as the bare tag, a negative value a renderer clamps to zero, or a
---transform nested in another. Every tag without a defect is left byte for byte, even where it is
---redundant, since tidying a well-formed line is a separate concern from repairing a defective one.
---
---A tag whose fields the run comparison does not read is left alone, because the check would accept any
---rewrite of it without evidence. `\q`, `\p` and `\r` are exceptions: `\q` decides where `\n` breaks the
---line, `\p` ends a karaoke syllable, and `\r` resets every field. A karaoke tag is rewritten only where
---written bare with a `bareTagDefault`, since its argument is a duration and rewriting it would change
---the timing.
---@param line string|AegisubDialogueLine The line to rewrite, or only its text. With only the text, the
---  style is not resolved, a karaoke template is treated as an ordinary line, and a transform without an
---  interval is read as animating over a default duration.
---@param options? AssNormalizeOptions Options, all optional.
---@return AssTokenStream tokens The rewritten line, read under the reference dialect where one is given
---  and under the first target otherwise. `emit` writes it back out as text, and where nothing needed
---  rectifying that text is the input byte for byte.
---@return AssTokenStream original The line as it arrived, untouched by the rewrites. It emits as the
---  text that came in, and every way it differs from the rewritten stream is one of the changes below,
---  so `getChangeSpans` can locate a change in both. Must not be written to, because where no pass edited
---  anything, which is most lines, this is the rewritten stream itself.
---@return AssNormalizeDivergence[] divergences The rewrites only some targets accepted, all undone.
---@return AssNormalizeChange[] changes The rewrites that were kept, in the order the passes made them.
---  `getChangeSpans` locates each in both lines.
---@return AegisubStyleLine? styleToDeclare A style to add to the script, for a line whose Style field
---  refers to a style the script does not declare. Each target otherwise draws such a line in its own
---  fallback style, and these differ. Declaring this style keeps the reference's picture and brings every
---  other target onto it, without editing the line. Nil unless a reference dialect is given.
normalizeLine = (line, options = {}) ->
  {:style, :stylesByName, :wrapStyle, :referenceDialect, :allowApproximateNormalizations,
    :allowRoundedTransformCrossings, :largestAcceptedError, :verifyDescriptionTrees} = options

  text, styleName, effect, durationMs = line, nil, nil, nil
  unless "string" == type line
    text, styleName, effect = line and line.text, line and line.style, line and line.effect
    -- A zero-length line gives a transform without an interval nothing more to animate over than a line
    -- without timings, so both use the default duration.
    spanMs = line and (line.end_time or 0) - (line.start_time or 0) or 0
    durationMs = spanMs > 0 and spanMs or nil
  text or= ""

  targets = options.targets or defaultTargets

  if referenceDialect
    isTarget = false
    isTarget = true for dialect in *targets when dialect == referenceDialect
    assert isTarget, msgs.normalizeLine.referenceOutsideTargets\format tostring(referenceDialect)

  -- Rewrites are made on a single stream, read under this dialect, and checked against every target's
  -- own reading.
  workingDialect = options.tokens and options.tokens.dialect or referenceDialect or targets[1]
  if options.tokens and referenceDialect
    assert options.tokens.dialect == referenceDialect,
      msgs.normalizeLine.tokensDialectMismatch\format tostring(options.tokens.dialect),
        tostring referenceDialect

  -- A karaoke template is expanded before any renderer sees it, so there is no drawn line to check a
  -- rewrite against. It is returned as a single junk token, so that templater code is not read as tags.
  -- `E-KARAOKE-TEMPLATE-SYNTAX` reports it.
  if diagnostics.isKaraokeTemplateSource text, effect
    source = {{kind: TokenKind.Junk, :text}}
    source.dialect = workingDialect
    return source, source, {}, {}

  scannerByDialect = {dialect, getScanner dialect for dialect in *targets}
  tokens = options.tokens
  if tokens
    -- taken from the stream, not the Text field, so the changes and the checks agree on the bytes
    text = emit tokens
  else tokens = scannerByDialect[workingDialect]\scan text

  -- Before any pass, so that no pass takes a comment's words for junk. The emitted text stays the same,
  -- so it is not recorded as a change.
  mergeCommentBlocks tokens

  -- Built in one constructor so the table is sized once. `original`, `copyOf`, `descriptionTrees` and
  -- `spans` are set later, only on the lines that need them.
  context = {
    :text, :tokens, :targets, :referenceDialect, :style, :styleName, :stylesByName
    :wrapStyle, :durationMs, :scannerByDialect, :verifyDescriptionTrees
    :allowApproximateNormalizations, :allowRoundedTransformCrossings, :largestAcceptedError
    changes: {}
    divergences: {}
    styleByDialect: {}
    describedOriginal: {}
    scannedOriginal: {}
    candidates: {}
    closerRunAsWritten: {}
  }
  {:changes, :divergences} = context

  -- Declaring the style fixes every line of the script that uses the undeclared style, without editing
  -- any of them, so it is returned for the script to declare.
  styleToDeclare = nil
  if styleName and stylesByName and referenceDialect
    keptByReference = dialects[referenceDialect].fallbackStyle
    if keptByReference
      resolved, _, declarationFound = resolveStyle stylesByName, styleName, keptByReference
      styleToDeclare = keptByReference if resolved == keptByReference and not declarationFound

  repairSyntax context
  clampTransforms context
  settleArguments context
  rewriteDrawings context
  flattenNestedTransforms context
  liftAppliedWholeTags context

  -- A later pass can remove a token an earlier change listed, so each change's `after` is filtered to
  -- the tokens still in the stream. A change left with an empty `after` is a removal.
  if #changes > 0
    surviving = collectTokens tokens
    for change in *changes
      change.after = [token for token in *change.after when surviving[token]]

  return tokens, context.original or tokens, divergences, changes, styleToDeclare

---The byte ranges a change covers in the original and in the rewritten line.
---
---A span brackets exactly what `emit` writes for the tokens on that side, a tag's own backslash
---included, which is the same range a finding reports for the same tag.
---@class AssNormalizeChangeSpans
---@field startIndex integer 1-based first byte of the change in the original line.
---@field endIndex integer 1-based last byte, inclusive. One less than `startIndex` where the change has no
---  original tokens.
---@field rewrittenStartIndex integer 1-based first byte of the change in the rewritten line.
---@field rewrittenEndIndex integer 1-based last byte, inclusive. One less than `rewrittenStartIndex`
---  where the tokens were removed, so that the pair marks the point they were removed from.

---Locates every change in the original line and in the rewritten line.
---
---A removal has no tokens in the rewritten line, so its span there is empty, placed where the tokens were
---by how far the earlier rewrites have shifted the text. Consecutive removals share the same point.
---@param changes AssNormalizeChange[] The changes `normalizeLine` returned.
---@param originalTokens AssTokenStream The original stream `normalizeLine` returned.
---@param normalizedTokens AssTokenStream The rewritten stream `normalizeLine` returned.
---@return AssNormalizeChangeSpans[] spans One per change, in the order the changes were given.
getChangeSpans = (changes, originalTokens, normalizedTokens) ->
  originalSpans = diagnostics.mapTokenSpans originalTokens
  rewrittenSpans = diagnostics.mapTokenSpans normalizedTokens

  ---Returns the byte range a list of tokens covers in a stream, or nil where the stream has none of them.
  ---@param run AssToken[]
  ---@param spans table<AssToken, table>
  ---@return integer? startIndex The first byte.
  ---@return integer? endIndex The last byte, inclusive.
  coveredBy = (run, spans) ->
    startIndex, endIndex = nil, nil
    for token in *run
      span = spans[token]
      continue unless span
      startIndex = span.startIndex if not startIndex or span.startIndex < startIndex
      endIndex = span.endIndex if not endIndex or span.endIndex > endIndex
    startIndex, endIndex

  found = {}
  for index, change in ipairs changes
    startIndex, endIndex = coveredBy change.before, originalSpans
    rewrittenStartIndex, rewrittenEndIndex = coveredBy change.after, rewrittenSpans
    found[index] = {
      at: index
      startIndex: startIndex or 1
      endIndex: endIndex or 0
      :rewrittenStartIndex, :rewrittenEndIndex
    }

  -- Passes record changes in their own order, and the running shift between the two texts is only
  -- meaningful in line order.
  inLineOrder = [one for one in *found]
  table.sort inLineOrder, (a, b) -> a.startIndex < b.startIndex

  moved = 0
  for one in *inLineOrder
    if one.rewrittenStartIndex
      -- where the rewrite is still in the line, the stream says exactly where, and how far everything
      -- after it has shifted
      moved = one.rewrittenEndIndex - one.endIndex
    else
      one.rewrittenStartIndex = one.startIndex + moved
      one.rewrittenEndIndex = one.rewrittenStartIndex - 1
      moved -= one.endIndex - one.startIndex + 1

  spans = {}
  for index, one in ipairs found
    spans[index] = {
      startIndex: one.startIndex
      endIndex: one.endIndex
      rewrittenStartIndex: one.rewrittenStartIndex
      rewrittenEndIndex: one.rewrittenEndIndex
    }
  return spans

---Fixes defects and degeneracies in a dialogue line's override tags and drawings, as a post-processor for
---a scan. Gives you a canonicalized, predictable token stream to work with, and removes the need to account
---for every malformed or degenerate form a line can take, or for how each renderer interprets one.
---
---The repairs cover syntax, such as an unclosed argument list or a stray backslash; arguments a renderer
---refuses, clamps or rounds; structure, such as a transform nested in another or a tag inside a transform
---that the transform does not animate; and drawings. Repairs that change the rendered output by a bounded
---amount are only made where the options allow them.
---
---Renderers interpret some defects differently. Given a reference dialect, a rewrite may change what the
---other targets draw, so that their output matches the reference's as far as possible, while the
---reference's own output stays the same. Without one, a rewrite is kept only where every target's output
---stays the same.
---@class AssNormalizer
normalizer = {
  :normalizeLine, :getChangeSpans
}

---The stages of a call, for this module's tests and cost probes to drive one at a time. The test
---suite's export helper is not used here because it loads the Aegisub shims, which the corpus harness
---and the probes run without.
---@private
normalizer.__internals = {
  :copyStream, :collectTokens, :mergeCommentBlocks, :findApplicableRepairs, :readBareTagSeeds,
  :iterateTags, :splitNestedTransform, :liftAppliedWholeTagOutOfTransform, :buildDescriptionTrees,
  :settleRange, :settleRewrite, :repairSyntax, :clampTransforms, :settleArguments, :rewriteDrawings,
  :flattenNestedTransforms, :liftAppliedWholeTags
}

return normalizer
