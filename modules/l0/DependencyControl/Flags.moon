bit = require "bit"
Enum = require "l0.DependencyControl.Enum"

-- the bit library works on 32-bit words and hands back a signed result, so every value crossing it is
-- taken back to the unsigned reading the constants are written in
UNSIGNED_32_BIT = 0x100000000

reservedKeys = {
  "clear",
  "combine",
  "has",
  "mask",
  "toList",
  "toggle"
}
reservedKeySet = {key, true for key in *reservedKeys}

msgs = {
  new: {
    noReservedKeys: "Key may not be any of the reserved words [#{table.concat reservedKeys, ', '}] (was '%s')."
    valueOutOfRange: "Value %s for '%s' in flags '%s' does not fit in the 32 bits a flag field holds."
  }
  resolveFlag: {
    unknownKey: "Flags '%s' defines no member named '%s'."
    invalidType: "A flag has to be a member name or a number, got a '%s'."
  }
  validate: {
    argPrefix: "Argument %s: "
    notANumber: "%sInvalid value '%s' for flags '%s': expected a number."
    unknownBits: "%sValue %s for flags '%s' sets bits no member defines (%s)."
    exclusive: "%sValue %s for flags '%s' sets %s at once, which exclude each other."
  }
  combine: {
    exclusive: "Cannot combine %s in flags '%s': they exclude each other."
  }
}

---Throws when the condition is false or nil, filling the template with the values that follow.
---@param logger? Logger Logger to throw through; throws with `assert` where the flag set has none.
---@param condition any Throws when this is false or nil.
---@param template string Message template, filled with the values that follow.
---@param ... any Values to fill the template with.
---@return any condition The condition itself, when it was neither false nor nil.
check = (logger, condition, template, ...) ->
  return condition if condition
  return logger\error template, ... if logger
  count = select "#", ...
  assert false, count == 0 and template or
    template\format unpack [tostring select index, ... for index = 1, count]

---Takes a bit operation's signed 32-bit result back to the unsigned reading.
---@param value integer
---@return integer unsigned
toUnsigned = (value) -> value % UNSIGNED_32_BIT

---An `Enum` treated as a bit field, so a value may combine any number of its members rather than
---being exactly one of them.
---
---Members are read off the type as on an `Enum` (`FontTrait.Bold`). `validate` accepts any combination
---of the members' bits rather than only a declared member, and `describe` names every member a value
---holds. `has` and `toList` read a packed value, while `combine`, `clear` and `toggle` build one as an
---unsigned 32-bit integer that an FFI call takes without conversion.
---
---Nesting a table of members inside the declaration marks them as excluding each other, for a word
---that holds one choice out of several alongside its free bits. `validate` and `combine` both refuse a
---value setting two members of one group; `clear` and `toggle` do not, a group being no obstacle to
---taking bits back out.
---@class Flags: Enum
---@field mask integer Every bit the members define between them, as one value.
class Flags extends Enum
  ---Reports whether `key` is reserved as a member name (a built-in member of the Flags or Enum classes)
  ---@param key string
  ---@return boolean reserved
  @isReservedKey = (key) =>
    return true if type(key) == "string" and reservedKeySet[key]
    return Enum.isReservedKey @, key

  ---Creates a flag set from a table of member/bit pairs, any nested table naming a group of members
  ---that exclude each other. Members read off the type flat whether they were nested or not.
  ---@param name string
  ---@param values table Member names against the bits they stand for; a member may combine others.
  ---@param options? EnumOptions|Logger How the type behaves; a logger may be given on its own instead.
  new: (name, values, options) =>
    -- Enum takes a flat table and reads a numeric key as a list entry, so the groups are lifted out
    -- and their members merged in before it sees any of them.
    flat, groups = {}, {}
    for key, value in pairs values
      unless "number" == type(key) and "table" == type value
        flat[key] = value
        continue

      group = {}
      for memberKey, memberValue in pairs value
        memberKey, memberValue = memberValue, memberKey if "number" == type memberKey
        flat[memberKey] = memberValue
        group[#group + 1] = memberKey
      table.sort group
      groups[#groups + 1] = group if #group > 1

    super name, flat, options
    logger = rawget @, "__logger"

    mask = 0
    for key in *@keys
      value = @elements[key]
      check logger, "number" == type(value) and value >= 0 and value < UNSIGNED_32_BIT,
        msgs.new.valueOutOfRange, value, key, name
      mask = bit.bor mask, value
    rawset @, "mask", toUnsigned mask

    -- a table literal reaches the constructor through pairs, whose order is undefined, so the members
    -- are put in a fixed one here for every listing to come back the same twice running
    ordered = [{:key, value: @elements[key]} for key in *@keys]
    table.sort ordered, (left, right) -> left.value < right.value
    rawset @, "__ordered", ordered
    rawset @, "__exclusive", groups

  ---Resolves a member name to its bits. Numbers pass through as-is.
  ---@private
  ---@param flag integer|string A member name, or the bits themselves.
  ---@return integer bits
  __resolveFlag: (flag) =>
    return flag if "number" == type flag
    logger = rawget @, "__logger"
    check logger, "string" == type(flag), msgs.resolveFlag.invalidType, type flag
    defined, value = @test flag
    check logger, defined, msgs.resolveFlag.unknownKey, @name, flag
    return value

  ---Reports whether a value holds every bit of the given flag.
  ---@param value integer The packed value to read.
  ---@param flag integer|string The member to look for, by name or by its bits.
  ---@return boolean held True for a flag of zero bits, which every value trivially holds.
  has: (value, flag) =>
    bits = @__resolveFlag flag
    return toUnsigned(bit.band value, bits) == toUnsigned bits

  ---Names the members of one exclusive group a value sets at once, where it sets more than one.
  ---
  ---A member of no bits is skipped, every value holding one of those. A group states such a member
  ---where the field's own zero stands for a choice, as `O_RDONLY` does among the open(2) access modes,
  ---and a value choosing it is indistinguishable from a value choosing nothing.
  ---@private
  ---@param value integer The packed value to read.
  ---@return string[]? clashing The members that clash, nil for a value setting at most one per group.
  __findExclusiveClash: (value) =>
    for group in *rawget @, "__exclusive"
      held = [key for key in *group when @elements[key] != 0 and @has value, @elements[key]]
      return held if #held > 1

  ---Combines any number of members into one packed value.
  ---@param ... integer|string Members to combine, by name or by their bits.
  ---@return integer value The combination, zero when nothing was given.
  combine: (...) =>
    combined = @__combineBits ...
    clashing = @__findExclusiveClash combined
    check rawget(@, "__logger"), not clashing, msgs.combine.exclusive,
      clashing and table.concat(clashing, " and "), @name
    return combined

  ---Combines members without judging the result, for the operations a group cannot speak to.
  ---@private
  ---@param ... integer|string Members to combine, by name or by their bits.
  ---@return integer value The combination, zero when nothing was given.
  __combineBits: (...) =>
    combined = 0
    combined = bit.bor combined, @__resolveFlag select index, ... for index = 1, select "#", ...
    return toUnsigned combined

  ---Returns a value with the given members taken out of it.
  ---@param value integer The packed value to start from.
  ---@param ... integer|string Members to take out, by name or by their bits.
  ---@return integer value The value without those bits.
  clear: (value, ...) =>
    return toUnsigned bit.band value, bit.bnot @__combineBits ...

  ---Returns a value with the given members flipped in it.
  ---@param value integer The packed value to start from.
  ---@param ... integer|string Members to flip, by name or by their bits.
  ---@return integer value The value with those bits inverted.
  toggle: (value, ...) =>
    return toUnsigned bit.bxor value, @__combineBits ...

  ---Names every member a value holds, ordered by the bits they stand for rather than by declaration,
  ---which a table literal does not preserve.
  ---
  ---A member standing for a combination of others is listed alongside the members it covers, since
  ---the value holds all of them.
  ---@param value integer The packed value to read.
  ---@return string[] members The member names it holds; empty for a value holding no bits.
  toList: (value) =>
    return [member.key for member in *rawget(@, "__ordered") when member.value != 0 and
      @has value, member.value]

  ---Describes the members a value holds, for a message or a log line.
  ---@param value integer The packed value to read.
  ---@param pattern? fun(key: string): string How to render one member, by default its name alone.
  ---@param join? string Separator between members, "|" by default.
  ---@return string described The members it holds, or "0" for a value holding none.
  describe: (value, pattern = ((key) -> key), join = "|") =>
    members = [pattern key for key in *@toList value]
    return #members > 0 and table.concat(members, join) or "0"

  ---Validates that a value sets only bits this type defines.
  ---@param value any
  ---@param argName? string Argument name to include in the error message.
  ---@return boolean? valid True for any combination of members, including none at all.
  ---@return string? err Validation error message when invalid.
  validate: (value, argName) =>
    prefix = argName != nil and msgs.validate.argPrefix\format(argName) or ""
    unless "number" == type(value) and value >= 0 and value < UNSIGNED_32_BIT
      return nil, msgs.validate.notANumber\format prefix, tostring(value), @name

    unknown = toUnsigned bit.band value, bit.bnot @mask
    unless unknown == 0
      return nil, msgs.validate.unknownBits\format prefix, value, @name, "0x%X"\format unknown

    clashing = @__findExclusiveClash value
    if clashing
      return nil, msgs.validate.exclusive\format prefix, value, @name,
        table.concat clashing, " and "

    return true

return Flags
