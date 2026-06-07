-- Additional Common tests: getAutomationDir, getTestDir, flatten.
-- Called from Tests.moon as: (require "...test.Common") basePath
(basePath) ->
  ffi    = require "ffi"
  Common = require "l0.DependencyControl.Common"

  {
    _description: "Tests for Common utilities: getAutomationDir, getTestDir, flatten."

    -- getAutomationDir

    getAutomationDir_automation: (ut) ->
      result = Common\getAutomationDir Common.ScriptType.Automation
      ut\assertString result
      ut\assertContains result, "autoload"

    getAutomationDir_module: (ut) ->
      result = Common\getAutomationDir Common.ScriptType.Module
      ut\assertString result
      ut\assertContains result, "modules"

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

    _order: {
      "getAutomationDir_automation", "getAutomationDir_module",
      "getAutomationDir_customRoot", "getAutomationDir_unknown",
      "getTestDir_automation", "getTestDir_module", "getTestDir_customRoot",
      "flatten_depth2Array", "flatten_depth1StopsEarly", "flatten_depth0NoFlatten",
      "flatten_scalar", "flatten_returnsCount", "flatten_toArrayTable",
      "getObjectHash_isHexString", "getObjectHash_deterministic", "getObjectHash_ignoresKeyOrder",
      "getObjectHash_nestedOrderIndependent", "getObjectHash_distinguishesContent",
      "getObjectHash_typeTagged"
    }
  }
