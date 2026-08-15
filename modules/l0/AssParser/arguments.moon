  -- cspell:ignore clipm -- a tag written against its argument
{:ColorNotation, :FontWeight, :WrapStyle, :emitColor, :parseColor} = require "l0.AssParser.ass"
{:ArgumentType, :Syntax, :TagName, :dialects, :getArgumentReading, :overrideTags} = require "l0.AssParser.dialects"

-- the one argument `\fn` reads as naming no font, which puts the style's back as a bare tag does
STYLE_FONT_NAME_TAG_VALUE = "0"

---Reads a number the way both renderers do, taking as much of a leading numeral as converts and
---nothing after it.
---@param text string The argument as the line wrote it.
---@return number
readNumber = (text) -> tonumber(text\match "^%s*[-+]?%d*%.?%d+") or 0

---Reads a whole number, stopping at the first character that is not part of one.
---@param text string The argument as the line wrote it.
---@return integer
readInteger = (text) -> tonumber(text\match "^%s*[-+]?%d+") or 0

---Reads one argument as the type it is declared with, before any dialect decides what to do with it.
---A flag is typed as an integer rather than a boolean so that `sanitizeArgument` can refuse one
---outside 0 and 1, which puts the style's own value back.
---@param argumentType AssArgumentType The type to read as.
---@param text string The argument as the line wrote it.
---@return any? value The typed value; the raw text for a tags or style-name argument; nil for a type holding none.
convert = (argumentType, text) ->
  switch argumentType
    when ArgumentType.Number, ArgumentType.SizeOrScale then readNumber text
    when ArgumentType.Integer, ArgumentType.Flag, ArgumentType.Weight then readInteger text
    when ArgumentType.Color, ArgumentType.Alpha then parseColor text
    when ArgumentType.Text, ArgumentType.Drawing then text\match "^%s*(.*)$"
    when ArgumentType.StyleName, ArgumentType.Tags then text
    else nil

---Whether a size names a scale of the size in force rather than a size outright, which is what a
---leading sign makes it. Asked of that one type alone: everywhere else a sign belongs to the number
---and is already in the value, so only here does it say something a typed value cannot. Nil for every
---other type, which says the question does not apply rather than that no sign was written.
---@param argumentType AssArgumentType The type the argument was read as.
---@param text string The argument as the line wrote it.
---@return boolean? relative
readRelativeSize = (argumentType, text) ->
  return nil unless argumentType == ArgumentType.SizeOrScale
  return nil != text\match "^%s*[-+]"

-- The longest argument list any tag declares, which `\fad` and `\fade` take. Splitting stops one part
-- beyond it, so an over-supplied list comes back too long to match any signature and the tag goes
-- unread, which is what both renderers do with one.
MAX_ARGUMENT_COUNT = 7

---Drops the whitespace around an argument that the dialect never reads. Trailing whitespace is dropped
---in every dialect, leading whitespace only in Aegisub.
---@param dialectName AssDialectName Whose reading to apply.
---@param text string The argument as the line wrote it.
---@return string trimmed Empty where the argument held nothing but whitespace.
trimArgument = (dialectName, text) ->
  trimmed = text\match "^(.-)%s*$"
  return trimmed unless dialects[dialectName].trimsLeadingWhitespaceInArguments
  trimmed\match "^%s*(.-)$"

---Splits an argument list on commas, up to the most any tag may take, so a list holding more than a
---tag's widest signature comes back too long to match it. A backslash ends the splitting, and
---everything from there on is one argument.
---@param params string The raw argument text.
---@param maxCount integer The most arguments to split out, the last holding whatever is left.
---@return string[] parts At least one, the last holding everything the splits left.
splitArguments = (params, maxCount) ->
  parts, rest = {}, params
  while #parts < maxCount - 1
    at = rest\find Syntax.ArgumentSeparator, 1, true
    break unless at

    -- a nested tag (e.g. `\t(0,500,\clip(1,2,3,4))`) can have its own commas we must not count;
    -- since nested tags are always the last argument, we can just stop when we encounter one
    nested = rest\find Syntax.TagPrefix, 1, true
    break if nested and nested < at

    parts[#parts + 1] = rest\sub 1, at - 1
    rest = rest\sub at + 1
  parts[#parts + 1] = rest
  parts

---The typed values one tag's argument text carries, against the signatures its tag declares. A tag
---taking one parameter reads its text whole, commas included, so a font name is never split.
---@param dialectName AssDialectName Whose reading of the types to apply.
---@param name AssTagName The tag the arguments belong to.
---@param params string The raw text after the tag's name.
---@param parenthesized? boolean Whether the arguments were written in parentheses. Only a parenthesized
---  list is split on commas, so `\pos40,40` reads as the one argument no signature of `\pos` takes and
---  the tag goes unread.
---@return any[]? values One per parameter — empty for a bare tag or a type holding no value, nil where no declared signature takes the number of arguments found.
---@return AssArgumentType[]? signature The signature the values matched, the tag's bare form where it
---  declares one and nothing was written, nil where no declared signature takes the count found.
---@return boolean? relative Whether a size argument names a scale of the size in force rather than an
---  absolute size. This additional hint is required, because ASS encodes the scale in the sign, which in
---  case of `\fs+10` is indistinguishable from the absolute size `\fs10` once converted to a number.
parse = (dialectName, name, params, parenthesized) ->
  definition = overrideTags[name]
  return nil unless definition
  params = trimArgument dialectName, params
  {:signatures} = definition

  -- An argument that was whitespace alone is gone by now, and the tag reads as the bare form: both
  -- renderers draw `{\bord }` as `{\bord}` rather than as a zero, and Aegisub reports an empty value.
  -- A tag declaring nothing but the bare form ignores whatever follows it (e.g. `\fsc0` reads as `\fsc`).
  if #params == 0 or #signatures == 0
    return nil unless definition.acceptsBareTag
    return {}, nil, nil

  -- A tag that reads its arguments only from a parenthesized list finds none where the line wrote no
  -- parenthesis, so nothing it declares can match. `\clip` is why this is a tag's own fact rather than
  -- the comma rule below: its path form takes one argument, which an unparenthesized list would
  -- otherwise satisfy, and `\clipm 0 0 l 50 0` draws as though no clip were written.
  return nil if definition.requiresParentheses and not parenthesized

  if #signatures == 1 and #signatures[1] == 1
    argumentType = getArgumentReading(dialectName, name).type or signatures[1][1]
    value = convert argumentType, params
    return (value != nil and {value} or {}), signatures[1], readRelativeSize argumentType, params

  -- Only a parenthesized list is split on commas; without one a tag takes everything after its name as a
  -- single argument, which no signature of more than one argument matches. Every tag declaring such a
  -- signature also requires parentheses, so no tag in the table reaches the unparenthesized side.
  parts = if parenthesized
    [trimArgument(dialectName, part) for part in *splitArguments params, MAX_ARGUMENT_COUNT + 1]
  else {params}

  match = nil
  for signature in *signatures
    if #signature == #parts
      match = signature
      break
  return nil unless match

  values = [convert match[index], parts[index] for index = 1, #parts]
  values, match, readRelativeSize match[1], parts[1]

---Applies transformations that reproduce dialect-specific internal representations of a tag argument
---after it has been read into a typed value.
---@param value any The value the argument's type produced.
---@param reading AssArgumentReading What this dialect does with it.
---@return any value Unchanged where it is not a number, since only a number can be rounded or held.
applyDialectSpecificReading = (value, reading) ->
  return value unless "number" == type value

  conversion = reading.conversion or {}
  if conversion.resolvesWeight
    value = switch value
      when 0 then FontWeight.Normal
      when 1 then FontWeight.Bold
      else value

  value = math.floor value + 0.5 if conversion.roundsToWhole
  value = math.max value, reading.minimum if reading.minimum
  value = math.min value, reading.maximum if reading.maximum
  return value

---Returns an argument's value where its type accepts it, and nil where it does not.
---@param argumentType AssArgumentType The type the tag declares for this position.
---@param value any? The value the type produced, as a scan read it.
---@return any? accepted The value unchanged, nil where its type refuses it.
sanitizeArgument = (argumentType, value) ->
  switch argumentType
    when ArgumentType.Text
      value != STYLE_FONT_NAME_TAG_VALUE and value or nil
    when ArgumentType.Flag
      (value == 0 or value == 1) and value or nil
    when ArgumentType.Weight
      (value == 0 or value == 1 or value >= 100) and value or nil
    else value

---Returns a typed argument in a dialect's own internal representation.
---@param argumentType AssArgumentType The type the tag declares for this position.
---@param value any? The value the type produced, as a scan read it.
---@param reading AssArgumentReading What the dialect in hand does with it once typed.
---@return any? held The value in that representation, nil where the argument's type refuses it.
interpret = (argumentType, value, reading) ->
  named = sanitizeArgument argumentType, value
  named != nil and applyDialectSpecificReading(named, reading) or nil

---Converts a number to a string for use in ASS tag arguments.
---Whole numbers are written without a decimal point and fractions without trailing
---zeros.
---@param value number The number to stringify.
---@return string text The stringified number.
emitNumber = (value) ->
  text = "%.14g"\format value
  return text unless text\find "e", 1, true

  -- `%g` reaches for an exponent below 1e-4 and above the precision it is given, and a tag holding
  -- one reads back as the mantissa alone, so those magnitudes get their digits written out in full
  text = ("%.14f"\format value)\gsub "0+$", ""
  return (text\gsub "%.$", "")

---Returns the given typed value as argument text, the way its type is written.
---@param argumentType AssArgumentType The type the value was read as.
---@param value any The typed value.
---@return string text
emitTypedValue = (argumentType, value) ->
  switch argumentType
    when ArgumentType.Color then emitColor value, ColorNotation.Color
    when ArgumentType.Alpha then emitColor value, ColorNotation.Alpha
    when ArgumentType.Number, ArgumentType.SizeOrScale, ArgumentType.Integer, ArgumentType.Flag, ArgumentType.Weight
      emitNumber value
    else tostring value

---Writes one tag's typed values back as argument text, which is what a rewrite of them has to be
---assigned to `params` for a tag to be emitted from.
---
---This is the inverse of `parse`, but a lossy one: reading drops the spelling that produced a
---value, so a tag written `\u1.5` comes back `\u1` and one written `\1cFF0000` comes back
---`\1c&HFF0000&`. What comes out is the canonical way of writing what the tag means to the dialect
---asked, so text that is already canonical survives a round trip and nothing else does.
---@param dialectName AssDialectName Whose reading the values were taken under.
---@param token AssToken The tag whose `arguments` are to be written.
---@return string? params The argument text, nil for a token holding no typed values to write.
emitArguments = (dialectName, token) ->
  {:arguments, :signature} = token
  return nil unless arguments
  -- a bare tag writes as empty rather than nil to tell it apart from a read failure
  return "" if #arguments == 0
  return nil unless signature

  parts = for index = 1, #arguments
    argumentType = index == 1 and getArgumentReading(dialectName, token.name).type or nil
    argumentType or= signature[index]
    emitTypedValue argumentType, arguments[index]

  parts[1] = "#{Syntax.PositiveRelativeSizeSign}#{parts[1]}" if token.sizeIsRelative and arguments[1] >= 0
  return table.concat parts, Syntax.ArgumentSeparator

---Reads the value one tag's argument has under one dialect, in the units the argument was written in,
---so it can go back into the tag it came from: `\b1` comes back as 1 even where the dialect holds it
---as a weight of 700. Refusal, clamping and rounding all apply, so the result is what the argument is
---interpreted as rather than its literal value.
---@param dialect AssDialectName Whose reading to apply.
---@param name AssTagName The tag the argument belongs to.
---@param params string The raw text after the tag's name.
---@return any? value What the tag writes, nil where the style's value goes back or the name is not declared.
read = (dialect, name, params) ->
  definition = overrideTags[name]
  return nil unless definition
  values = parse dialect, name, params
  return nil unless values and values[1] != nil
  stated = getArgumentReading dialect, name
  reading = {key, value for key, value in pairs stated when key != "conversion"}
  if stated.conversion
    kept = {key, value for key, value in pairs stated.conversion when key != "resolvesWeight"}
    reading.conversion = next(kept) and kept or nil
  interpret definition.signatures[1][1], values[1], reading

---Formats a value as the argument text a tag is written with, the inverse of `read`, so a value can be
---read out of a line, changed, and written back. A number is written to the precision that reads back as
---the same number, so it reaches the tag unchanged.
---@param dialect AssDialectName Whose reading the value was taken under, since a dialect may read a
---  tag's argument as a different type than the tag declares.
---@param tagName AssTagName The tag the argument belongs to.
---@param value any The value to write, in the units the tag's argument is written in.
---@return string? params The argument text, nil for an undeclared name or a nil value.
emitSingleArgument = (dialect, tagName, value) ->
  definition = overrideTags[tagName]
  return nil unless definition and value != nil
  emitTypedValue (getArgumentReading dialect, tagName).type or definition.signatures[1][1], value

---Formats the value the provided dialect reads a tag's argument as, so that reading it back at
---face value gives that value again. A refused argument acts as the bare tag and is written as
---nothing; a clamped, rounded or capped one is written as the value it becomes.
---@param dialect AssDialectName Whose reading to apply.
---@param token AssToken The tag whose argument is in question.
---@return string? canonical Nil where the argument already reads at face value and nothing is rewritten.
canonicalArgumentFor = (dialect, token) ->
  definition = overrideTags[token.name]
  return definition and definition.bareTagDefault if #token.params == 0

  -- A color's canonical spelling is a question about its notation rather than its value: every
  -- implementation reads a bare run of hex digits, and writes the `&H…&` a style is written with. A
  -- transparency takes two digits where a color takes six, which is what separates the argument types.
  argumentType = definition.signatures[1][1]
  if argumentType == ArgumentType.Color or argumentType == ArgumentType.Alpha
    -- A prefix with nothing behind it (e.g. `\c&H&`) puts the style's own value back for a dialect that
    -- refuses it, exactly as the bare tag does, so we canonicalize it to the bare tag (e.g. `\c`) which
    -- all dialects agree on.
    return "" if (getArgumentReading dialect, token.name).refusesLiteralWithoutDigits and
      not token.params\match "%x"

    value = read dialect, token.name, token.params
    return nil if value == nil
    notation = argumentType == ArgumentType.Alpha and ColorNotation.Alpha or ColorNotation.Color
    canonical = emitColor value, notation
    return canonical != token.params and canonical or nil

  -- Both renderers put the script's wrap style back for an argument outside the values the format
  -- declares, exactly as the bare tag does, so out of range the bare tag is the spelling of what it
  -- means. An argument holding no number converts to zero rather than restoring, and is spelled so.
  if token.name == TagName.WrapStyle
    value = read(dialect, token.name, token.params) or 0
    return "" unless WrapStyle\validate value
    face = tonumber token.params
    return nil if face == value
    return emitNumber value

  value = read dialect, token.name, token.params
  return "" if value == nil
  if "string" == type value
    return value != token.params and value or nil

  -- A size at or below zero puts the style's own back, so the bare tag is its spelling. An absolute
  -- zero always lands there; a signed argument scales the size in force by a tenth of what it names,
  -- so at -10 and below the scale is zero or less whatever size is in force.
  if (getArgumentReading dialect, token.name).requiresPositive
    signed = nil != token.params\match "^%s*[-+]"
    return "" if not signed and value == 0
    return "" if signed and value <= -10

  -- Reading the value doesn't tell us whether the argument was written with whitespace around it, so
  -- check the text and propose the trimmed form where that is all that differs.
  trimmed = trimArgument dialect, token.params
  return trimmed if trimmed != token.params and tonumber(trimmed) == value

  -- What the text literally says, against what the tag makes of it. This reads the number out of the
  -- source rather than off `arguments`, and has to: typing is itself lossy where a tag takes a whole
  -- number, so `\u1.5` would arrive here already reduced to the 1 it means and look like it said so.
  face = tonumber token.params
  return nil if face == value
  return emitNumber value

---Argument typing for tag tokens. The scanner runs it during a scan, so values can be read off
---the token rather than parsing `params` by hand.
---@class AssArguments
return {
  :parse, :convert, :readNumber, :readInteger, :emitNumber, :emitArguments
  :read, :interpret, :applyDialectSpecificReading, :sanitizeArgument, :canonicalArgumentFor
  :emitSingleArgument
}
