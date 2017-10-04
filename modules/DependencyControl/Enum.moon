Logger = require "l0.DependencyControl.Logger"

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
}

class Enum
  @logger = Logger fileBaseName: "DependencyControl.Enum"
  @reservedKeys = reservedKeys
  @isReservedKey = (k) => 
    return type(k) == "string" and (k\sub(1,2) == "__" or reservedKeySet[k]) or false


  new: (@name, values, @__logger = @@logger) =>
    @__logger\assert type(@name) == "string", msgs.new.missingOrInvalidName, Logger\describeType @name
    @elements, @__valuesToKeys, @values, @keys = {}, {}, {}, {}

    for k, v in pairs values
      -- we support lists as input, but we do not support numerical keys, which is sane
      if "number" == type k
        k, v = v, k

      @__logger\assert not @@isReservedKey(k), msgs.new.noReservedKeys, k
      @__logger\assert @elements[k] == nil, msgs.new.keyAlreadyDefined, k, @name
      @__logger\assert @__valuesToKeys[v] == nil, msgs.new.valueAlreadyTaken, k, @name, v, @__valuesToKeys[v]

      @elements[k], @__valuesToKeys[v] = v, k
      table.insert @values, v
      table.insert @keys, k

    meta = getmetatable @
    clsIdx = meta.__index

    setmetatable @, setmetatable {
      __index: (k) =>
        if @elements[k]
          return @elements[k]

        v = switch type clsIdx
          when "function" then clsIdx @, k
          when "table" then clsIdx[k]
        return v if v != nil
        
        @__logger\error msgs.__index.invalidKeyAccess, k, @name 
    
      __newindex: (k, v) =>
        @__logger\error msgs.__newindex.immutableError, k, v, @name
    }, clsIdx


  test: (key) =>
    val = @elements[key]
    return val != nil and true or false, val


  describe: (values, join = false) =>
    key = @__valuesToKeys[values]
    if key != nil
      return key

    if "table" != type values
      return nil, msgs.describe.valueNotDefined

    keys = for v in *values
      key = @__valuesToKeys[v]
      if key == nil
        join and '<invalid>' or nil 
      else key

    return join and table.concat(keys, join == true and ', ' or join) or keys