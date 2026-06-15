-- SemanticVersioning tests: toNumber, toString, and check.
-- Called from Tests.moon as: (require "...test.SemanticVersioning")!
->
  SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"

  {
    _description: "Tests for SemanticVersioning covering toNumber, toString, and check."

    -- toNumber

    toNumber_string: (ut) ->
      result, err = SemanticVersioning\toNumber "1.2.3"
      ut\assertEquals result, 66051
      ut\assertNil err

    toNumber_zero: (ut) ->
      result, err = SemanticVersioning\toNumber "0.0.0"
      ut\assertEquals result, 0
      ut\assertNil err

    toNumber_number: (ut) ->
      result = SemanticVersioning\toNumber 66051
      ut\assertEquals result, 66051

    toNumber_nil: (ut) ->
      result = SemanticVersioning\toNumber nil
      ut\assertEquals result, 0

    toNumber_badString: (ut) ->
      result, err = SemanticVersioning\toNumber "1.2"
      ut\assertFalse result
      ut\assertString err

    toNumber_overflow: (ut) ->
      result, err = SemanticVersioning\toNumber "1.256.0"
      ut\assertFalse result
      ut\assertString err

    toNumber_badType: (ut) ->
      result, err = SemanticVersioning\toNumber {}
      ut\assertFalse result
      ut\assertString err

    -- toString

    toString_fromNumber: (ut) ->
      result, err = SemanticVersioning\toString 66051
      ut\assertEquals result, "1.2.3"
      ut\assertNil err

    toString_roundtrip: (ut) ->
      result, err = SemanticVersioning\toString "1.2.3"
      ut\assertEquals result, "1.2.3"
      ut\assertNil err

    toString_majorPrecision: (ut) ->
      result = SemanticVersioning\toString 66051, "major"
      ut\assertEquals result, "1.0.0"

    -- check

    check_equal: (ut) ->
      result, b = SemanticVersioning\check "1.2.3", "1.2.3"
      ut\assertTrue result

    check_greater: (ut) ->
      result = SemanticVersioning\check "2.0.0", "1.0.0"
      ut\assertTrue result

    check_less: (ut) ->
      result = SemanticVersioning\check "1.0.0", "2.0.0"
      ut\assertFalse result

    check_majorPrecision: (ut) ->
      result = SemanticVersioning\check "2.0.0", "1.9.9", "major"
      ut\assertTrue result

    check_badArg: (ut) ->
      result, err = SemanticVersioning\check "bad", "1.0.0"
      ut\assertNil result
      ut\assertString err

    _order: {
      "toNumber_string", "toNumber_zero", "toNumber_number", "toNumber_nil",
      "toNumber_badString", "toNumber_overflow", "toNumber_badType",
      "toString_fromNumber", "toString_roundtrip", "toString_majorPrecision",
      "check_equal", "check_greater", "check_less", "check_majorPrecision", "check_badArg"
    }
  }
