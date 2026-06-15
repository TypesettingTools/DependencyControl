-- Logger tests: message formatting, dump serialization, and log dispatch.
-- Called from Tests.moon as: (require "...test.Logger")!
->
  Logger = require "l0.DependencyControl.Logger"

  {
    _description: "Tests for the Logger class covering message formatting, dump serialization, and log dispatch."

    -- format: pure computation, no stubs needed

    format_string: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\format "hello world", 0
      ut\assertEquals result, "hello world"

    format_printf: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\format "value: %d", 0, 42
      ut\assertEquals result, "value: 42"

    format_table: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\format {"line1", "line2"}, 0
      ut\assertEquals result, "line1\nline2"

    format_indent: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\format "line1\nline2", 1
      ut\assertContains result, "— line2"

    -- dumpToString: pure computation, no stubs needed

    dumpToString_scalar: (ut) ->
      logger = Logger toFile: false, toWindow: false
      ut\assertEquals logger\dumpToString("hello"), "hello"
      ut\assertEquals logger\dumpToString(42), "42"
      ut\assertEquals logger\dumpToString(true), "true"

    dumpToString_flatTable: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\dumpToString {key: "val"}
      ut\assertContains result, "key:"
      ut\assertContains result, "val"

    dumpToString_ignoreKey: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\dumpToString {keep: "yes", skip: "no"}, "skip"
      ut\assertContains result, "keep:"
      ut\assertNil result\find "skip:", 1, true

    dumpToString_maxDepth: (ut) ->
      logger = Logger toFile: false, toWindow: false
      nested = {inner: {deep: "value"}}
      result = logger\dumpToString nested, nil, 0
      ut\assertContains result, "<...>"

    dumpToString_circular: (ut) ->
      logger = Logger toFile: false, toWindow: false
      t = {}
      t.self = t
      result = logger\dumpToString t
      ut\assertContains result, "self: @1"

    -- log/dispatch: stubs aegisub.log

    log_dispatches: (ut) ->
      logger = Logger toFile: false, toWindow: true
      logStub = ut\stub aegisub, "log"
      result = logger\log 2, "hello"
      ut\assertTrue result
      logStub\assertCalledOnce!

    log_emptyMsg: (ut) ->
      logger = Logger toFile: false, toWindow: true
      logStub = ut\stub aegisub, "log"
      result = logger\log 2, ""
      ut\assertFalse result
      logStub\assertNotCalled!

    log_nonNumberLevel: (ut) ->
      logger = Logger toFile: false, toWindow: true
      logStub = ut\stub aegisub, "log"
      result = logger\log "hello"
      ut\assertTrue result
      logStub\assertCalledOnce!

    -- assert/assertNotNil: success path returns values, failure path throws

    assert_truthy: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result, extra = logger\assert true, "should not log"
      ut\assertTrue result
      ut\assertEquals extra, "should not log"

    assert_falsy: (ut) ->
      logger = Logger toFile: false, toWindow: false
      ok, err = pcall -> logger\assert false, "boom"
      ut\assertFalse ok
      ut\assertString err

    assertNotNil_value: (ut) ->
      logger = Logger toFile: false, toWindow: false
      result = logger\assertNotNil 0, "should not log"
      ut\assertEquals result, 0

    assertNotNil_nil: (ut) ->
      logger = Logger toFile: false, toWindow: false
      ok, err = pcall -> logger\assertNotNil nil, "boom"
      ut\assertFalse ok
      ut\assertString err

    _order: {
      "format_string", "format_printf", "format_table", "format_indent",
      "dumpToString_scalar", "dumpToString_flatTable", "dumpToString_ignoreKey",
      "dumpToString_maxDepth", "dumpToString_circular",
      "log_dispatches", "log_emptyMsg", "log_nonNumberLevel",
      "assert_truthy", "assert_falsy",
      "assertNotNil_value", "assertNotNil_nil"
    }
  }
