-- Common tests: namespace validation, terms, and shared utilities
-- (getAutomationDir, getTestDir, flatten, getObjectHash).
-- Called from Tests.moon as: (require "...test.Common") basePath
(basePath) ->
  ffi = require "ffi"
  Common = require "l0.DependencyControl.Common"

  {
    _description: "Tests for the Common base class: namespace validation, shared terms, and utilities."

    capitalizeTerms: (ut) ->
      ut\assertEquals Common.terms.capitalize("hello world"), "Hello world"

    -- validateNamespace: pure computation, no stubs needed

    validateNamespace_valid: (ut) ->
      result, err = Common.validateNamespace "l0.DependencyControl"
      ut\assertTrue result
      ut\assertNil err

    validateNamespace_multiPart: (ut) ->
      result, err = Common.validateNamespace "a.b.c"
      ut\assertTrue result
      ut\assertNil err

    validateNamespace_noDot: (ut) ->
      result, err = Common.validateNamespace "no-dot"
      ut\assertFalse result
      ut\assertString err

    validateNamespace_leadingDot: (ut) ->
      result, err = Common.validateNamespace ".foo.bar"
      ut\assertFalse result
      ut\assertString err

    validateNamespace_trailingDot: (ut) ->
      result, err = Common.validateNamespace "foo.bar."
      ut\assertFalse result
      ut\assertString err

    validateNamespace_invalidChars: (ut) ->
      result, err = Common.validateNamespace "foo bar.baz"
      ut\assertFalse result
      ut\assertString err

    validateNamespace_consecutiveDots: (ut) ->
      result, err = Common.validateNamespace "foo..bar"
      ut\assertFalse result
      ut\assertString err

    -- getAutomationDir

    getAutomationDir_automation: (ut) ->
      result = Common\getAutomationDir Common.ScriptType.Automation
      ut\assertString result
      ut\assertContains result, "autoload"

    getAutomationDir_module: (ut) ->
      result = Common\getAutomationDir Common.ScriptType.Module
      ut\assertString result
      ut\assertContains result, "include"

    getAutomationDir_customRoot: (ut) ->
      (ut\stub aegisub, "decode_path")\calls (path) -> path
      result = Common\getAutomationDir Common.ScriptType.Automation, "myroot"
      ut\assertString result
      ut\assertContains result, "myroot"
      ut\assertContains result, "autoload"

    getAutomationDir_unknown: (ut) ->
      result = Common\getAutomationDir 99
      ut\assertNil result

    -- getTestDir

    getTestDir_automation: (ut) ->
      result = Common\getTestDir Common.ScriptType.Automation
      ut\assertString result
      ut\assertContains result, "macros"

    getTestDir_module: (ut) ->
      result = Common\getTestDir Common.ScriptType.Module
      ut\assertString result
      ut\assertContains result, "modules"

    getTestDir_customRoot: (ut) ->
      (ut\stub aegisub, "decode_path")\calls (path) -> path
      result = Common\getTestDir Common.ScriptType.Module, "myroot"
      ut\assertString result
      ut\assertContains result, "myroot"
      ut\assertContains result, "DepUnit"

    -- flatten

    flatten_depth2Array: (ut) ->
      flat, n = Common.flatten {{"a", "b"}, {"c"}}, 2
      ut\assertEquals n, 3
      ut\assertEquals flat[1], "a"
      ut\assertEquals flat[2], "b"
      ut\assertEquals flat[3], "c"

    flatten_depth1StopsEarly: (ut) ->
      flat, n = Common.flatten {{"a", "b"}, "c"}, 1
      ut\assertEquals n, 2
      ut\assertTable flat[1]
      ut\assertEquals flat[2], "c"

    flatten_depth0NoFlatten: (ut) ->
      flat, n = Common.flatten {{"a"}, "b"}, 0
      ut\assertEquals n, 1
      ut\assertTable flat[1]

    flatten_scalar: (ut) ->
      flat, n = Common.flatten "hello"
      ut\assertEquals n, 1
      ut\assertEquals flat[1], "hello"

    flatten_returnsCount: (ut) ->
      _, n = Common.flatten {"x", "y", "z"}, 2
      ut\assertEquals n, 3

    flatten_toArrayTable: (ut) ->
      input = {42, "x"}
      converter = (v, typ) ->
        return {"a", "b"} if typ == "number"
        v
      flat, n = Common.flatten input, 2, converter
      ut\assertEquals n, 3
      ut\assertEquals flat[1], "a"
      ut\assertEquals flat[2], "b"
      ut\assertEquals flat[3], "x"

    -- listIncludes: exact (==) membership in an array

    listIncludes_found: (ut) ->
      ut\assertTrue Common.listIncludes {"a", "b", "c"}, "b"

    listIncludes_notFoundAndEmpty: (ut) ->
      ut\assertFalse Common.listIncludes {"a", "b"}, "z"
      ut\assertFalse Common.listIncludes {}, "a"

    -- getObjectHash: deterministic, order-independent SHA-1 of a (nested) value

    getObjectHash_isHexString: (ut) ->
      hash = Common.getObjectHash {a: 1, b: "two"}
      ut\assertString hash
      ut\assertMatches hash, "^%x+$"

    getObjectHash_deterministic: (ut) ->
      ut\assertEquals Common.getObjectHash({a: 1, b: 2}), Common.getObjectHash {a: 1, b: 2}

    getObjectHash_ignoresKeyOrder: (ut) ->
      ut\assertEquals Common.getObjectHash({a: 1, b: 2, c: 3}), Common.getObjectHash {c: 3, a: 1, b: 2}

    getObjectHash_nestedOrderIndependent: (ut) ->
      a = {x: {p: 1, q: 2}, y: 3}
      b = {y: 3, x: {q: 2, p: 1}}
      ut\assertEquals Common.getObjectHash(a), Common.getObjectHash b

    getObjectHash_distinguishesContent: (ut) ->
      ut\assertNotEquals Common.getObjectHash({v: "1"}), Common.getObjectHash {v: "2"}

    -- type tagging keeps the number 1 and the string "1" from colliding
    getObjectHash_typeTagged: (ut) ->
      ut\assertNotEquals Common.getObjectHash({v: 1}), Common.getObjectHash {v: "1"}

    -- equals: a cyclic value is treated as matched at that key, not as making the whole tables equal
    equals_cyclicRefs: (ut) ->
      cyc = (x) ->
        t = {:x}
        t.self = t
        t
      ut\assertFalse Common.equals cyc(1), cyc(2) -- a differing sibling key still makes them unequal
      ut\assertTrue Common.equals cyc(1), cyc(1)

    -- itemsEqual counts occurrences, so duplicate scalar items match by multiplicity
    itemsEqual_duplicateScalars: (ut) ->
      ut\assertTrue Common.itemsEqual {1, 1}, {1, 1}
      ut\assertTrue Common.itemsEqual {1, 2}, {1, 2}
      ut\assertFalse Common.itemsEqual {1, 1}, {1, 2}
      ut\assertFalse Common.itemsEqual {1, 1, 2}, {1, 2, 2}

    escapePattern_matchesLiterally: (ut) ->
      s = "a-mo.Line[1] (v2)+?*^$%"
      escaped = Common.escapePattern s
      ut\assertEquals (s\find escaped), 1
      ut\assertNil ("amo.Line[1] (v2)+?*^$%")\find "^" .. escaped -- hyphen no longer quantifies

    escapePattern_plainStringUnchanged: (ut) ->
      ut\assertEquals Common.escapePattern("l0_Functional"), "l0_Functional"

    _order: {
      "capitalizeTerms",
      "validateNamespace_valid", "validateNamespace_multiPart",
      "validateNamespace_noDot", "validateNamespace_leadingDot",
      "validateNamespace_trailingDot", "validateNamespace_invalidChars",
      "validateNamespace_consecutiveDots",
      "getAutomationDir_automation", "getAutomationDir_module",
      "getAutomationDir_customRoot", "getAutomationDir_unknown",
      "getTestDir_automation", "getTestDir_module", "getTestDir_customRoot",
      "flatten_depth2Array", "flatten_depth1StopsEarly", "flatten_depth0NoFlatten",
      "flatten_scalar", "flatten_returnsCount", "flatten_toArrayTable",
      "listIncludes_found", "listIncludes_notFoundAndEmpty",
      "getObjectHash_isHexString", "getObjectHash_deterministic", "getObjectHash_ignoresKeyOrder",
      "getObjectHash_nestedOrderIndependent", "getObjectHash_distinguishesContent",
      "getObjectHash_typeTagged", "equals_cyclicRefs", "itemsEqual_duplicateScalars",
      "escapePattern_matchesLiterally", "escapePattern_plainStringUnchanged"
    }
  }
