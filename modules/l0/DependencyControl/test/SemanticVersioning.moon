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

    -- check with precision "range": b is an npm-style range string

    check_rangeMode: (ut) ->
      ut\assertTrue SemanticVersioning\check("1.2.9", "~1.2.3", "range")
      ut\assertFalse SemanticVersioning\check("1.3.0", "~1.2.3", "range")

    check_rangeBadRange: (ut) ->
      result, err = SemanticVersioning\check "1.2.3", "garbage", "range"
      ut\assertNil result
      ut\assertString err

    -- satisfiesRange: npm semver range syntax

    satisfiesRange_tilde: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.3", "~1.2.3")
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.9", "~1.2.3")
      ut\assertFalse SemanticVersioning\satisfiesRange("1.3.0", "~1.2.3")
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.0", "~1.2")    -- ~1.2 => >=1.2.0 <1.3.0
      ut\assertFalse SemanticVersioning\satisfiesRange("2.0.0", "~1")     -- ~1 => >=1.0.0 <2.0.0

    satisfiesRange_caret: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("1.9.9", "^1.2.3")
      ut\assertFalse SemanticVersioning\satisfiesRange("2.0.0", "^1.2.3")
      ut\assertTrue SemanticVersioning\satisfiesRange("0.2.9", "^0.2.3")  -- 0.x: minor is left-most non-zero
      ut\assertFalse SemanticVersioning\satisfiesRange("0.3.0", "^0.2.3")
      ut\assertTrue SemanticVersioning\satisfiesRange("0.0.3", "^0.0.3")  -- 0.0.x: patch is left-most non-zero
      ut\assertFalse SemanticVersioning\satisfiesRange("0.0.4", "^0.0.3")

    satisfiesRange_xRangeAndAny: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("1.5.0", "1.x")
      ut\assertFalse SemanticVersioning\satisfiesRange("2.0.0", "1.x")
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.7", "1.2.x")
      ut\assertTrue SemanticVersioning\satisfiesRange("5.0.0", "*")
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.3", "")        -- empty range => any

    satisfiesRange_exact: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.3", "1.2.3")
      ut\assertFalse SemanticVersioning\satisfiesRange("1.2.4", "1.2.3")

    satisfiesRange_comparators: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("1.5.0", ">=1.2.3 <2.0.0")
      ut\assertFalse SemanticVersioning\satisfiesRange("2.0.0", ">=1.2.3 <2.0.0")
      ut\assertTrue SemanticVersioning\satisfiesRange("2.0.0", ">1")      -- >1 => >=2.0.0
      ut\assertFalse SemanticVersioning\satisfiesRange("1.5.0", ">1")
      ut\assertTrue SemanticVersioning\satisfiesRange("1.3.0", ">1.2")    -- >1.2 => >=1.3.0
      ut\assertTrue SemanticVersioning\satisfiesRange("1.0.0", "<=1")     -- <=1 => <2.0.0

    satisfiesRange_orUnion: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("0.9.0", "<1.0.0 || >=2.0.0")
      ut\assertTrue SemanticVersioning\satisfiesRange("2.1.0", "<1.0.0 || >=2.0.0")
      ut\assertFalse SemanticVersioning\satisfiesRange("1.5.0", "<1.0.0 || >=2.0.0")

    satisfiesRange_hyphen: (ut) ->
      ut\assertTrue SemanticVersioning\satisfiesRange("1.2.3", "1.2.3 - 2.3.4")
      ut\assertTrue SemanticVersioning\satisfiesRange("2.3.4", "1.2.3 - 2.3.4")   -- inclusive upper
      ut\assertFalse SemanticVersioning\satisfiesRange("2.4.0", "1.2.3 - 2.3.4")
      ut\assertTrue SemanticVersioning\satisfiesRange("2.3.9", "1.2.3 - 2.3")     -- partial upper => <2.4.0
      ut\assertFalse SemanticVersioning\satisfiesRange("2.4.0", "1.2.3 - 2.3")

    satisfiesRange_errors: (ut) ->
      r1, e1 = SemanticVersioning\satisfiesRange "1.2.3", "garbage"
      ut\assertNil r1
      ut\assertString e1
      r2, e2 = SemanticVersioning\satisfiesRange "bad", "1.2.3"
      ut\assertNil r2
      ut\assertString e2
      r3, e3 = SemanticVersioning\satisfiesRange "1.2.3", nil
      ut\assertNil r3
      ut\assertString e3

    -- parseRange: range string -> set of half-open [min, max) intervals

    parseRange_intervals: (ut) ->
      intervals = SemanticVersioning\parseRange "~1.2.3"
      ut\assertEquals #intervals, 1
      ut\assertEquals intervals[1].min, SemanticVersioning\toNumber "1.2.3"
      ut\assertEquals intervals[1].max, SemanticVersioning\toNumber "1.3.0"   -- exclusive upper

    parseRange_unsatisfiableIsEmpty: (ut) ->
      intervals = SemanticVersioning\parseRange ">2.0.0 <1.0.0"
      ut\assertEquals #intervals, 0

    parseRange_badType: (ut) ->
      result, err = SemanticVersioning\parseRange nil
      ut\assertNil result
      ut\assertString err

    -- rangesIntersect: do two ranges share any version?

    rangesIntersect_overlap: (ut) ->
      ut\assertTrue SemanticVersioning\rangesIntersect("~1.2.3", "~1.2")
      ut\assertTrue SemanticVersioning\rangesIntersect(">=1.0.0 <2.0.0", "^1.5.0")
      ut\assertTrue SemanticVersioning\rangesIntersect("1.x", "1.5.x")

    rangesIntersect_disjoint: (ut) ->
      ut\assertFalse SemanticVersioning\rangesIntersect("~1.2", "~1.3")    -- [1.2,1.3) vs [1.3,1.4) adjacent
      ut\assertFalse SemanticVersioning\rangesIntersect("<1.0.0", ">=1.0.0")
      ut\assertFalse SemanticVersioning\rangesIntersect("1.x", "2.x")

    rangesIntersect_unionGroups: (ut) ->
      ut\assertTrue SemanticVersioning\rangesIntersect("^1.0.0 || ^2.0.0", "~2.0")
      ut\assertFalse SemanticVersioning\rangesIntersect("^1.0.0 || ^3.0.0", "~2.0")

    rangesIntersect_emptyAndExactBounds: (ut) ->
      ut\assertFalse SemanticVersioning\rangesIntersect(">2.0.0 <1.0.0", "*")  -- contradictory range matches nothing
      ut\assertTrue SemanticVersioning\rangesIntersect("1.2.3 - 2.0.0", ">=2.0.0")  -- inclusive upper meets >=
      ut\assertFalse SemanticVersioning\rangesIntersect("1.2.3 - 1.9.9", ">=2.0.0")
      ut\assertFalse SemanticVersioning\rangesIntersect("=1.2.3", "=1.2.4")

    rangesIntersect_error: (ut) ->
      r, e = SemanticVersioning\rangesIntersect "garbage", "1.2.3"
      ut\assertNil r
      ut\assertString e

    -- getRangeMaxVersion: the highest version a range can supply (for ranking competing ranges)

    getRangeMaxVersion_bounds: (ut) ->
      ut\assertEquals SemanticVersioning\getRangeMaxVersion("^1"), SemanticVersioning\toNumber "1.255.255"
      ut\assertEquals SemanticVersioning\getRangeMaxVersion("~1.2"), SemanticVersioning\toNumber "1.2.255"
      ut\assertEquals SemanticVersioning\getRangeMaxVersion("*"), SemanticVersioning\toNumber "255.255.255"

    getRangeMaxVersion_unionTakesHighest: (ut) ->
      ut\assertEquals SemanticVersioning\getRangeMaxVersion("^1.0.0 || ^2.0.0"), SemanticVersioning\toNumber "2.255.255"

    getRangeMaxVersion_emptyAndError: (ut) ->
      ut\assertNil SemanticVersioning\getRangeMaxVersion ">2.0.0 <1.0.0"   -- empty range supplies nothing
      r, e = SemanticVersioning\getRangeMaxVersion "garbage"
      ut\assertNil r
      ut\assertString e

    _order: {
      "toNumber_string", "toNumber_zero", "toNumber_number", "toNumber_nil",
      "toNumber_badString", "toNumber_overflow", "toNumber_badType",
      "toString_fromNumber", "toString_roundtrip", "toString_majorPrecision",
      "check_equal", "check_greater", "check_less", "check_majorPrecision", "check_badArg",
      "check_rangeMode", "check_rangeBadRange",
      "satisfiesRange_tilde", "satisfiesRange_caret", "satisfiesRange_xRangeAndAny",
      "satisfiesRange_exact", "satisfiesRange_comparators", "satisfiesRange_orUnion",
      "satisfiesRange_hyphen", "satisfiesRange_errors",
      "parseRange_intervals", "parseRange_unsatisfiableIsEmpty", "parseRange_badType",
      "rangesIntersect_overlap", "rangesIntersect_disjoint", "rangesIntersect_unionGroups",
      "rangesIntersect_emptyAndExactBounds", "rangesIntersect_error",
      "getRangeMaxVersion_bounds", "getRangeMaxVersion_unionTakesHighest", "getRangeMaxVersion_emptyAndError"
    }
  }
