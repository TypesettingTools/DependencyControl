tagArguments = require "l0.AssParser.arguments"
{:readDrawing} = require "l0.AssParser.drawing"
{:TokenKind, :Syntax, :TagName, :dialects} = require "l0.AssParser.dialects"

msgs = {
  new: {
    unknownDialect: "No such dialect '%s'."
  }
}

-- What both renderers step over between the backslash and a tag name. Their `skip_spaces` takes a
-- space and a tab and nothing else, so a newline still breaks a name rather than padding it.
TOLERATED_TAG_NAME_PADDING = "^[ \t]"

---The characters a scan consumed on its way to a name and its arguments, which the name and
---arguments do not themselves hold: whitespace that was skipped, parentheses that were stripped, a
---backslash that turned a brace into text. They are kept so that `emit` can write the token back out
---as the text it was read from, and so that a tool rewriting one token disturbs no other byte.
---
---A token has a `form` only where one of these applies, so its absence means nothing was skipped,
---stripped or resolved while reading it.
---@class AssTokenForm
---@field whitespaceBeforeName? string Whitespace the dialect skipped between the backslash and the name.
---@field parenthesized? boolean Whether a tag's arguments were written in parentheses.
---@field argumentsClosed? boolean Whether that parenthesis was closed. Set only alongside `parenthesized`.
---@field trailing? string Characters a tag kept after its closing parenthesis, which only Aegisub reads.
---@field escaped? boolean Whether a text token's character was written as a backslash escape.

---One item of a scan: a brace, a tag, or a run of characters.
---@class AssToken
---@field kind AssTokenKind Which of the seven kinds this is.
---@field name? string A tag's name, without the backslash that introduced it. Matches the `AssTagName` values.
---@field params? string The raw text between a tag's name and the next tag or the block's end.
---@field arguments? any[] A tag's argument values, one per parameter of the matched signature, in the
---  form the scanning dialect reads them. Empty for a tag written bare, nil where no declared
---  signature takes the number of arguments found. Field is read-only: write edits back with
---  `emitArguments` and assign the result to `params`, which is what a tag is emitted from.
---@field signature? AssArgumentType[] The signature the arguments matched, nil alongside a nil or empty
---  `arguments`. Field is read-only.
---@field sizeIsRelative? boolean Whether a size argument names a scale of the size in force rather
---  than a size, which is what writing it with a sign does. Recorded because no typed value can show
---  it — `+10` and `10` are one number — and only `\fs` reads a sign that way, so this is nil on every
---  other tag. A sign anywhere else is part of the number and needs no field of its own. Field is
---  read-only.
---@field text? string A text, drawing, comment or junk token's characters. Written back out as it
---  stands, so it is where a rewrite of rendered text goes.
---@field commands? AssDrawingCommand[] A drawing token's commands and their coordinates. Field is
---  read-only: write edits back with `emitDrawing` and assign the result to `text`, which is what a
---  drawing is emitted from.
---@field children? AssToken[] The stream parsed out of a tag's own arguments, as `\t` holds, junk and
---  all. Field is read-only: write edits back with `emit` and assign the result to `params`.
---@field form? AssTokenForm What the source spelling held beyond the reading, if anything.

---Splits a line's text into override blocks, tags and rendered text, reading it as one of Aegisub,
---libass or VSFilter would. The three disagree in some cases, so this may affect the results.
---
---A block runs from an opening brace to the first closing one in every dialect, and an unmatched opening
---brace is rendered as text. Drawing mode outlives the block that set it, so text is classified by the
---`\p` level in force where it is reached.
---
---A scan keeps every character it was given: `emit` writes a stream back out as the text it was read
---from, byte for byte, so one token can be rewritten and the rest of the line left untouched.
---@class AssOverrideScanner
---@field dialect AssDialect The dialect this scanner reads with. Read-only.
class AssOverrideScanner
  ---@param dialect string|AssDialect A dialect name, or a dialect table to read with directly.
  new: (dialect = "aegisub") =>
    -- a name that matches nothing has to fall through to the assert, which an `and`/`or` chain would
    -- defeat by handing back the name itself
    @dialect = if type(dialect) == "string" then dialects[dialect] else dialect
    assert @dialect, msgs.new.unknownDialect\format tostring(dialect)

  ---Finds the longest declared name that prefixes the text at `at`, which is how all three resolve
  ---an unknown name onto a shorter one it starts with.
  ---@param text string The block content being scanned.
  ---@param at integer Index of the first character of the name.
  ---@return string|nil name The longest declared name found there, or nil when none prefixes it.
  ---@return integer nextIndex Index just past the name, or `at` unchanged when none matched.
  ---@private
  __matchName: (text, at) =>
    {:tagNames, :longestTagName} = @dialect
    for length = math.min(longestTagName, #text - at + 1), 1, -1
      candidate = text\sub at, at + length - 1
      return candidate, at + length if tagNames[candidate]
    return nil, at

  ---Reads one tag's arguments, stopping where the dialect stops. A parenthesized list ends at the
  ---first `)` in every dialect; an unparenthesized one ends at the next backslash or the block's end.
  ---Aegisub keeps reading past that `)` until a backslash or the block's end, since a parenthesis only
  ---suspends its tag splitting rather than delimiting the arguments.
  ---@param text string The block content being scanned.
  ---@param at integer Index just past the tag's name.
  ---@return string params The argument text, without the parentheses where there were any.
  ---@return integer nextIndex Index of the first character the arguments did not consume.
  ---@return boolean parenthesized Whether the arguments were written in parentheses.
  ---@return boolean argumentsClosed Whether a closing parenthesis was found. Meaningless when unparenthesized.
  ---@return string? trailing Characters the tag kept after its closing parenthesis, where a dialect
  ---  reads any. Nil for the dialects whose arguments end at that parenthesis.
  ---@private
  __readParams: (text, at) =>
    return "", at, false, false if at > #text

    unless text\sub(at, at) == Syntax.ArgumentListOpen
      stop = text\find Syntax.TagPrefix, at, true
      stop or= #text + 1
      return text\sub(at, stop - 1), stop, false, false

    close = text\find Syntax.ArgumentListClose, at + 1, true

    -- an argument list with no closer runs to the block's end, which every dialect accepts
    return text\sub(at + 1), #text + 2, true, false unless close
    return text\sub(at + 1, close - 1), close + 1, true, true if @dialect.argumentsEndAtFirstParen

    -- A parenthesis only suspends Aegisub's tag splitting, until the first `)`, and the tag then runs
    -- on to the next backslash. So `{\clip(m 0 0 l (1 1))}` is one tag holding both parentheses, and
    -- `{\t(0,500,\bord2)x\shad3}` hands `\t` the stray `x` while still reading `\shad3`.
    stop = text\find Syntax.TagPrefix, close + 1, true
    stop or= #text + 1
    content = text\sub at + 1, stop - 1
    return content\sub(1, -2), stop, true, true if content\sub(-1) == Syntax.ArgumentListClose
    content\sub(1, close - at - 1), stop, true, true, content\sub close - at + 1

  ---Scans one override block's content, which is the text between the braces.
  ---@param content string The characters between the braces, excluding both.
  ---@return AssToken[] tokens Tags in the order written, with anything claiming no tag as junk.
  ---@private
  __scanBlock: (content) =>
    tokens = {}
    unless content\find Syntax.TagPrefix, 1, true
      -- Brace content holding no backslash. Aegisub gives it a block type of its own; the other two
      -- skip it while looking for a backslash and render nothing. The characters are emitted either
      -- way, so a scan can always rebuild the line it was given, and the kind is what says whether
      -- anything renders.
      if #content > 0
        kind = @dialect.hasCommentBlockType and TokenKind.Comment or TokenKind.Junk
        tokens[1] = {:kind, text: content}
      return tokens

    index, skippedFrom = 1, nil

    -- characters no tag claimed still have to reach the stream, or the block cannot be rebuilt
    flushSkipped = (upTo) ->
      return unless skippedFrom
      tokens[#tokens + 1] = {kind: TokenKind.Junk, text: content\sub skippedFrom, upTo}
      skippedFrom = nil

    while index <= #content
      unless content\sub(index, index) == Syntax.TagPrefix
        skippedFrom or= index
        index += 1
        continue

      flushSkipped index - 1
      nameAt = index + 1
      if @dialect.skipsWhitespaceAfterBackslash
        while content\match TOLERATED_TAG_NAME_PADDING, nameAt
          nameAt += 1
      whitespaceBeforeName = content\sub index + 1, nameAt - 1

      name, after = @__matchName content, nameAt
      unless name
        -- a backslash matching no declared name; the run to the next one is junk
        stop = content\find Syntax.TagPrefix, index + 1, true
        stop or= #content + 1
        tokens[#tokens + 1] = {kind: TokenKind.Junk, text: content\sub index, stop - 1}
        index = stop
        continue

      params, nextIndex, parenthesized, argumentsClosed, trailing = @__readParams content, after
      token = {kind: TokenKind.Tag, :name, :params}
      token.arguments, token.signature, token.sizeIsRelative = tagArguments.parse(@dialect.name, name,
        params, parenthesized)

      -- what the source held that the reading above does not show
      form = {}
      form.whitespaceBeforeName = whitespaceBeforeName if #whitespaceBeforeName > 0
      if parenthesized
        form.parenthesized = true
        form.argumentsClosed = argumentsClosed
        form.trailing = trailing if trailing and #trailing > 0
      token.form = form if next(form)

      -- The whole of a transform's arguments is scanned as though it were an override block, timings
      -- included rather than the nested tags alone, so everything around them is kept as junk. Emitting
      -- `children` then reproduces `params` byte for byte, which is what lets an edit to a nested tag
      -- be written back.
      if name == TagName.Transform and params\find Syntax.TagPrefix, 1, true
        children = @__scanBlock params
        token.children = children if #children > 0

      tokens[#tokens + 1] = token
      index = nextIndex

    flushSkipped #content
    return tokens

  ---Splits a line's text into tokens under this scanner's dialect.
  ---@param text string The line's Text field.
  ---@return AssToken[] tokens A flat list, with a tag's own tags nested under `children`.
  scan: (text) =>
    tokens, index, drawingLevel = {}, 1, 0

    while index <= #text
      char = text\sub index, index

      nextChar = text\sub(index + 1, index + 1)
      if char == Syntax.EscapePrefix and @dialect.honorsBraceEscapes and (nextChar == Syntax.BlockOpen or nextChar == Syntax.BlockClose)
        -- an escaped brace is one literal character of text, and never opens a block.
        tokens[#tokens + 1] = {kind: TokenKind.Text, text: text\sub(index + 1, index + 1), form: {escaped: true}}
        index += 2
        continue

      if char == Syntax.BlockOpen
        close = text\find Syntax.BlockClose, index + 1, true
        if close
          tokens[#tokens + 1] = {kind: TokenKind.BlockStart}
          content = text\sub index + 1, close - 1
          for token in *@__scanBlock content
            tokens[#tokens + 1] = token
            if token.kind == TokenKind.Tag and token.name == TagName.Drawing
              -- the typed value rather than the text, so a scale of '2.5' enters at the 2 every
              -- implementation reads rather than at a level no renderer would use
              drawingLevel = token.arguments and token.arguments[1] or 0
          tokens[#tokens + 1] = {kind: TokenKind.BlockEnd}
          index = close + 1
          continue

      -- a plain text token ends either before an override block starts or before an escaped brace,
      -- the latter of which needs its own text token with the `escaped` form flag for the backslash
      -- to be added back (in the right place) when emitting the token stream.
      stop = index + 1
      while stop <= #text
        break if text\sub(stop, stop) == Syntax.BlockOpen
        if @dialect.honorsBraceEscapes and text\sub(stop, stop) == Syntax.EscapePrefix
          nextChar = text\sub stop + 1, stop + 1
          break if nextChar == Syntax.BlockOpen or nextChar == Syntax.BlockClose
        stop += 1

      kind = drawingLevel > 0 and TokenKind.Drawing or TokenKind.Text
      characters = text\sub index, stop - 1
      token = {:kind, text: characters}
      token.commands = readDrawing characters if kind == TokenKind.Drawing
      tokens[#tokens + 1] = token
      index = stop

    return tokens

return AssOverrideScanner
