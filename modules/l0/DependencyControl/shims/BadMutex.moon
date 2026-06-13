-- A stand-in for the process-scoped singleton BM.BadMutex, using our internal pure-FFI
-- NamedSemaphore implementation.

constants = require "l0.DependencyControl.Constants"
NamedSemaphore = require "l0.DependencyControl.NamedSemaphore"

-- A single fixed, process-private name
semaphore = NamedSemaphore "#{constants.DEPCTRL_SHORT_NAME}_BadMutex_p#{NamedSemaphore.pid}", true

mutex = {
    tryLock: -> semaphore\tryLock!
    lock:    -> semaphore\lock!
    unlock:  -> semaphore\unlock!
    -- the BM.BadMutex version this is compatible with
    version: "0.1.3"
}

return mutex
