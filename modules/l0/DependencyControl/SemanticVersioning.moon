Enum = require "l0.DependencyControl.Enum"
Common = require "l0.DependencyControl.Common"

SemanticVersioning = nil

---@alias SemverPrecision
---| "major"
---| "minor"
---| "patch"
---| "range" # compare `b` as an npm-style version range string instead of as a version

NPM_RANGE_TOKEN_OR = "||"
NPM_RANGE_TOKEN_LT = "<"
NPM_RANGE_TOKEN_LTE = "<="
NPM_RANGE_TOKEN_GT = ">"
NPM_RANGE_TOKEN_GTE = ">="
NPM_RANGE_TOKEN_EQ = "="
NPM_RANGE_TOKEN_TILDE = "~"
NPM_RANGE_TOKEN_RUBY_PESSIMISTIC = NPM_RANGE_TOKEN_TILDE .. NPM_RANGE_TOKEN_GT  -- "~>", an alias for "~" (see parseComparator)
NPM_RANGE_TOKEN_CARET = "^"
NPM_RANGE_TOKEN_WILDCARD_X_UPPER = "X"
NPM_RANGE_TOKEN_WILDCARD_X_LOWER = "x"
NPM_RANGE_TOKEN_WILDCARD_STAR = "*"
NPM_RANGE_TOKEN_HYPHEN = "-"

npmRangeWildcardTokens = {
  [NPM_RANGE_TOKEN_WILDCARD_X_UPPER]: true
  [NPM_RANGE_TOKEN_WILDCARD_X_LOWER]: true
  [NPM_RANGE_TOKEN_WILDCARD_STAR]: true
}

semverFields = {"major", "minor", "patch"}

ComparisonOperator = Enum "ComparisonOperator", {
  GT: ">"
  GTE: ">="
  LT: "<"
  LTE: "<="
  EQ: "="
}
Op = ComparisonOperator

---A version comparison operator (the value of a ComparisonOperator enum member).
---@alias ComparisonOperator
---| ">"  # greater than
---| ">=" # greater than or equal
---| "<"  # less than
---| "<=" # less than or equal
---| "="  # equal

---A semantic version parsed into its specified components; an absent or wildcard (`x`/`*`) component is nil.
---@class PartialVersion
---@field major? integer
---@field minor? integer
---@field patch? integer

---A single version comparator: an operator and the encoded version it compares against.
---@class SemverComparator
---@field op ComparisonOperator
---@field num integer The encoded version (see encodeVersion) the operator compares against.

---A half-open version interval [min, max): min inclusive, max exclusive (both encoded versions).
---@class SemverInterval
---@field min integer Inclusive lower bound (encoded version).
---@field max integer Exclusive upper bound (encoded version).

msgs = {
  toNumber: {
    badString: "Can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
    badType: "Argument had the wrong type: expected a string or number, got a %s."
    overflow: "Error: %s version must be an integer <= 255, got %s."
  }
  range: {
    badType: "Version range must be a string, got a %s."
    invalidVersion: "Invalid version '%s' in range."
  }
}

---Encodes a semantic version's major/minor/patch components into a single integer.
---@param major? integer The major version (0-255).
---@param minor? integer The minor version (0-255).
---@param patch? integer The patch version (0-255).
---@return integer encoded The encoded version.
encodeVersion = (major, minor, patch) ->
  bit.lshift(major or 0, 16) + bit.lshift(minor or 0, 8) + (patch or 0)

-- One past the highest representable version (255.255.255); the exclusive upper bound of an
-- unbounded-above interval. Exclusive upper bounds from range expansion never exceed this.
SEMVER_RANGE_MAX_EXCLUSIVE = encodeVersion 256, 0, 0

---Parses a (possibly partial) version into a table holding only the specified, non-wildcard components.
---Absent or wildcard components become nil.
---@param str string The version string to parse (e.g "1", "1.2", "1.2.3", "1.x", "*")
---@return PartialVersion? parsed The parsed version, or nil on error.
---@return string? err Error message if parsing failed.
parsePartialVersion = (str) ->
  str = (Common.trim str)\gsub "^[vV]", ""
  return {} if str == "" or npmRangeWildcardTokens[str]
  components = [c for c in str\gmatch "[^%.]+"]
  return nil, msgs.range.invalidVersion\format str if #components == 0 or #components > 3

  parsed = {}
  for i, component in ipairs components
    unless npmRangeWildcardTokens[component]
      n = tonumber component
      return nil, msgs.range.invalidVersion\format str unless n and n % 1 == 0 and n >= 0 and n <= 255
      parsed[semverFields[i]] = n
  parsed

---Expands a bare version ("1.2") or partial version (1.2.x) with wildcards converted to nil into its equivalent X-range
---comparator list.
---@param v PartialVersion The parsed version (possibly partial; wildcard components are nil).
---@return SemverComparator[] comparators The expanded comparator list equivalent to the original version.
xRangeComparators = (v) ->
  if v.major == nil
    {{op: Op.GTE, num: 0}}
  elseif v.minor == nil
    {{op: Op.GTE, num: encodeVersion v.major, 0, 0}, {op: Op.LT, num: encodeVersion v.major + 1, 0, 0}}
  elseif v.patch == nil
    {{op: Op.GTE, num: encodeVersion v.major, v.minor, 0}, {op: Op.LT, num: encodeVersion v.major, v.minor + 1, 0}}
  else
    {{op: Op.EQ, num: encodeVersion v.major, v.minor, v.patch}}

---Expands a tilde-range version into its equivalent comparator list. Allows patch-level changes if a
---minor version is specified, otherwise minor-level changes.
---@param v PartialVersion The parsed version (possibly partial; wildcard components are nil).
---@return SemverComparator[] comparators The expanded comparator list equivalent to the original tilde-range version.
tildeComparators = (v) ->
  lower = encodeVersion v.major or 0, v.minor or 0, v.patch or 0
  upper = v.minor != nil and encodeVersion(v.major or 0, v.minor + 1, 0) or encodeVersion((v.major or 0) + 1, 0, 0)
  {{op: Op.GTE, num: lower}, {op: Op.LT, num: upper}}

---Expands a caret-range version into its equivalent comparator list. Allows changes that do not modify the 
---left-most non-zero digit in the {major, minor, patch} sequence.
---@param v PartialVersion The parsed version (possibly partial; wildcard components are nil).
---@return SemverComparator[] comparators The expanded comparator list equivalent to the original caret-range version.
caretComparators = (v) ->
  major = v.major or 0
  lower = encodeVersion major, v.minor or 0, v.patch or 0
  upper = if v.minor == nil
    encodeVersion major + 1, 0, 0
  elseif v.patch == nil
    major == 0 and encodeVersion(0, v.minor + 1, 0) or encodeVersion(major + 1, 0, 0)
  elseif major == 0
    v.minor == 0 and encodeVersion(0, 0, v.patch + 1) or encodeVersion(0, v.minor + 1, 0)
  else
    encodeVersion major + 1, 0, 0
  {{op: Op.GTE, num: lower}, {op: Op.LT, num: upper}}

---Expands an explicit-operator comparator over a possibly-partial version into concrete {op, num} comparator(s). 
---A fully-specified version (e.g. ">1.2.3") passes straight through whereas a partial one is normalized the way
---the operator dictates (e.g. ">1" => ">=2.0.0","<=1.2" => "<1.3.0").
---@param op ComparisonOperator The operator (e.g. ">", "<=", "=").
---@param v PartialVersion The parsed version (possibly partial; wildcard components are nil).
---@return SemverComparator[] comparators The expanded comparator(s) equivalent to the original partial comparator.
operatorComparators = (op, v) ->
  -- "=" is just an X-range (e.g. `=1.2` is the same as `1.2.x`) so it is delegated.
  return xRangeComparators v if op == NPM_RANGE_TOKEN_EQ

  major, minor, patch = v.major, v.minor, v.patch
  -- A wildcard major (e.g. ">*", ">=x") applies the operator to "any version at all". ">" and "<" can never hold
  -- (no version is greater/less than every version) while  ">=" and "<=" always hold.
  return (op == NPM_RANGE_TOKEN_GT or op == NPM_RANGE_TOKEN_LT) and {{op: Op.LT, num: 0}} or {{op: Op.GTE, num: 0}} if major == nil
  if minor == nil or patch == nil
    switch op
      when NPM_RANGE_TOKEN_GT  then return {{op: Op.GTE, num: minor == nil and encodeVersion(major + 1, 0, 0) or encodeVersion(major, minor + 1, 0)}}
      when NPM_RANGE_TOKEN_LTE then return {{op: Op.LT,  num: minor == nil and encodeVersion(major + 1, 0, 0) or encodeVersion(major, minor + 1, 0)}}
      when NPM_RANGE_TOKEN_LT  then return {{op: Op.LT,  num: encodeVersion major, minor or 0, 0}}
      when NPM_RANGE_TOKEN_GTE then return {{op: Op.GTE, num: encodeVersion major, minor or 0, 0}}
  {{op: op, num: encodeVersion major, minor, patch}}

---Takes two versions `a` and `b` extracted from a hyphen range and returns a pair comparator tables
---representing the equivalent range. 
---@param aVersion PartialVersion The left-hand side of the hyphen range.
---@param bVersion PartialVersion The right-hand side of the hyphen range.
---@return SemverComparator[] comparators The pair of comparators ({lower, upper}) representing the hyphen range.
hyphenComparators = (aVersion, bVersion) ->
  lower = {op: Op.GTE, num: encodeVersion aVersion.major or 0, aVersion.minor or 0, aVersion.patch or 0}
  upper = if bVersion.minor == nil
    {op: Op.LT, num: encodeVersion((bVersion.major or 0) + 1, 0, 0)}
  elseif bVersion.patch == nil
    {op: Op.LT, num: encodeVersion(bVersion.major, bVersion.minor + 1, 0)}
  else
    {op: Op.LTE, num: encodeVersion(bVersion.major, bVersion.minor, bVersion.patch)}
  {lower, upper}

---Parse a single comparator token into a list of comparator tables.
---@param token string The comparator token (e.g. ">=1.2.3", "~1.2", "1.2.x").
---@return SemverComparator[]? comparators The parsed comparators, or nil on error.
---@return string? err Error message if parsing failed.
parseComparator = (token) ->
  head = token\sub 1, 1
  if head == NPM_RANGE_TOKEN_TILDE
    -- "~>" is an undocumented but supported alias for "~" - a RubyGems "pessimistic version constraint"
    prefix = token\sub(1, 2) == NPM_RANGE_TOKEN_RUBY_PESSIMISTIC and NPM_RANGE_TOKEN_RUBY_PESSIMISTIC or NPM_RANGE_TOKEN_TILDE
    v, err = parsePartialVersion token\sub(#prefix + 1)
    return nil, err unless v
    return tildeComparators v
  if head == NPM_RANGE_TOKEN_CARET
    v, err = parsePartialVersion token\sub 2
    return nil, err unless v
    return caretComparators v

  op = nil
  if token\sub(1, 2) == NPM_RANGE_TOKEN_GTE or token\sub(1, 2) == NPM_RANGE_TOKEN_LTE
    op, token = token\sub(1, 2), token\sub 3
  elseif head == NPM_RANGE_TOKEN_GT or head == NPM_RANGE_TOKEN_LT or head == NPM_RANGE_TOKEN_EQ
    op, token = head, token\sub 2
  v, err = parsePartialVersion token
  return nil, err unless v
  op and operatorComparators(op, v) or xRangeComparators v

---Parse one ||-separated group of whitespace-separated comparators into a list of comparator tables.
---@param groupStr string The comparator group string.
---@return SemverComparator[]? comparators The parsed comparators, or nil on error.
---@return string? err Error message if parsing failed.
parseComparatorSet = (groupStr) ->
  groupStr = Common.trim groupStr
  return {{op: Op.GTE, num: 0}} if groupStr == ""

  fromStr, toStr = groupStr\match "^(.-)%s+%-%s+(.+)$"
  if fromStr
    fromVer, errFrom = parsePartialVersion fromStr
    return nil, errFrom unless fromVer
    toVer, errTo = parsePartialVersion toStr
    return nil, errTo unless toVer
    return hyphenComparators fromVer, toVer
  
  comparators = {}
  for token in groupStr\gmatch "%S+"
    parts, err = parseComparator token
    return nil, err unless parts
    comparators[#comparators + 1] = comparator for comparator in *parts
  comparators

---Reduces an AND-list of comparators to a single half-open interval [min,max).
---@param comparators SemverComparator[]
---@return SemverInterval interval The reduced interval (min inclusive, max exclusive).
reduceToInterval = (comparators) ->
  min, max = 0, SEMVER_RANGE_MAX_EXCLUSIVE
  for comp in *comparators
    switch comp.op
      when Op.GTE then min = math.max min, comp.num
      when Op.GT  then min = math.max min, comp.num + 1
      when Op.LTE then max = math.min max, comp.num + 1
      when Op.LT  then max = math.min max, comp.num
      when Op.EQ  then min, max = math.max(min, comp.num), math.min(max, comp.num + 1)
  {:min, :max}


---Splits a range string into `||` groups, reduces each to an interval, and drops empty ones. The
---public entry point (with the type guard and full syntax docs) is SemanticVersioning.parseRange.
---@param range string The version range.
---@return SemverInterval[]? intervals The range's non-empty intervals, or nil on a malformed range.
---@return string? err Error message on failure.
parseRangeToIntervals = (range) ->
  range = Common.trim range
  groups, start = {}, 1
  while true
    s, e = range\find NPM_RANGE_TOKEN_OR, start, true
    if s
      groups[#groups + 1] = range\sub start, s - 1
      start = e + 1
    else
      groups[#groups + 1] = range\sub start
      break
  intervals = {}
  for groupStr in *groups
    comparators, err = parseComparatorSet groupStr
    return nil, err unless comparators
    interval = reduceToInterval comparators
    intervals[#intervals + 1] = interval if interval.min < interval.max
  intervals

---Semantic versioning utilities.
---@class SemanticVersioning
class SemanticVersioning
  semParts = {{"major", 16}, {"minor", 8}, {"patch", 0}}

  --- Converts a version number or string to a semantic version string.
  ---@param version number|string
  ---@param precision? SemverPrecision
  ---@return string|nil versionString
  ---@return string|nil err
  @toString = (version, precision = "patch") =>
    if type(version) == "string"
      version, err = @toNumber version
      return nil, err unless version
    
    parts = {0, 0, 0}
    for i, part in ipairs semParts
      parts[i] = bit.rshift(version, part[2]) % 256
      break if precision == part[1]

    return "%d.%d.%d"\format unpack parts


  ---Converts a semantic version string or number to an integer.
  ---@param value string|number|nil The version as a string (e.g. "1.2.3"), a number, or nil.
  ---@return number|false version The integer version, or false on error.
  ---@return string? err Error message if conversion failed.
  @toNumber = (value) =>
    return switch type value
      when "number" then math.max value, 0
      when "nil" then 0
      when "string"
        matches = {value\match "^(%d+)%.(%d+)%.(%d+)$"}
        if #matches != 3
          return false, msgs.toNumber.badString\format value

        version = 0
        for i, part in ipairs semParts
          value = tonumber matches[i]
          if type(value) != "number" or value > 255
            return false, msgs.toNumber.overflow\format part[1], tostring value

          version += bit.lshift value, part[2]
        version

      else false, msgs.toNumber.badType\format type value


  ---Checks whether version `a` is greater than or equal to version `b`, up to the given precision.
  ---When `precision` is "range", `b` is instead an npm-style version range string and the result is
  ---whether `a` satisfies that range (see satisfiesRange).
  ---@param a number|string The first version.
  ---@param b number|string The second version, or an npm-style range string when precision is "range".
  ---@param precision? SemverPrecision Precision to compare at (default "patch").
  ---@return boolean? result True if a satisfies b, or nil on error.
  ---@return number|string masked The masked value of b on success (absent for ranges), or the error message on failure.
  @check: (a, b, precision = "patch") =>
    if type(a) != "number"
      a, err = @toNumber a
      return nil, err unless a

    return @satisfiesRange a, b if precision == "range"

    if type(b) != "number"
      b, err = @toNumber b
      return nil, err unless b

    mask = 0
    for part in *semParts
      mask += 0xFF * 2^part[2]
      break if precision == part[1]

    b = bit.band b, mask
    return a >= b, b

  ---Parses an npm-style version range into its set of half-open integer intervals `[min,max)` 
  --- (`min`inclusive, `max` exclusive). Supports the following range syntax:
  --- * comparators: `>=1.2.7`, `<=1.2.7`, `>1.2.7`, `<1.2.7`, `=1.2.7`
  --- * intersection: `>=1.2.7 <1.3.0`
  --- * union: `>=1.2.7 <1.3.0 || >=1.4.0 <2.0.0`
  --- * hyphen ranges: `1.2 - 2.3`
  --- * X-ranges: `1.x`, `*`
  --- * tilde ranges: `~1.2.3`
  --- * caret ranges: `^1.2.3`
  ---An unsatisfiable range (e.g. `>2 <1`) yields an empty list. 
  ---Pre-release/build labels are not supported at this time.
  ---@param range string The version range.
  ---@return SemverInterval[]? intervals The range's intervals, or nil on a malformed range.
  ---@return string? err Error message on failure.
  @parseRange = (range) =>
    return nil, msgs.range.badType\format type range unless type(range) == "string"
    parseRangeToIntervals range

  ---Reports whether a version satisfies an npm-style semver range.
  ---@param version number|string The version to test.
  ---@param range string The version range.
  ---@return boolean? satisfies True/false, or nil on error (a malformed version or range).
  ---@return string? err Error message on failure.
  @satisfiesRange = (version, range) =>
    unless type(version) == "number"
      version, err = @toNumber version
      return nil, err unless version
    intervals, err = @parseRange range
    return nil, err unless intervals
    for interval in *intervals
      return true if version >= interval.min and version < interval.max
    false

  ---Reports whether two npm-style version ranges overlap for at least one version.
  ---@param rangeA string The first version range.
  ---@param rangeB string The second version range.
  ---@return boolean? intersect True/false, or nil on error (a malformed range).
  ---@return string? err Error message on failure.
  @rangesIntersect = (rangeA, rangeB) =>
    intervalsA, errA = @parseRange rangeA
    return nil, errA unless intervalsA
    intervalsB, errB = @parseRange rangeB
    return nil, errB unless intervalsB
    for a in *intervalsA
      for b in *intervalsB
        return true if math.max(a.min, b.min) < math.min(a.max, b.max)
    false

  ---Returns the highest version that satisfies an npm-style range.
  ---@param range string The version range.
  ---@return number? version The greatest satisfying version, or nil on an unsatisfiable range or a malformed one.
  ---@return string? err Error message on a malformed range.
  @getRangeMaxVersion = (range) =>
    intervals, err = @parseRange range
    return nil, err unless intervals
    highest = nil
    for interval in *intervals
      highest = interval.max - 1 if not highest or interval.max - 1 > highest
    highest

  ---Reports whether `version` is strictly higher than `reference`. Raises on invalid input.
  ---Call as a plain static (`SemanticVersioning.isHigher a, b`), e.g. as a table.sort comparator.
  ---@param version number|string
  ---@param reference number|string
  ---@return boolean
  @isHigher = (version, reference) ->
    version, errMsg = SemanticVersioning\toNumber version
    assert version, errMsg
    referenceVersionNumber, errMsg = SemanticVersioning\toNumber reference
    assert referenceVersionNumber, errMsg

    return version > referenceVersionNumber

  ---Reports whether `version` is strictly lower than `reference`. Raises on invalid input.
  ---Call as a plain static (`SemanticVersioning.isLower a, b`), e.g. as a table.sort comparator.
  ---@param version number|string
  ---@param reference number|string
  ---@return boolean
  @isLower = (version, reference) ->
    version, errMsg = SemanticVersioning\toNumber version
    assert version, errMsg
    referenceVersionNumber, errMsg = SemanticVersioning\toNumber reference
    assert referenceVersionNumber, errMsg

    return version < referenceVersionNumber
