SemanticVersioning = nil

--- Semantic versioning utilities.
-- @class SemanticVersioning
class SemanticVersioning
  msgs = {
    toNumber: {
      badString: "Can't parse version string '%s'. Make sure it conforms to semantic versioning standards."
      badType: "Argument had the wrong type: expected a string or number, got a %s."
      overflow: "Error: %s version must be an integer <= 255, got %s."
    }
  }

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


  --- Converts a semantic version string or number to an integer.
  -- @param value string|number|nil The version as string (e.g. "1.2.3"), number, or nil.
  -- @return number|false The integer version, or false on error.
  -- @return string|nil Error message if conversion failed.
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


  --- Checks if version a is greater than or equal to version b, up to the given precision.
  -- @param a number|string The first version (number or string).
  -- @param b number|string The second version (number or string).
  -- @param[opt="patch"] precision string The precision to use ("major", "minor", or "patch").
  -- @return boolean|nil True if a >= b, or nil on error.
  -- @return number|nil The masked version of b, or error message if failed.
  @check: (a, b, precision = "patch") =>
    if type(a) != "number"
      a, err = @toNumber a
      return nil, err unless a

    if type(b) != "number"
      b, err = @toNumber b
      return nil, err unless b

    mask = 0
    for part in *semParts
      mask += 0xFF * 2^part[2]
      break if precision == part[1]

    b = bit.band b, mask
    return a >= b, b

  isHigher: (version, reference) ->
    version, errMsg = SemanticVersioning\toNumber version
    assert version, errMsg
    referenceVersionNumber, errMsg = SemanticVersioning\toNumber reference
    assert referenceVersionNumber, errMsg

    return version > referenceVersionNumber

  isLower: (version, reference) ->
    version, errMsg = SemanticVersioning\toNumber version
    assert version, errMsg
    referenceVersionNumber, errMsg = SemanticVersioning\toNumber reference
    assert referenceVersionNumber, errMsg

    return version < referenceVersionNumber
