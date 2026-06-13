-- Timer tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "Timer")!
() ->
  Timer = require "l0.DependencyControl.Timer"

  {
    _description: "Tests for the FFI-based Timer: monotonic timing and millisecond sleep."

    -- timeElapsed

    timeElapsed_nonNegative: (ut) ->
      t = Timer!
      ut\assertGreaterThanOrEquals t\timeElapsed!, 0

    timeElapsed_monotonic: (ut) ->
      t = Timer!
      a = t\timeElapsed!
      b = t\timeElapsed!
      ut\assertGreaterThanOrEquals b, a

    timeElapsed_advancesAfterSleep: (ut) ->
      t = Timer!
      Timer.sleep 20          -- 20 ms
      -- Require at least 10 ms to pass; allows 50% margin for CI jitter.
      ut\assertGreaterThan t\timeElapsed!, 0.010

    -- stopwatch: start / stop / reset

    stop_freezesElapsed: (ut) ->
      t = Timer!
      Timer.sleep 20
      t\stop!
      a = t\timeElapsed!
      Timer.sleep 20
      -- while stopped, the elapsed total must not advance
      ut\assertEquals t\timeElapsed!, a

    start_resumesAfterStop: (ut) ->
      t = Timer!
      Timer.sleep 20
      frozen = t\stop!\timeElapsed!
      t\start!
      Timer.sleep 20
      -- resuming measurement adds to the time accumulated before the stop
      ut\assertGreaterThan t\timeElapsed!, frozen

    reset_clearsAccumulated: (ut) ->
      t = Timer!
      Timer.sleep 20
      before = t\timeElapsed!
      t\reset!
      -- reset drops back to (near) zero, below the pre-reset total
      ut\assertLessThan t\timeElapsed!, before

    -- getTime: shared monotonic clock

    getTime_isCallable: (ut) ->
      ut\assertFunction Timer.getTime

    getTime_monotonic: (ut) ->
      a = Timer.getTime!
      Timer.sleep 5
      b = Timer.getTime!
      ut\assertGreaterThanOrEquals b, a

    -- sleep

    sleep_isCallable: (ut) ->
      -- Smoke test: sleep(0) must not error and must return.
      Timer.sleep 0
      ut\assertTrue true

    sleep_onClass: (ut) ->
      -- sleep is a static method accessible directly on the class.
      ut\assertFunction Timer.sleep

    sleep_onInstance: (ut) ->
      -- sleep is also accessible through an instance (class method inheritance).
      t = Timer!
      ut\assertFunction t.sleep

    _order: {
      "timeElapsed_nonNegative", "timeElapsed_monotonic",
      "timeElapsed_advancesAfterSleep",
      "stop_freezesElapsed", "start_resumesAfterStop", "reset_clearsAccumulated",
      "getTime_isCallable", "getTime_monotonic",
      "sleep_isCallable", "sleep_onClass", "sleep_onInstance"
    }
  }
