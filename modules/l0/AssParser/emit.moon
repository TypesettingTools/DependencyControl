-- A source form the scanner learns to record is one this has to learn to write back. The corpus
-- asserts the round trip in both directions, so a form recorded but never emitted fails there.

{:TokenKind, :Syntax} = require "l0.AssParser.dialects"

---Writes one tag back out, including whatever its dialect skipped or resolved while reading it.
---@param token AssToken A token of kind `tag`. Only `params`, `name` and `form` are read, so an edit
---  to `arguments` or `children` must be committed to `params` first.
---@return string text The characters the scan read the tag from.
emitTag = (token) ->
  {:form} = token
  parts = {Syntax.TagPrefix, form and form.whitespaceBeforeName or "", token.name}
  if form and form.parenthesized
    parts[#parts + 1] = Syntax.ArgumentListOpen
    parts[#parts + 1] = token.params or ""
    parts[#parts + 1] = Syntax.ArgumentListClose if form.argumentsClosed
    parts[#parts + 1] = form.trailing if form.trailing
  else
    parts[#parts + 1] = token.params or ""

  return table.concat parts

---Writes a token stream back out as line text. Emitting a scan reproduces the text it was read from
---byte for byte, in every dialect, so rewriting one token leaves every other byte of the line alone.
---@param tokens AssToken[] A stream as `AssOverrideScanner\scan` returns, edited or not.
---@return string text The line text the stream stands for.
emit = (tokens) ->
  parts = {}
  for token in *tokens
    parts[#parts + 1] = switch token.kind
      when TokenKind.BlockStart then Syntax.BlockOpen
      when TokenKind.BlockEnd then Syntax.BlockClose
      when TokenKind.Tag then emitTag token
      when TokenKind.Text
        escaped = token.form and token.form.escaped
        escaped and "#{Syntax.EscapePrefix}#{token.text}" or token.text
      else token.text or ""

  return table.concat parts

---Writes a token stream back out as the text it was scanned from. Emitting is the scanner's inverse,
---so a stream that was not edited reproduces its source byte for byte.
---@class AssOverrideEmit
return {:emit, :emitTag}
