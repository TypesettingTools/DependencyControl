-- Utils tests: flattening, list membership, deep equality, item equality, and pattern escaping.
-- Called from test.moon as: (controls\requireTest "utils")!
->
  utils = require "l0.DependencyControl.utils"

  {
    _description: "Tests for the general-purpose utility helpers."

    -- flatten

    flatten_depth2Array: (ut) ->
      flat, n = utils.flatten {{"a", "b"}, {"c"}}, 2
      ut\assertEquals n, 3
      ut\assertEquals flat[1], "a"
      ut\assertEquals flat[2], "b"
      ut\assertEquals flat[3], "c"

    flatten_depth1StopsEarly: (ut) ->
      flat, n = utils.flatten {{"a", "b"}, "c"}, 1
      ut\assertEquals n, 2
      ut\assertTable flat[1]
      ut\assertEquals flat[2], "c"

    flatten_depth0NoFlatten: (ut) ->
      flat, n = utils.flatten {{"a"}, "b"}, 0
      ut\assertEquals n, 1
      ut\assertTable flat[1]

    flatten_scalar: (ut) ->
      flat, n = utils.flatten "hello"
      ut\assertEquals n, 1
      ut\assertEquals flat[1], "hello"

    flatten_returnsCount: (ut) ->
      _, n = utils.flatten {"x", "y", "z"}, 2
      ut\assertEquals n, 3

    flatten_toArrayTable: (ut) ->
      input = {42, "x"}
      converter = (v, typ) ->
        return {"a", "b"} if typ == "number"
        v
      flat, n = utils.flatten input, 2, converter
      ut\assertEquals n, 3
      ut\assertEquals flat[1], "a"
      ut\assertEquals flat[2], "b"
      ut\assertEquals flat[3], "x"

    -- listIncludes: exact (==) membership in an array

    listIncludes_found: (ut) ->
      ut\assertTrue utils.listIncludes {"a", "b", "c"}, "b"

    listIncludes_notFoundAndEmpty: (ut) ->
      ut\assertFalse utils.listIncludes {"a", "b"}, "z"
      ut\assertFalse utils.listIncludes {}, "a"

    -- equals: a cyclic value is treated as matched at that key, not as making the whole tables equal
    equals_cyclicRefs: (ut) ->
      cyc = (x) ->
        t = {:x}
        t.self = t
        t
      ut\assertFalse utils.equals cyc(1), cyc(2) -- a differing sibling key still makes them unequal
      ut\assertTrue utils.equals cyc(1), cyc(1)

    -- itemsEqual counts occurrences, so duplicate scalar items match by multiplicity
    itemsEqual_duplicateScalars: (ut) ->
      ut\assertTrue utils.itemsEqual {1, 1}, {1, 1}
      ut\assertTrue utils.itemsEqual {1, 2}, {1, 2}
      ut\assertFalse utils.itemsEqual {1, 1}, {1, 2}
      ut\assertFalse utils.itemsEqual {1, 1, 2}, {1, 2, 2}

    escapePattern_matchesLiterally: (ut) ->
      s = "a-mo.Line[1] (v2)+?*^$%"
      escaped = utils.escapePattern s
      ut\assertEquals (s\find escaped), 1
      ut\assertNil ("amo.Line[1] (v2)+?*^$%")\find "^" .. escaped -- hyphen no longer quantifies

    escapePattern_plainStringUnchanged: (ut) ->
      ut\assertEquals utils.escapePattern("l0_Functional"), "l0_Functional"

    _order: {
      "flatten_depth2Array", "flatten_depth1StopsEarly", "flatten_depth0NoFlatten",
      "flatten_scalar", "flatten_returnsCount", "flatten_toArrayTable",
      "listIncludes_found", "listIncludes_notFoundAndEmpty",
      "equals_cyclicRefs", "itemsEqual_duplicateScalars",
      "escapePattern_matchesLiterally", "escapePattern_plainStringUnchanged"
    }
  }
