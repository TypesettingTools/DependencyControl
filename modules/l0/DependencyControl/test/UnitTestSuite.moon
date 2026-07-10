-- UnitTestSuite tests: the unit-test framework's own assertions and run loop.
-- Called from test.moon as: (controls\requireTest "UnitTestSuite")!
->
  UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
  UnitTest = UnitTestSuite.UnitTest

  -- A probe `self` for driving a single UnitTest assert method directly: its logger records the
  -- failure message/args and raises (mirroring the real logger's level-1 assert) so a failing assert
  -- is observable via pcall. `__class` lets `@@msgs`/`@format` resolve through UnitTest.__base.
  makeProbe = ->
    cap = {}
    setmetatable {
      __class: UnitTest
      assertFailed: false
      captured: cap
      logger: {
        assert: (cond) => cond   -- checkArgTypes passthrough when the arg types are valid
        logEx: (level, msg, _insertLineFeed, _prefix, _indent, ...) =>
          cap.msg, cap.args = msg, table.pack ...
          error "PROBE_ASSERT_FAILED"
      }
    }, __index: UnitTest.__base

  -- Replaces every logger a constructed suite holds (suite + each class/test/setup/teardown) with a
  -- no-op so a nested run() doesn't write to the live stream or a log file. Loggers are captured at
  -- construction, so this must run after the suite is built.
  silence = (suite) ->
    noop = {indent: 0, log: (->), warn: (->), logEx: (->), trace: (->), assert: ((cond) => cond)}
    suite.logger = noop
    for cls in *suite.classes
      cls.logger, cls.setup.logger, cls.teardown.logger = noop, noop, noop
      test.logger = noop for test in *cls.tests
    suite

  {
    _description: "Tests for the UnitTestSuite framework's own assertions and run loop."

    -- assertContains: regression for the inverted case-insensitivity and malformed failure message.

    assertContains_caseInsensitiveMatches: (ut) ->
      probe = makeProbe!
      ok = pcall UnitTest.assertContains, probe, "Hello World", "WORLD", false
      ut\assertTrue ok
      ut\assertFalse probe.assertFailed

    assertContains_caseSensitiveRejectsWrongCase: (ut) ->
      probe = makeProbe!
      ok = pcall UnitTest.assertContains, probe, "Hello World", "world"   -- default: case-sensitive
      ut\assertFalse ok
      ut\assertTrue probe.assertFailed

    assertContains_failureUsesContainsMessage: (ut) ->
      probe = makeProbe!
      pcall UnitTest.assertContains, probe, "abc", "xyz"
      ut\assertEquals probe.captured.msg, UnitTest.msgs.assert.contains

    -- assertNegative: regression for the wrong "positive" word and the missing value arg (the message
    -- template's %d crashed on format because `actual` wasn't passed).

    assertNegative_failureMessage: (ut) ->
      probe = makeProbe!
      pcall UnitTest.assertNegative, probe, 5   -- 5 isn't negative → the assertion fails
      ut\assertEquals probe.captured.args[1], "negative"
      ut\assertEquals probe.captured.args[3], 5   -- the value, now passed for the template's %d

    -- run(): regression for the crash when a test class's setup fails (the -1 sentinel was iterated).

    setupFailureDoesNotCrashRun: (ut) ->
      suite = UnitTestSuite "test.regression.setupCrash", {
        Failing: {
          _setup: -> error "intentional setup failure"
          neverRuns: (t) -> t\assertTrue true
        }
      }
      silence suite
      ok, success = pcall -> suite\run!
      ut\assertTrue ok        -- previously raised on `for … in *(-1)`
      ut\assertFalse success  -- the failed setup is reported as a suite failure

    -- ut\skip: a test that skips itself is marked skipped (not failed), aborts the rest of its body,
    -- and is reported as skipped with its reason; the suite run still succeeds.
    skip_marksSkippedAbortsAndReports: (ut) ->
      suite = UnitTestSuite "test.regression.skip", {
        Skipping: {
          skips: (t) ->
            t\skip "unmet precondition"
            t\assertTrue false   -- unreachable: skip aborts the body before this would fail
          passes: (t) -> t\assertTrue true
        }
      }
      silence suite
      ok, success = pcall -> suite\run!
      ut\assertTrue ok
      ut\assertTrue success   -- a skip is not a failure

      byName = {t.name, t for t in *suite.classes[1].tests}
      ut\assertTrue byName.skips.skipped
      ut\assertEquals byName.skips.skipReason, "unmet precondition"
      ut\assertFalse byName.passes.skipped

      summary = suite\toCtrf!.results.summary
      ut\assertEquals summary.skipped, 1
      ut\assertEquals summary.passed, 1
      ut\assertEquals summary.failed, 0

    -- a test absent from a class's _order still runs, appended (name-sorted) after the listed ones:
    -- _order sets the run order, not which tests run.
    runsTestsMissingFromOrder: (ut) ->
      ran = {}
      suite = UnitTestSuite "test.regression.orderMembership", {
        Partial: {
          _order: {"bbb", "aaa"}   -- non-alphabetical, and deliberately omits "ccc"
          aaa: (t) -> ran[#ran+1] = "aaa"
          bbb: (t) -> ran[#ran+1] = "bbb"
          ccc: (t) -> ran[#ran+1] = "ccc"
        }
      }
      silence suite
      suite\run!
      ut\assertEquals ran, {"bbb", "aaa", "ccc"}   -- listed order first, then the unlisted test appended
  }
