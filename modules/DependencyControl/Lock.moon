mutex        = require "BM.BadMutex"
PreciseTimer = require "PT.PreciseTimer"

Logger = require "l0.DependencyControl.Logger"
Enum   = require "l0.DependencyControl.Enum"

DEFAULT_LOCK_WAIT_INTERVAL = 250
DEFAULT_EXPIRY_DURATION = 5 * 60
DEFAULT_HOLDER_NAME = "unknown"

--- Cooperative mutex-based lock with a sqlite-compatible interface.
-- The namespace and resource parameters are accepted for interface compatibility
-- with the sqlite Lock but are not used for actual locking — the underlying
-- BadMutex is a single global mutex, so only one lock can be held at a time
-- regardless of namespace/resource. This is sufficient since no scripts write
-- to multiple config files concurrently.
-- @class Lock
class Lock
    msgs = {
        new: {
            lockNotReleased: "Lock holder '%s' (%s) did not release its lock on resource '%s.%s' before discarding it, cleaning up..."
        }
        lock: {
            trying:     "Trying to get a lock on resource '%s.%s' for holder '%s' (%s). Timeout in %ims..."
            failed:     "Could not attain lock on resource '%s.%s' for holder '%s' (%s): %s"
            heldByOther: "Lock on resource '%s.%s' is currently held, retrying in %ims..."
            alreadyHeld: "'%s' (%s) is already holding the lock on resource '%s.%s'."
            attained:   "'%s' (%s) attained the lock on resource '%s.%s'."
            timeout:    "Gave up trying to attain a lock on resource '%s.%s' for holder '%s' (%s) after timeout was reached."
        }
        release: {
            failed:   "Could not release lock on resource '%s.%s' for '%s' (%s): %s"
            notHeld:  "lock is not currently held by this instance"
            released: "'%s' (%s) released its lock on resource '%s.%s'."
        }
    }

    @logger = Logger fileBaseName: "DependencyControl.Lock"

    @LockState = Enum "LockState", {
        Unknown:     -1
        Unavailable:  0
        Available:    1
        Held:         2
    }, @logger
    LockState or= @LockState

    @uuid = ->
        -- https://gist.github.com/jrus/3197011
        "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"\gsub "[xy]", (c) ->
            v = c == "x" and math.random(0, 0xf) or math.random 8, 0xb
            return "%x"\format v

    --- Creates a lock for the given resource.
    -- @param args table
    new: (args) =>
        {namespace: @namespace, resource: @resource, holderName: @holderName, logger: @logger, expiresAfter: @expiresAfter} = args
        @logger or= @@logger
        @expiresAfter or= DEFAULT_EXPIRY_DURATION
        @holderName or= DEFAULT_HOLDER_NAME
        @instanceId = @@uuid!

        -- mutable held-state shared with the GC canary (avoids capturing self)
        held = {false}
        @_held = held

        -- release any still-held lock when this object is garbage collected
        -- the canary must not hold a reference to self, or it will never be collected
        holderName, instanceId, namespace, resource, logger = @holderName, @instanceId, @namespace, @resource, @logger
        canary = newproxy true
        (getmetatable canary).__gc = ->
            if held[1]
                pcall logger.warn, logger, msgs.new.lockNotReleased, holderName, instanceId, namespace, resource
                pcall ->
                    mutex.unlock!
                    held[1] = false

        meta = getmetatable @
        setmetatable @, {
            __metatable: meta
            __index: meta.__index
            __canary: canary
        }

    --- Returns the current lock state for this instance.
    -- Returns Held if this instance holds the lock, Unknown otherwise
    -- (the global mutex cannot be queried without attempting to acquire it).
    -- @return number LockState
    getState: =>
        return if @_held[1]
            @@LockState.Held
        else
            @@LockState.Unknown

    --- Attempts to acquire the lock, waiting up to timeout milliseconds.
    -- @param[opt=math.huge] timeout number
    -- @param[opt=250] lockWaitInterval number
    -- @return number LockState
    -- @return number timePassed
    lock: (timeout = math.huge, lockWaitInterval = DEFAULT_LOCK_WAIT_INTERVAL) =>
        timePassed = 0
        while timeout == math.huge or timeout >= timePassed
            @logger\trace msgs.lock.trying, @namespace, @resource, @holderName, @instanceId,
                          timeout == math.huge and math.huge or timeout - timePassed

            state = @getState!
            switch state
                when @@LockState.Held
                    @logger\trace msgs.lock.alreadyHeld, @holderName, @instanceId, @namespace, @resource
                    return @@LockState.Held, timePassed

                else -- Unknown: attempt to acquire
                    if mutex.tryLock!
                        @_held[1] = true
                        @logger\trace msgs.lock.attained, @holderName, @instanceId, @namespace, @resource
                        return @@LockState.Held, timePassed

                    @logger\trace msgs.lock.heldByOther, @namespace, @resource, lockWaitInterval
                    PreciseTimer.sleep lockWaitInterval unless timeout == 0
                    timePassed += lockWaitInterval

        @logger\trace msgs.lock.timeout, @namespace, @resource, @holderName, @instanceId
        return @@LockState.Unavailable, timePassed

    --- Attempts to acquire the lock without waiting.
    -- @return number LockState
    -- @return number timePassed
    tryLock: =>
        return @lock 0

    --- Releases the lock held by this instance.
    -- @return boolean|nil
    -- @return string|nil err
    release: =>
        unless @_held[1]
            return nil, msgs.release.failed\format @namespace, @resource, @holderName, @instanceId, msgs.release.notHeld
        mutex.unlock!
        @_held[1] = false
        @logger\trace msgs.release.released, @holderName, @instanceId, @namespace, @resource
        return true, @@LockState.Available
