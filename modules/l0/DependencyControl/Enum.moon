reservedKeys = {
  "describe",
  "elements"
  "keys",
  "name",
  "test",
  "values"
}

reservedKeySet = {v, true for v in *reservedKeys}

msgs = {
  __index: {
    invalidKeyAccess: "Cannot access invalid key '%s' on Enum '%s'"
  }
  __newindex: {
    immutableError: "Cannot assign field '%s' to '%s' on immutable Enum '%s'."
  }
  new: {
    valueAlreadyTaken: "Could not define '%s' in enum '%s': value %s is already taken by '%s'."
    keyAlreadyDefined: "Cannot redefine key '%s' in enum '%s'."
    noReservedKeys: "Key may not be any of the reserved words [#{table.concat reservedKeys, ', '}] or start with '__' (was '%s')."
    missingOrInvalidName: "Missing or invalid Enum name (expected a string, got a '%s')."
  }
  describe: {
    valueNotDefined: "Value '%s' is not defined in enum '%s'."
  }
  validate: {
    argPrefix: "Argument %s: "
    invalidValue: "%sInvalid value '%s' for enum '%s'."
  }
}

---Formats a message template against values of any type.
---@param template string The template to fill.
---@param ... any Values to interpolate.
---@return string message
formatMessage = (template, ...) ->
  count = select "#", ...
  return template if count == 0
  return template\format unpack [tostring select index, ... for index = 1, count]

---Throws unless a contract holds, through the enum's logger where it has one and natively otherwise.
---@param logger? Logger The enum's logger, absent where none was given.
---@param condition any Throws unless this holds.
---@param template string The message template.
---@param ... any Values to interpolate.
---@return any condition The condition, where it held.
check = (logger, condition, template, ...) ->
  return condition if condition
  return logger\error template, ... if logger
  assert false, formatMessage template, ...

---An immutable enumeration type with value/key reverse lookup.
---@class Enum
class Enum
  ---Reports whether `k` is reserved as an enum key — a built-in member name or `__`-prefixed.
  ---@param k string
  ---@return boolean reserved
  @isReservedKey = (k) =>
    return type(k) == "string" and (k\sub(1,2) == "__" or reservedKeySet[k]) or false


  ---Creates an enum from a table of key/value pairs or a list of names.
  ---@param name string
  ---@param values table Key/value pairs, or a list of names whose value defaults to their position.
  ---@param logger? Logger Logger for enum error messages; without one they are thrown natively.
  new: (@name, values, @__logger) =>
    logger = @__logger -- avoid invalid key access error from metamethod if no logger was given
    check logger, type(@name) == "string", msgs.new.missingOrInvalidName, type @name
    @elements, @__keysByValue, @values, @keys = {}, {}, {}, {}

    for k, v in pairs values
      -- we support lists as input, but we do not support numerical keys, which is sane
      if "number" == type k
        k, v = v, k

      check logger, not @@isReservedKey(k), msgs.new.noReservedKeys, k
      check logger, @elements[k] == nil, msgs.new.keyAlreadyDefined, k, @name
      check logger, @__keysByValue[v] == nil, msgs.new.valueAlreadyTaken, k, @name, v, @__keysByValue[v]

      @elements[k], @__keysByValue[v] = v, k
      table.insert @values, v
      table.insert @keys, k

    meta = getmetatable @
    clsIdx = meta.__index

    setmetatable @, setmetatable {
      __index: (k) =>
        if @elements[k] != nil
          return @elements[k]

        v = switch type clsIdx
          when "function" then clsIdx @, k
          when "table" then clsIdx[k]
        return v if v != nil

        check logger, false, msgs.__index.invalidKeyAccess, k, @name

      __newindex: (k, v) =>
        check logger, false, msgs.__newindex.immutableError, k, v, @name
    }, clsIdx


  ---Returns whether the given key is defined in this enum.
  ---@param key string
  ---@return boolean defined
  ---@return any value The value mapped to the key, or nil if undefined.
  test: (key) =>
    val = @elements[key]
    return val != nil and true or false, val


  ---Returns a human-readable description of the given value(s) in this enum.
  ---@param values? any A single value, or a list of values to look up. If not provided, returns all keys.
  ---@param pattern? fun(key: string, value: any): string A function to format the key/value pair for display (default "<value> (<key>)").
  ---@param join? string|boolean Separator string for joining multiple keys, true for ", ", or false to return a list (default true).
  ---@return string|string[] result A single string when joining, or a list of the formatted keys when join is false.
  describe: (values = @values, pattern = ((key, value) -> "#{value} (#{key})"), join = true) =>
    values = {values} if "table" != type values

    keys = for v in *values
      key = @__keysByValue[v]
      check rawget(@, "__logger"), key != nil, msgs.describe.valueNotDefined, v, @name
      pattern key, v

    return join and table.concat(keys, join == true and ', ' or join) or keys

  ---Validates that a value is a member of this enum.
  ---@param value any
  ---@param argName? string Argument name to include in the error message.
  ---@return boolean? valid True when the value is a member, nil otherwise.
  ---@return string? err Validation error message when invalid.
  validate: (value, argName) =>
    if value == nil or @__keysByValue[value] == nil
      prefix = argName != nil and msgs.validate.argPrefix\format(argName) or ""
      return nil, msgs.validate.invalidValue\format prefix, value, @name

    return true

return Enum
