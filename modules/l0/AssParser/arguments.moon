-- cspell:ignore clipm -- a tag written against its argument
{:ColorNotation, :FontWeight, :WrapStyle, :emitColor, :parseColor} = require "l0.AssParser.ass"
{:ArgumentType, :Syntax, :TagName, :dialects, :getArgumentReading, :overrideTags} = require "l0.AssParser.dialects"

-- the one argument `\fn` reads as no font at all, which puts the style's back as a bare tag does
STYLE_FONT_NAME_TAG_VALUE = "0"

-- The two arguments `\b` takes that read as a flag rather than as a numeric weight.
FONT_WEIGHT_FLAG_NORMAL_TAG_VALUE = "0"
FONT_WEIGHT_FLAG_BOLD_TAG_VALUE = "1"

-- A numeric argument is read against the grammar of the string-to-double the dialect converts through,
-- and text that grammar can make nothing of reads as zero. Aegisub and VSFilter use the C library's,
-- to which an exponent, a hexadecimal float and the words `inf` and `nan` are all numbers; libass ships
-- one that reads a decimal numeral with an exponent and stops at everything else. Each alternative is
-- tried longest first, since `infinity` has to win over the `inf` inside it and a hexadecimal `0x1`
-- over the `0`.
decimalNumberPatterns = {
  "^[-+]?%d*%.?%d+[eE][-+]?%d+"
  "^[-+]?%d*%.?%d+"
}
numberPatterns = {
  "^[-+]?[iI][nN][fF][iI][nN][iI][tT][yY]"
  "^[-+]?[iI][nN][fF]"
  "^[-+]?[nN][aA][nN]"
  "^[-+]?0[xX]%x+%.?%x*[pP][-+]?%d+"
  "^[-+]?0[xX]%x+%.?%x*"
  decimalNumberPatterns[1]
  decimalNumberPatterns[2]
}

INFINITY = math.huge
NOT_A_NUMBER = 0 / 0

---Reads a number as a dialect's string-to-double does, taking as much of a leading numeral as that
---converts and nothing after it.
---@param text string The argument as the line wrote it.
---@param readsHexAndNonFiniteNumbers? boolean Whether `inf`, `nan` and a hex float are numbers here.
---  False for libass, whose own conversion reads a decimal numeral and stops.
---@return number value Zero where nothing at all converts, which is what the C call reports for one.
parseNumber = (text, readsHexAndNonFiniteNumbers = true) ->
  body = text\match "^%s*(.*)$"
  for pattern in *(readsHexAndNonFiniteNumbers and numberPatterns or decimalNumberPatterns)
    numeral = body\match pattern
    continue unless numeral
    negative = numeral\sub(1, 1) == "-"
    return negative and -INFINITY or INFINITY if numeral\match "[iI][nN][fF]"
    return NOT_A_NUMBER if numeral\match "[nN][aA][nN]"
    return tonumber(numeral) or 0
  return 0

---Reads a whole number, stopping at the first character that is not part of one.
---@param text string The argument as the line wrote it.
---@return integer value The number read, zero where the text does not start with one.
parseInteger = (text) -> tonumber(text\match "^%s*[-+]?%d+") or 0

---Reads one argument as the type it is declared with, before any dialect decides what to do with it.
---A flag is typed as an integer rather than a boolean so that `sanitizeArgument` can refuse one
---outside 0 and 1, which puts the style's own value back.
---@param argumentType AssArgumentType The type to read as.
---@param text string The argument as the line wrote it.
---@param readHexAndNonFiniteNumbers? boolean The dialect's number grammar, as `parseNumber` takes it.
---@param allowColorPrefix? boolean Whether a color or alpha literal may start with a `&H` prefix
---       in this context, which not every dialect does inside parentheses.
---@return any? value The typed value; the raw text for a tags or style-name argument; nil for a type that produces none.
convert = (argumentType, text, readHexAndNonFiniteNumbers, allowColorPrefix) ->
  switch argumentType
    when ArgumentType.Number, ArgumentType.SizeOrScale
      parseNumber text, readHexAndNonFiniteNumbers
    when ArgumentType.Integer, ArgumentType.Flag, ArgumentType.Weight then parseInteger text
    when ArgumentType.Color, ArgumentType.Alpha then parseColor text, allowColorPrefix
    when ArgumentType.Text, ArgumentType.Drawing then text\match "^%s*(.*)$"
    when ArgumentType.StyleName, ArgumentType.Tags then text
    else nil

---Checks whether a size argument is a scale of the size in force rather than an absolute size, which is
---what a leading sign makes it. Asked of that one type alone: everywhere else a sign belongs to the
---number and is already in the value, so only here does it say something a typed value cannot. Nil for
---every other type, which says the question does not apply rather than that no sign was written.
---@param argumentType AssArgumentType The type the argument was read as.
---@param text string The argument as the line wrote it.
---@return boolean? relative True for a scaled size, false for an absolute one.
readRelativeSize = (argumentType, text) ->
  return nil unless argumentType == ArgumentType.SizeOrScale
  return nil != text\match "^%s*[-+]"

-- The longest argument list any tag declares, which `\fad` and `\fade` take. Splitting stops one part
-- beyond it, so an over-supplied list comes back too long to match any signature and the tag goes
-- unread, which is what both renderers do with one.
MAX_ARGUMENT_COUNT = 7

---Drops the whitespace around an argument that the dialect never reads. Trailing whitespace is dropped
---in every dialect, leading whitespace only in Aegisub.
---@param text string The argument as the line wrote it.
---@param dialect AssDialectName Whose reading to apply.
---@return string trimmed Empty where the argument held nothing but whitespace.
trimArgument = (text, dialect) ->
  trimmed = text\match "^(.-)%s*$"
  return trimmed unless dialects[dialect].trimsLeadingWhitespaceInArguments
  return trimmed\match "^%s*(.-)$"

---Reads the argument a dialect takes from a tag written without parentheses whose arguments contain a
---`(`. The parenthesized text is taken ahead of the text before it, and text after the `)` is dropped,
---so `\bord2(9)7` draws a border of 9.
---@param params string The argument text as the line wrote it, outside any parentheses.
---@param dialect AssDialectName Whose reading to apply.
---@return string argument The parameters unchanged for a dialect reading them whole, or where the
---  parentheses hold nothing at all.
splitParenthesizedArgument = (params, dialect) ->
  return params unless dialects[dialect].splitsParenthesesInEveryTag
  before, inside = params\match "^([^()]*)%(([^,()\\]*)"
  return params unless before
  return #inside > 0 and inside or before

---Splits an argument list on commas, up to the most any tag may take, so a list with more arguments
---than a tag's widest signature comes back too long to match it. A backslash ends the splitting, and
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
  return parts

---Reads one tag's argument text into typed values, matched against the signatures the tag declares. A
---tag taking one parameter reads its text whole, commas included, so a font name is never split.
---@param params string The raw text after the tag's name.
---@param dialect AssDialectName Whose reading of the types to apply.
---@param tagName AssTagName The tag the arguments belong to.
---@param isParenthesized? boolean Whether the arguments were written in parentheses. Only a parenthesized
---  list is split on commas, so `\pos40,40` reads as the one argument no signature of `\pos` takes and
---  the tag goes unread.
---@return any[]? values One per parameter. Empty for a bare tag or a type that produces no value, nil
---  where no declared signature takes the number of arguments found.
---@return AssArgumentType[]? signature The signature the values matched, the tag's bare form where it
---  declares one and nothing was written, nil where no declared signature takes the count found.
---@return boolean? relative Whether a size argument is a scale of the size in force rather than an
---  absolute size. This additional hint is required, because ASS encodes the scale in the sign, which in
---  case of `\fs+10` is indistinguishable from the absolute size `\fs10` once converted to a number.
parse = (params, dialect, tagName, isParenthesized) ->
  definition = overrideTags[tagName]
  return nil unless definition
  params = trimArgument params, dialect
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
  return nil if definition.requiresParentheses and not isParenthesized

  params = splitParenthesizedArgument params, dialect unless isParenthesized
  {:honorsColorPrefixInParentheses, :readsHexAndNonFiniteNumbers} = dialects[dialect]
  allowColorPrefix = not isParenthesized or honorsColorPrefixInParentheses

  if #signatures == 1 and #signatures[1] == 1
    argumentType = getArgumentReading(tagName, dialect).type or signatures[1][1]
    value = convert argumentType, params, readsHexAndNonFiniteNumbers, allowColorPrefix
    return (value != nil and {value} or {}), signatures[1], readRelativeSize argumentType, params

  -- Only a parenthesized list is split on commas; without one a tag takes everything after its name as a
  -- single argument, which no signature of more than one argument matches. Every tag declaring such a
  -- signature also requires parentheses, so no tag in the table takes the unparenthesized path.
  parts = if isParenthesized
    [trimArgument(part, dialect) for part in *splitArguments params, MAX_ARGUMENT_COUNT + 1]
  else {params}

  match = nil
  for signature in *signatures
    if #signature == #parts
      match = signature
      break
  return nil unless match

  values = [convert match[index], parts[index], readsHexAndNonFiniteNumbers, allowColorPrefix for index = 1, #parts]
  return values, match, readRelativeSize match[1], parts[1]

---Applies transformations that reproduce dialect-specific internal representations of a tag argument
---after it has been read into a typed value.
---@param value any The value the argument's type produced.
---@param reading AssArgumentReading What this dialect does with it.
---@return any value Unchanged where it is not a number, since only a number can be rounded or clamped.
applyDialectSpecificReading = (value, reading) ->
  return value unless "number" == type value

  conversion = reading.conversion or {}
  if conversion.resolvesWeight
    value = switch value
      when 0 then FontWeight.Normal
      when 1 then FontWeight.Bold
      else value

  value = math.floor value + 0.5 if conversion.roundsToWhole

  -- Both renderers hold a value to its bounds by comparing against them and taking the bound only where
  -- the comparison is true, so a NaN passes through untouched. `math.max` and `math.min` would take the
  -- bound instead, which is what turns a NaN blur into the zero its picture is nothing like.
  return 0 if reading.readsNonFiniteAsZero and (value != value or value == INFINITY or value == -INFINITY)

  value = reading.minimum if reading.minimum and value < reading.minimum
  value = reading.maximum if reading.maximum and value > reading.maximum
  return value

---Checks whether a dialect refuses a color or alpha literal because it has no hex digit at all, as
---`\c&H&` and `\c&&` do. A refused one puts the style's own value back, exactly as the bare tag does.
---The digits are sought in the raw parameters, a typed value having already read the empty literal
---as zero.
---@param token AssToken The tag as it was written.
---@param reading AssArgumentReading What this dialect does with that tag's argument.
---@return boolean refused True where the literal is refused, so the style's own value goes back.
isRefusedLiteralWithoutDigits = (token, reading) ->
  return false unless reading.refusesLiteralWithoutDigits
  return nil == token.params\match "%x"

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
  return named != nil and applyDialectSpecificReading(named, reading) or nil

---Converts a number to a string for use in ASS tag arguments.
---Whole numbers are written without a decimal point and fractions without trailing
---zeros.
---@param value number The number to stringify.
---@return string text The stringified number.
emitNumber = (value) ->
  text = "%.14g"\format value
  return text unless text\find "e", 1, true

  -- `%g` switches to an exponent below 1e-4 and above the precision it is given, and a tag holding
  -- one reads back as the mantissa alone, so those magnitudes get their digits written out in full
  text = ("%.14f"\format value)\gsub "0+$", ""
  return (text\gsub "%.$", "")

---Returns the given typed value as argument text, the way its type is written.
---@param argumentType AssArgumentType The type the value was read as.
---@param value any The typed value.
---@return string text The value as its type writes it.
emitTypedValue = (argumentType, value) ->
  switch argumentType
    when ArgumentType.Color then emitColor value, ColorNotation.Color
    when ArgumentType.Alpha then emitColor value, ColorNotation.Alpha
    when ArgumentType.Number, ArgumentType.SizeOrScale, ArgumentType.Integer, ArgumentType.Flag, ArgumentType.Weight
      emitNumber value
    else tostring value

---Writes one tag's typed values back as argument text.
---Assign the result to `params`, which is what a tag is emitted from.
---
---This is the inverse of `parse`, but a lossy one: reading drops the form that produced a
---value, so a tag written `\u1.5` comes back `\u1` and one written `\1cFF0000` comes back
---`\1c&HFF0000&`. What comes out is the canonical way of writing what the tag means to the dialect
---asked, so text that is already canonical survives a round trip and nothing else does.
---@param token AssToken The tag whose `arguments` are to be written.
---@param dialect AssDialectName Whose reading the values were taken under.
---@return string? params The argument text, nil for a token with no typed values to write.
emitArguments = (token, dialect) ->
  {:arguments, :signature} = token
  return nil unless arguments
  -- a bare tag writes as empty rather than nil to tell it apart from a read failure
  return "" if #arguments == 0
  return nil unless signature

  parts = for index = 1, #arguments
    argumentType = index == 1 and getArgumentReading(token.name, dialect).type or nil
    argumentType or= signature[index]
    emitTypedValue argumentType, arguments[index]

  parts[1] = "#{Syntax.PositiveRelativeSizeSign}#{parts[1]}" if token.sizeIsRelative and arguments[1] >= 0
  return table.concat parts, Syntax.ArgumentSeparator

---Reads the value one tag's argument has under one dialect, in the units the argument was written in,
---so it can go back into the tag it came from: `\b1` comes back as 1 even where the dialect holds it
---as a weight of 700. Refusal, clamping and rounding all apply, so the result is what the argument is
---interpreted as rather than its literal value.
---@param params string The raw text after the tag's name.
---@param dialect AssDialectName Whose reading to apply.
---@param tagName AssTagName The tag the argument belongs to.
---@param isParenthesized? boolean Whether the argument was written in parentheses, which decides how a
---  color literal's `&H` prefix is read and which signatures the list can match.
---@return any? value What the tag writes, nil where the style's value goes back or the name is not declared.
read = (params, dialect, tagName, isParenthesized) ->
  definition = overrideTags[tagName]
  return nil unless definition
  values = parse params, dialect, tagName, isParenthesized
  return nil unless values and values[1] != nil
  stated = getArgumentReading tagName, dialect
  reading = {key, value for key, value in pairs stated when key != "conversion"}
  if stated.conversion
    kept = {key, value for key, value in pairs stated.conversion when key != "resolvesWeight"}
    reading.conversion = next(kept) and kept or nil
  return interpret definition.signatures[1][1], values[1], reading

---Formats a value as the argument text a tag is written with, the inverse of `read`, so a value can be
---read out of a line, changed, and written back. A number is written to the precision that reads back as
---the same number, so it goes into the tag unchanged.
---@param value any The value to write, in the units the tag's argument is written in.
---@param dialect AssDialectName Whose reading the value was taken under, since a dialect may read a
---  tag's argument as a different type than the tag declares.
---@param tagName AssTagName The tag the argument belongs to.
---@return string? params The argument text, nil for an undeclared name or a nil value.
emitSingleArgument = (value, dialect, tagName) ->
  definition = overrideTags[tagName]
  -- `sc` declares no signature, reading nothing at all, so there is no type to write a value as
  return nil unless definition and value != nil and definition.signatures[1]
  emitTypedValue (getArgumentReading tagName, dialect).type or definition.signatures[1][1], value

---Formats the value the provided dialect reads a tag's argument as, so that reading it back at
---face value gives that value again. A refused argument acts as the bare tag and is written as
---nothing; a clamped, rounded or capped one is written as the value it becomes.
---@param token AssToken The tag whose argument is in question.
---@param dialect AssDialectName Whose reading to apply.
---@return string? canonical Nil where the argument already reads at face value and nothing is rewritten.
---@return boolean? parenthesesDropped True where the canonical form drops the parentheses the argument
---  was written in, so writing it back is a change of form as well as of text.
canonicalArgumentFor = (token, dialect) ->
  definition = overrideTags[token.name]
  return definition and definition.bareTagDefault if #token.params == 0

  -- A color's canonical spelling is a question about its notation rather than its value: every
  -- implementation reads a bare run of hex digits, and writes the `&H…&` a style is written with. A
  -- transparency takes two digits where a color takes six, which is what separates the argument types.
  isParenthesized = nil != (token.form and token.form.parenthesized)

  argumentType = definition.signatures[1] and definition.signatures[1][1]
  if argumentType == ArgumentType.Color or argumentType == ArgumentType.Alpha
    return "" if isRefusedLiteralWithoutDigits token, (getArgumentReading token.name, dialect)

    value = read token.params, dialect, token.name, isParenthesized
    return nil if value == nil
    notation = argumentType == ArgumentType.Alpha and ColorNotation.Alpha or ColorNotation.Color
    canonical = emitColor value, notation
    -- A color tag declares no argument list, so parentheses around its value are a degenerate form
    -- rather than syntax, and one dialect reads the `&H` prefix as digits where they stand inside them.
    -- Writing the value without them is what leaves one form every dialect reads the same way.
    return canonical, true if isParenthesized
    return canonical != token.params and canonical or nil

  -- Both renderers put the script's wrap style back for an argument outside the values the format
  -- declares, exactly as the bare tag does, so out of range the bare tag is how that meaning is
  -- written. An argument that is not a number converts to zero rather than restoring, and is written so.
  if token.name == TagName.WrapStyle
    value = read(token.params, dialect, token.name) or 0
    return "" unless WrapStyle\validate value
    face = tonumber token.params
    return nil if face == value
    return emitNumber value

  value = read token.params, dialect, token.name, isParenthesized
  return "" if value == nil
  if "string" == type value
    return value != token.params and value or nil

  reading = getArgumentReading token.name, dialect

  -- A dialect resolving a weight reads `\b700` as the same weight `\b1` writes, so the flag is the one
  -- form that says the same thing to every dialect. The others hold the number as written, and part
  -- from the flag on a run boundary though both draw the same weight.
  conversion = reading.conversion
  if conversion and conversion.resolvesWeight
    return FONT_WEIGHT_FLAG_NORMAL_TAG_VALUE if value == FontWeight.Normal
    return FONT_WEIGHT_FLAG_BOLD_TAG_VALUE if value == FontWeight.Bold

  -- A size at or below zero puts the style's own back, so the bare tag is how it is written. An absolute
  -- zero always lands there; a signed argument scales the size in force by a tenth of its value,
  -- so at -10 and below the scale is zero or less whatever size is in force.
  if reading.requiresPositive
    signed = nil != token.params\match "^%s*[-+]"
    return "" if not signed and value == 0
    return "" if signed and value <= -10

  -- Reading the value doesn't tell us whether the argument was written with whitespace around it, so
  -- check the text and propose the trimmed form where that is all that differs.
  trimmed = trimArgument token.params, dialect
  return trimmed if trimmed != token.params and tonumber(trimmed) == value

  -- The text as written, against what the tag makes of it. This reads the number out of the
  -- source rather than off `arguments`, and has to: typing is itself lossy where a tag takes a whole
  -- number, so `\u1.5` would arrive here already reduced to the 1 it means and look like it said so.
  face = tonumber token.params

  -- A hex numeral is 16 to the dialects converting through the C library and 0 to libass, whose own
  -- conversion stops at the `x`. So even the dialect reading it at face value has to write it out as a
  -- decimal numeral, which is the only notation all three read alike.
  return emitNumber value if face == value and token.params\match "^%s*[-+]?0[xX]%x"

  return nil if face == value
  return emitNumber value

---Reads a tag token's arguments off its own `params` and writes the typed values onto it.
---Call this after manually editing the token's `params` to re-synchronize the parsed fields to the new text.
---@param token AssToken A tag token, whose `arguments`, `signature` and `sizeIsRelative` are replaced.
---@param dialect AssDialectName Whose reading of the types to apply.
reparseToken = (token, dialect) ->
  isParenthesized = nil != (token.form and token.form.parenthesized)
  token.arguments, token.signature, token.sizeIsRelative = parse token.params, dialect, token.name,
    isParenthesized

---Argument typing for tag tokens. The scanner runs it during a scan, so values can be read off
---the token rather than parsing `params` by hand.
---@class AssArguments
return {
  :parse, :convert, :parseNumber, :parseInteger, :emitNumber, :emitArguments, :splitArguments
  :read, :interpret, :applyDialectSpecificReading, :isRefusedLiteralWithoutDigits, :sanitizeArgument
  :canonicalArgumentFor
  :emitSingleArgument, :reparseToken
}
