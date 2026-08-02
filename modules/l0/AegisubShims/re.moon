-- Aegisub's re module binds Boost.Regex through its ICU layer: Perl syntax, matching over Unicode code
-- points, and byte offsets into the UTF-8 subject. PCRE2 under UTF and UCP reproduces all three, so
-- only the public surface is reproduced here and the internals follow PCRE2's grain.
--
-- Two Boost defaults invert against PCRE2's and are corrected when a pattern is compiled: Boost's perl
-- mode has the m modifier on, and Aegisub never passes match_not_dot_newline, so `^`/`$` match at
-- embedded newlines and `.` spans them unless NO_MOD_M / NO_MOD_S say otherwise.
--
-- Byte offsets are 1-based and inclusive throughout. A zero-width match reports its last one before its
-- first, which the iteration and replacement walks rely on to make progress.

bit = require "bit"

msgs = {
  requireEngine: {
    unavailable: "The headless stand-in for aegisub.re needs the lrexlib-pcre2 rock: %s"
  }
  combineFlags: {
    unsupported: "aegisub.re flag %s has no PCRE2 equivalent and is not supported headlessly."
  }
  splitFlagArgs: {
    outOfOrder: "Flags must follow all non-flag arguments."
  }
  compile: {
    emptyPattern: "Regular expression must not be empty."
  }
}

-- Assigned by requireEngine on the first compile; baseOptions is Perl syntax over Unicode code points,
-- with the two inverted Boost defaults applied.
local rex, pcre, baseOptions

---Loads the regex engine, raising a message naming the rock when it isn't installed.
---@param errorLevel number Stack level to blame when the rock is missing.
assertEngineLoaded = (errorLevel) ->
  return if rex

  ok, loaded = pcall require, "rex_pcre2"
  error msgs.requireEngine.unavailable\format(tostring loaded), errorLevel + 1 unless ok

  rex = loaded
  pcre = rex.flags!
  baseOptions = bit.bor pcre.UTF, pcre.UCP, pcre.MULTILINE, pcre.DOTALL

---@alias AegisubReFlagName
---| "ICASE" # match regardless of case, using Unicode case folding
---| "NOSUB" # don't mark sub-expressions
---| "COLLATE" # use locale-specific collation in ranges
---| "NEWLINE_ALT" # treat a newline in the pattern as an alternation
---| "NO_MOD_M" # turn the Perl m modifier off, so ^ and $ only match at the subject's ends
---| "NO_MOD_S" # turn the Perl s modifier off, so . stops matching a newline
---| "MOD_S" # force the Perl s modifier on, so . matches a newline
---| "MOD_X" # ignore unescaped whitespace in the pattern and honor # comments
---| "NO_EMPTY_SUBEXPRESSIONS" # reject empty sub-expressions

-- Boost's regbase bit values, so a flag compares equal to the one a script read from real Aegisub
FLAG_VALUES = {
  NO_MOD_M: 0x400
  MOD_X: 0x800
  MOD_S: 0x1000
  NO_MOD_S: 0x2000
  NEWLINE_ALT: 0x20000
  ICASE: 0x100000
  COLLATE: 0x200000
  NOSUB: 0x400000
  NO_EMPTY_SUBEXPRESSIONS: 0x1000000
}

-- NEWLINE_ALT turns a newline in the pattern into an alternation, so a pattern relying on it silently
-- means something else under PCRE2. The other two flags PCRE2 lacks are accepted and ignored, since
-- neither can change what a pattern matches: PCRE2 ranges already collate as the C locale does, and the
-- empty sub-expression check only ever adds a compile error that would reject patterns Aegisub accepts.
UNSUPPORTED_FLAGS = {NEWLINE_ALT: true}

---One of the module's flag values, carrying the Boost bit a caller may compare against.
---@class AegisubReFlag
---@field name AegisubReFlagName
---@field value number Boost's regbase bit for this flag.
flagMeta = {__tostring: (flag) -> "aegisub.re.#{flag.name}"}

---Reports whether a value is one of this module's flags rather than a plain argument.
---@param value any The value to test.
---@return boolean isFlag
isFlag = (value) -> "table" == type(value) and flagMeta == getmetatable value

---Combines flag values, rejecting one PCRE2 can't honor.
---@param flags AegisubReFlag[] The flags to combine.
---@param errorLevel number Stack level to blame for a rejected flag.
---@return number combined The flags' bitwise union.
combineFlags = (flags, errorLevel) ->
  combined = 0
  for flag in *flags
    error msgs.combineFlags.unsupported\format(flag.name), errorLevel + 1 if UNSUPPORTED_FLAGS[flag.name]
    combined = bit.bor combined, flag.value
  return combined

---Splits a static wrapper's trailing flag arguments from the plain ones it passes through.
---@param errorLevel number Stack level to blame when a plain argument follows a flag.
---@param ... any The wrapper's arguments, flags last.
---@return number flags The combined flag value.
---@return table plain The remaining arguments, packed with an `n` count.
splitFlagArgs = (errorLevel, ...) ->
  plain = table.pack ...

  local firstFlag
  firstFlag or=i for i = 1, plain.n when isFlag plain[i]
  return 0, plain unless firstFlag

  error msgs.splitFlagArgs.outOfOrder, errorLevel + 1 for i = firstFlag, plain.n when not isFlag plain[i]
  flags = [plain[i] for i = firstFlag, plain.n]

  plain.n = firstFlag - 1
  return combineFlags(flags, errorLevel + 1), plain

---Translates a combined Aegisub flag value into PCRE2 compile options.
---@param flags number The combined flag value.
---@return number options The PCRE2 options to compile the pattern with.
toPcreOptions = (flags) ->
  ---@param value number A single flag's bit.
  ---@return boolean present
  hasFlag = (value) -> 0 != bit.band flags, value

  options = baseOptions
  options = bit.bor options, pcre.CASELESS if hasFlag FLAG_VALUES.ICASE
  options = bit.bor options, pcre.EXTENDED if hasFlag FLAG_VALUES.MOD_X
  options = bit.bor options, pcre.NO_AUTO_CAPTURE if hasFlag FLAG_VALUES.NOSUB
  -- MOD_S only restates the default; its negation is the one that changes anything
  options = bit.band options, bit.bnot pcre.DOTALL if hasFlag FLAG_VALUES.NO_MOD_S
  options = bit.band options, bit.bnot pcre.MULTILINE if hasFlag FLAG_VALUES.NO_MOD_M
  return options

---Byte bounds as `{first, last}` pairs, the whole match first and its capture groups after it.
---@alias AegisubReBounds number[][]

---A matched span of the subject, reported by every method that hands one back.
---@class AegisubReMatch
---@field str string The matched text.
---@field first number First byte of the match.
---@field last number Last byte of the match, one before `first` for a zero-width match.

---Finds the next match at or after a byte offset.
---@param compiled userdata The compiled rex_pcre2 pattern.
---@param str string The subject to search.
---@param startAt number 1-based byte offset to start at.
---@return number? first First byte of the match; nil when there is none or the offset is past the end.
---@return number? last Last byte of the match, one before `first` for a zero-width match.
findFrom = (compiled, str, startAt) ->
  return unless startAt <= #str + 1
  return compiled\find str, startAt

---Finds the next match at or after a byte offset, along with its capture groups.
---@param compiled userdata The compiled rex_pcre2 pattern.
---@param str string The subject to search.
---@param startAt number 1-based byte offset to start at.
---@return AegisubReBounds? bounds Nil when nothing matched. The list stops at the first group that didn't participate, so a pattern whose optional group missed reports only what precedes it.
matchBoundsFrom = (compiled, str, startAt) ->
  return unless startAt <= #str + 1

  first, last, groups = compiled\exec str, startAt
  return unless first

  bounds = {{first, last}}
  for i = 1, #groups, 2
    break unless groups[i]
    bounds[#bounds + 1] = {groups[i], groups[i + 1]}
  return bounds

---Expands Boost's Perl-format replacement template against one match.
---@param template string The replacement, using `$1`, `${1}`, `$&`, `` $` ``, `$'` and `$$`.
---@param str string The subject the match came from.
---@param bounds AegisubReBounds The match's bounds, whole match first.
---@return string expanded
expandTemplate = (template, str, bounds) ->
  {first, last} = bounds[1]
  out, position = {}, 1

  while position <= #template
    dollar = template\find "%$", position
    unless dollar
      out[#out + 1] = template\sub position
      break

    out[#out + 1] = template\sub position, dollar - 1 if dollar > position

    rest = template\sub dollar + 1
    local token, width
    if braced = rest\match "^{(%d+)}"
      token, width = tonumber(braced), #braced + 2
    elseif digits = rest\match "^(%d+)"
      token, width = tonumber(digits), #digits
    else
      token, width = rest\sub(1, 1), 1

    out[#out + 1] = switch token
      when "$" then "$"
      when "&" then str\sub first, last
      when "`" then str\sub 1, first - 1
      when "'" then str\sub last + 1
      when "" then "$" -- a trailing dollar stands for itself
      else
        if "number" == type token
          group = bounds[token + 1]
          group and str\sub(group[1], group[2]) or ""
        else "$" .. token

    position = dollar + 1 + width

  return table.concat out

---Replaces matches with an expanded template. Steps past one character after a zero-width match, or
---the same empty match would be found until the count runs out.
---@param compiled userdata The compiled rex_pcre2 pattern.
---@param template string The replacement, in Boost's Perl-format syntax.
---@param str string The subject to rewrite.
---@param maxCount number Maximum replacements to make.
---@return string replaced
substituteWithTemplate = (compiled, template, str, maxCount) ->
  out, position, remaining = {}, 1, maxCount

  while remaining > 0
    bounds = matchBoundsFrom compiled, str, position
    break unless bounds
    {first, last} = bounds[1]

    out[#out + 1] = str\sub position, first - 1
    out[#out + 1] = expandTemplate template, str, bounds

    if last < first
      out[#out + 1] = str\sub first, first
      position = first + 1
    else position = last + 1
    remaining -= 1

  out[#out + 1] = str\sub position
  return table.concat out

---Applies the callback to one match, appending the rewritten span and the text leading up to it.
---The callback receives each capture group when the pattern has them, and the whole match when it
---has none, so a group's replacement carries the text between it and whatever was written last.
---@param compiled userdata The compiled rex_pcre2 pattern.
---@param func fun(str: string, first: number, last: number): string? Returns the replacement; a non-string leaves the span alone.
---@param str string The subject to rewrite.
---@param out string[] Accumulator the rewritten pieces are appended to.
---@param position number 1-based byte offset to match from.
---@return number position Offset the next match should start at; unchanged when nothing matched.
---@return boolean? more Whether the subject may hold a further match.
substituteOne = (compiled, func, str, out, position) ->
  bounds = matchBoundsFrom compiled, str, position
  return position unless bounds

  start = #bounds == 1 and 1 or 2
  written = position
  local first
  for i = start, #bounds
    first, last = bounds[i][1], bounds[i][2]
    out[#out + 1] = str\sub written, first - 1 if written < last

    replaced = func str\sub(first, last), first, last
    out[#out + 1] = "string" == type(replaced) and replaced or str\sub first, last
    written = last + 1

  if first == written
    out[#out + 1] = str\sub written, written
    written += 1

  return written, bounds[1][1] <= #str

---Replaces matches with the callback's return value.
---@param compiled userdata The compiled rex_pcre2 pattern.
---@param func fun(str: string, first: number, last: number): string? Returns the replacement; a non-string leaves the span alone.
---@param str string The subject to rewrite.
---@param maxCount number Maximum replacements to make.
---@return string replaced
substituteWithFunction = (compiled, func, str, maxCount) ->
  out, position = {}, 1
  for _ = 1, maxCount
    position, more = substituteOne compiled, func, str, out, position
    break unless more
  return table.concat(out, "") .. str\sub position

---A compiled regular expression.
---@class AegisubRegEx
---@field _regex userdata The compiled rex_pcre2 pattern backing this expression.
class RegEx
  ---@param _regex userdata The compiled rex_pcre2 pattern.
  new: (@_regex) =>

  ---Iterates the substrings between matches.
  ---@param str string The subject to split.
  ---@param skipEmpty? boolean Drop empty fields (default false).
  ---@param maxSplit? number Maximum number of splits; 0 or absent means as many as fit.
  ---@return fun(): string? iterator Yields each field in turn, then nil.
  gsplit: (str, skipEmpty, maxSplit) =>
    maxSplit = #str if not maxSplit or maxSplit <= 0

    startAt, fieldStart = 1, 1
    nextField = ->
      return if not str or #str == 0

      local first, last
      first, last = findFrom @_regex, str, startAt if maxSplit > 0

      if not first or first > #str
        field = str\sub fieldStart, #str
        str = nil
        return if skipEmpty and #field == 0 then nil else field

      field = str\sub fieldStart, first - 1
      fieldStart = last + 1
      startAt = startAt - 1 >= last and startAt + 1 or last + 1

      return nextField! if skipEmpty and #field == 0
      maxSplit -= 1
      return field

    return nextField

  ---Splits the subject on every match.
  ---@param str string The subject to split.
  ---@param skipEmpty? boolean Drop empty fields (default false).
  ---@param maxSplit? number Maximum number of splits; 0 or absent means as many as fit.
  ---@return string[] fields
  split: (str, skipEmpty, maxSplit) => [field for field in @gsplit str, skipEmpty, maxSplit]

  ---Iterates every match in the subject.
  ---@param str string The subject to search.
  ---@return fun(): string?, number?, number? iterator Yields the matched text with its first and last byte offsets.
  gfind: (str) =>
    startAt = 1
    ->
      first, last = findFrom @_regex, str, startAt
      return unless first

      startAt = last >= startAt and last + 1 or startAt + 1
      return str\sub(first, last), first, last

  ---Finds every match in the subject.
  ---@param str string The subject to search.
  ---@return AegisubReMatch[]? matches Nil when nothing matched.
  find: (str) =>
    found = [{str: s, first: f, last: l} for s, f, l in @gfind str]
    return next(found) and found

  ---Replaces matches in the subject.
  ---@param str string The subject to rewrite.
  ---@param repl string|fun(str: string, first: number, last: number): string? A replacement template using Boost's `$1`/`$&` syntax, or a function whose non-string return leaves the match alone.
  ---@param maxCount? number Maximum replacements; 0 or absent means every match.
  ---@return string? replaced Nil when `repl` is neither a string nor a function.
  sub: (str, repl, maxCount) =>
    maxCount = #str + 1 if not maxCount or maxCount == 0

    switch type repl
      when "function" then return substituteWithFunction @_regex, repl, str, maxCount
      when "string" then return substituteWithTemplate @_regex, repl, str, maxCount

  ---Iterates the whole match and then each capture group of the first match at or after `start`.
  ---@param str string The subject to search.
  ---@param start? number Byte offset to start at (default 1).
  ---@return fun(): AegisubReMatch? iterator Stops at the first group that didn't participate.
  gmatch: (str, start) =>
    bounds = matchBoundsFrom @_regex, str, start or 1
    index = 0
    ->
      index += 1
      entry = bounds and bounds[index]
      return unless entry
      return {str: str\sub(entry[1], entry[2]), first: entry[1], last: entry[2]}

  ---Returns the whole match and its capture groups for the first match at or after `start`.
  ---@param str string The subject to search.
  ---@param start? number Byte offset to start at (default 1).
  ---@return AegisubReMatch[]? matches Nil when nothing matched.
  match: (str, start) =>
    found = [entry for entry in @gmatch str, start]
    return next(found) and found

---Compiles a pattern, raising when the engine rejects it.
---@param pattern string The pattern, in Perl syntax.
---@param flags number The combined flag value.
---@param errorLevel number Stack level to blame for a bad pattern.
---@return AegisubRegEx regex
compile = (pattern, flags, errorLevel) ->
  assertEngineLoaded errorLevel + 1
  error msgs.compile.emptyPattern, errorLevel + 1 if pattern == ""

  ok, compiled = pcall rex.new, pattern, toPcreOptions flags
  error tostring(compiled), errorLevel + 1 unless ok
  return RegEx compiled

---Builds the module's static for one AegisubRegEx method, compiling the pattern each call passes it
---and applying that method to the result.
---@param methodName string The AegisubRegEx method the static stands for.
---@return fun(str: string, pattern: string, ...): ... static The static wrapper for that method.
wrapAsStatic = (methodName) -> (str, pattern, ...) ->
  flags, plain = splitFlagArgs 2, ...
  regex = compile pattern, flags, 2
  return regex[methodName] regex, str, unpack plain, 1, plain.n

---Headless stand-in for Aegisub's `aegisub.re` module, reached under that require id once
---l0.AegisubShims has claimed it, so a script requiring it loads and can be tested outside Aegisub.
---
---Backed by PCRE2 where Aegisub uses Boost.Regex over ICU. The dialects agree on Perl syntax, Unicode
---code-point matching and byte offsets, so ordinary patterns behave identically. `NEWLINE_ALT` has no
---PCRE2 equivalent and raises, since it changes what a pattern means; `COLLATE` and
---`NO_EMPTY_SUBEXPRESSIONS` are accepted and ignored, neither being able to change what is matched.
---@class AegisubRe
---@field ICASE AegisubReFlag Match regardless of case.
---@field NOSUB AegisubReFlag Don't mark sub-expressions.
---@field COLLATE AegisubReFlag Locale-specific collation; accepted and ignored.
---@field NEWLINE_ALT AegisubReFlag A newline in the pattern acts as an alternation; unsupported headlessly.
---@field NO_MOD_M AegisubReFlag Turn the Perl m modifier off.
---@field NO_MOD_S AegisubReFlag Turn the Perl s modifier off.
---@field MOD_S AegisubReFlag Force the Perl s modifier on.
---@field MOD_X AegisubReFlag Ignore unescaped whitespace and honor # comments.
---@field NO_EMPTY_SUBEXPRESSIONS AegisubReFlag Reject empty sub-expressions; accepted and ignored.
Re = {
  ---Compiles a pattern into a reusable regular expression.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... AegisubReFlag Any of the module's flag values.
  ---@return AegisubRegEx regex
  compile: (pattern, ...) -> compile pattern, combineFlags({...}, 2), 2

  ---Splits the subject on every match of the pattern.
  ---@param str string The subject to split.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... any `skipEmpty` and `maxSplit`, then any flag values.
  ---@return string[] fields
  split: wrapAsStatic "split"

  ---Iterates the substrings between matches of the pattern.
  ---@param str string The subject to split.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... any `skipEmpty` and `maxSplit`, then any flag values.
  ---@return fun(): string? iterator
  gsplit: wrapAsStatic "gsplit"

  ---Finds every match of the pattern in the subject.
  ---@param str string The subject to search.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... AegisubReFlag Any of the module's flag values.
  ---@return AegisubReMatch[]? matches
  find: wrapAsStatic "find"

  ---Iterates every match of the pattern in the subject.
  ---@param str string The subject to search.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... AegisubReFlag Any of the module's flag values.
  ---@return fun(): string?, number?, number? iterator
  gfind: wrapAsStatic "gfind"

  ---Returns the first match of the pattern along with its capture groups.
  ---@param str string The subject to search.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... any A start offset, then any flag values.
  ---@return AegisubReMatch[]? matches
  match: wrapAsStatic "match"

  ---Iterates the first match of the pattern and then each of its capture groups.
  ---@param str string The subject to search.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... any A start offset, then any flag values.
  ---@return fun(): AegisubReMatch? iterator
  gmatch: wrapAsStatic "gmatch"

  ---Replaces matches of the pattern in the subject.
  ---@param str string The subject to rewrite.
  ---@param pattern string The pattern, in Perl syntax.
  ---@param ... any The replacement and an optional max count, then any flag values.
  ---@return string? replaced
  sub: wrapAsStatic "sub"
}

Re[name] = setmetatable {:name, :value}, flagMeta for name, value in pairs FLAG_VALUES

return Re
