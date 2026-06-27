-- NamedSemaphore tests: the named binary-semaphore primitive, exercised against real OS semaphores
-- (CreateSemaphoreA on Windows, sem_open on POSIX). Skipped where the semaphore FFI is unavailable.
-- Called from test.moon as: (controls\requireTest "NamedSemaphore")!
() ->
  NamedSemaphore = require "l0.DependencyControl.NamedSemaphore"

  -- a fresh, random [A-Za-z0-9_] token per call so concurrent runs don't collide on a persisted POSIX name
  token = -> "DepCtrlTest_#{'%08X'\format math.random 0, 16^8-1}"

  {
    _description: "NamedSemaphore: the cross-process binary semaphore, against real OS semaphores."
    _condition: -> NamedSemaphore.isAvailable, "no semaphore FFI on this platform/build"

    pidIsExposed: (ut) ->
      ut\assertEquals type(NamedSemaphore.pid), "number"

    -- a binary semaphore acquires once (1 -> 0), refuses a second (non-reentrant) tryLock, then releases
    -- and can be acquired again. unlinkOnClose cleans up the OS name on POSIX (no effect on Windows).
    acquiresExclusivelyAndReleases: (ut) ->
      sem = NamedSemaphore token!, true
      ut\assertTrue sem.isOpen
      ut\assertTrue sem\tryLock!
      ut\assertFalse sem\tryLock!
      ut\assertTrue sem\unlock!
      ut\assertTrue sem\tryLock!
      sem\unlock!

    -- a blocking lock() on an available semaphore acquires immediately (without blocking)
    blockingLockAcquires: (ut) ->
      sem = NamedSemaphore token!, true
      ut\assertTrue sem\lock!
      sem\unlock!

    -- two handles to the same name share the one kernel semaphore and contend
    sameNameContends: (ut) ->
      name = token!
      a, b = NamedSemaphore(name, true), NamedSemaphore(name, true)
      ut\assertTrue a\tryLock!
      ut\assertFalse b\tryLock!
      a\unlock!
      ut\assertTrue b\tryLock!
      b\unlock!

    _order: {"pidIsExposed", "acquiresExclusivelyAndReleases", "blockingLockAcquires", "sameNameContends"}
  }
