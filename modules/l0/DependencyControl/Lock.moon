constants = require "l0.DependencyControl.Constants"
NamedSemaphore = require "l0.DependencyControl.NamedSemaphore"
FileLock = require "l0.DependencyControl.FileLock"
Timer  = require "l0.DependencyControl.Timer"
Logger = require "l0.DependencyControl.Logger"
Enum   = require "l0.DependencyControl.Enum"
Crypto = require "l0.DependencyControl.Crypto"
FileOps = require "l0.DependencyControl.FileOps"
json   = require "json"

DEFAULT_LOCK_WAIT_INTERVAL = 250
DEFAULT_EXPIRY_DURATION = 5 * 60
DEFAULT_HOLDER_NAME = "unknown"

-- default lower bound on remaining lease before renew refreshes, so a renewal still lands
-- ahead of expiry despite system latency/hangs.
RENEW_SAFETY_MARGIN_MS = 2000

-- separates namespace from resource when hashing them into a single name token
NAMESPACE_RESOURCE_SEPARATOR = "\31"

--- Cooperative, named lock with per-resource granularity. Each distinct
-- (scope, namespace, resource) maps to its own OS lock, so unrelated resources lock
-- independently. A lock is mutually exclusive across every Lock instance -- and, for
-- Global scope, across every process -- that targets the same tuple.
--
-- Scope (see Lock.Scope) selects the primitive and reach of exclusion:
--   Process: a named semaphore whose name embeds the pid; only Lua states within this
--            process contend.
--   Global:  an OS advisory file lock (FileLock) shared by every process in the session --
--            use for resources shared between Aegisub instances (e.g. a config file). The
--            kernel releases it if the holder crashes, so it never stays stuck; it cannot,
--            however, be taken from a holder that is alive but hung.
--
-- While held, the holder's identity and lease are recorded in a per-resource side file for
-- diagnostics. Long operations should call renew! periodically to extend the recorded lease
-- so waiters don't mistake a busy holder for a crashed one.
-- @class Lock
class Lock
    msgs = {
        new: {
            lockNotReleased: "Lock holder '%s' (%s) did not release its lock on resource '%s.%s' before discarding it, cleaning up..."
        }
        lock: {
            trying:     "Trying to get a lock on resource '%s.%s' for holder '%s' (%s). Timeout in %ims..."
            failed:     "Could not attain lock on resource '%s.%s' for holder '%s' (%s): %s"
            heldByOther: "Lock on resource '%s.%s' is currently held by %s, retrying in %ims..."
            staleHolder: "Lock on resource '%s.%s' is held by %s whose lease lapsed %ds ago; the holder may have crashed or stalled without releasing it."
            alreadyHeld: "'%s' (%s) is already holding the lock on resource '%s.%s'."
            attained:   "'%s' (%s) attained the lock on resource '%s.%s'."
            timeout:    "Gave up trying to attain a lock on resource '%s.%s' for holder '%s' (%s) after timeout was reached."
            unavailable: "OS lock unavailable for resource '%s.%s'; '%s' (%s) is proceeding with a process-local lock only (no cross-process exclusion)."
        }
        release: {
            failed:   "Could not release lock on resource '%s.%s' for '%s' (%s): %s"
            notHeld:  "lock is not currently held by this instance"
            released: "'%s' (%s) released its lock on resource '%s.%s'."
        }
        renew: {
            notHeld: "cannot renew a lock that is not currently held by this instance"
        }
        guard: {
            notAcquired: "Could not acquire lock on resource '%s.%s' for holder '%s' (%s): lock state %s."
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

    @Scope = Enum "LockScope", {
        Process: "process"
        Global:  "global"
    }, @logger
    Scope = @Scope

    @uuid = ->
        -- https://gist.github.com/jrus/3197011
        "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"\gsub "[xy]", (c) ->
            v = c == "x" and math.random(0, 0xf) or math.random 8, 0xb
            return "%x"\format v

    -- Builds the OS lock primitive backing a lock: a named semaphore for Process scope, an
    -- advisory file lock for Global scope.
    -- @param scope string a Lock.Scope value
    -- @param token string OS-safe semaphore name token (Process scope)
    -- @param lockFile string full path to the lock file (Global scope)
    -- @return table a primitive exposing isOpen, tryLock and unlock
    @createPrimitive = (scope, token, lockFile) =>
        scopeIsValid, errMsg = Scope\validate scope, "scope"
        return nil, errMsg unless scopeIsValid

        if scope == Scope.Global
            FileLock lockFile
        else
            -- Process-scoped names embed our pid, so unlink them on close: a future process
            -- that reuses this pid must not inherit a stuck name.
            NamedSemaphore token, true

    -- Derives the OS-safe semaphore name token, holder-file path and Global lock-file path
    -- for a tuple.
    deriveNames = (scope, namespace, resource) ->
        hash = Crypto.sha1 "#{namespace}#{NAMESPACE_RESOURCE_SEPARATOR}#{resource}"
        token = scope == Scope.Global and "#{constants.DEPCTRL_SHORT_NAME}_global_#{hash}" or "#{constants.DEPCTRL_SHORT_NAME}_p#{NamedSemaphore.pid}_#{hash}"
        holderFilePath = aegisub.decode_path "?temp/depctrl_lock_#{token}.json"
        lockFilePath = aegisub.decode_path "?temp/depctrl_lock_#{token}.lock"
        return token, holderFilePath, lockFilePath

    --- Creates a lock for the given resource.
    -- @param args table fields: namespace, resource, holderName?, logger?, expiresAfter?,
    --   scope? (Lock.Scope, default Process), recordHolder? (default true),
    --   overrideExpiry? (default false -- when true, judge a foreign holder against this
    --   instance's expiresAfter instead of honoring the holder's recorded lease)
    new: (args) =>
        {namespace: @namespace, resource: @resource, holderName: @holderName, logger: @logger,
         expiresAfter: @expiresAfter, scope: @scope, recordHolder: @recordHolder,
         overrideExpiry: @overrideExpiry} = args
        
        @scope or= Scope.Process
        assert Scope\validate @scope, 'scope'

        @logger or= @@logger
        @expiresAfter or= DEFAULT_EXPIRY_DURATION
        @holderName or= DEFAULT_HOLDER_NAME
        @namespace or= ""
        @resource or= ""
        @recordHolder = true if @recordHolder == nil
        @instanceId = @@uuid!

        token, holderFilePath, lockFilePath = deriveNames @scope, @namespace, @resource
        @_holderFilePath = holderFilePath
        @_primitive = @@createPrimitive @scope, token, lockFilePath

        -- mutable held-state shared with the GC canary (avoids capturing self)
        state = {held: false}
        @_state = state

        -- release any still-held lock when this object is garbage collected.
        holderName, instanceId, namespace, resource, logger = @holderName, @instanceId, @namespace, @resource, @logger
        primitive, recordHolder = @_primitive, @recordHolder
        canary = newproxy true
        (getmetatable canary).__gc = ->
            if state.held
                pcall logger.warn, logger, msgs.new.lockNotReleased, holderName, instanceId, namespace, resource
                pcall ->
                    primitive\unlock!
                    FileOps.remove holderFilePath if recordHolder
                    state.held = false

        meta = getmetatable @
        setmetatable @, {
            __metatable: meta
            __index: meta.__index
            __canary: canary
        }

    -- Reads the holder record written by the current lock holder, or nil if none is
    -- present/parseable. Read lock-free, so the record may be stale or briefly absent.
    -- @return table|nil record
    _readHolder: =>
        return nil unless @recordHolder
        data = FileOps.readFile @_holderFilePath
        return nil unless data
        ok, record = pcall json.decode, data
        return ok and type(record) == "table" and record or nil

    -- Records this instance as the current holder in the side file, stamping the lease
    -- (expiresAt = now + expiresAfter) so waiters honor the holder's own expiry. Keeps the
    -- original @acquiredAt across renewals. Also tracks the lease end on the monotonic
    -- clock for this instance's own renew decisions (os.time is shared across processes but
    -- coarse and can jump; the monotonic clock is local but fine-grained and steady). No-op
    -- when holder recording is disabled; best-effort, so failures don't affect the lock.
    _writeHolder: =>
        return unless @recordHolder
        @expiresAt = os.time! + @expiresAfter
        @_leaseExpiresMono = Timer.getTime! + @expiresAfter
        record = {
            holderName: @holderName, instanceId: @instanceId, pid: NamedSemaphore.pid
            scope: @scope, namespace: @namespace, resource: @resource
            acquiredAt: @acquiredAt, expiresAt: @expiresAt
        }
        ok, data = pcall json.encode, record
        FileOps.writeFile @_holderFilePath, data, true if ok

    -- Removes the holder side file. No-op when holder recording is disabled.
    _clearHolder: =>
        FileOps.remove @_holderFilePath if @recordHolder

    -- Human-readable description of the current foreign holder for log messages, e.g.
    -- "'ConfigHandler' (pid 1234)" or "another instance" when no record is available.
    _describeHolder: (record) =>
        return "another instance" unless record
        "'#{record.holderName or DEFAULT_HOLDER_NAME}' (pid #{record.pid or "?"})"

    -- Timestamp at which a foreign holder's lease lapses, or nil if it can't be determined.
    -- Honors the holder's recorded expiresAt unless overrideExpiry is set, in which case
    -- this instance's expiresAfter is applied to the holder's acquiredAt instead.
    _holderDeadline: (record) =>
        return nil unless record
        if @overrideExpiry and record.acquiredAt
            return record.acquiredAt + @expiresAfter
        return record.expiresAt or (record.acquiredAt and record.acquiredAt + @expiresAfter)

    --- Returns the holder currently believed to hold this lock, or nil if it appears free.
    -- Reads the side file lock-free, so the result is advisory: a holder whose lease has
    -- lapsed (likely crashed) is reported as free, and a brand-new holder may not be visible
    -- yet. Reports this instance too when it holds the lock. Requires holder recording.
    -- @return table|nil record the holder record (holderName, pid, namespace, resource, ...)
    getActiveHolder: =>
        record = @_readHolder!
        return nil unless record
        deadline = @_holderDeadline record
        return nil if deadline and os.time! > deadline
        return record

    --- Returns the current lock state for this instance.
    -- Returns Held if this instance holds the lock, Unknown otherwise (the OS lock
    -- can't be queried for foreign holders without attempting to acquire it).
    -- @return number LockState
    getState: =>
        return @@LockState.Held if @_state.held
        @@LockState.Unknown

    --- Attempts to acquire the lock, waiting up to timeout milliseconds.
    -- @param[opt=math.huge] timeout number
    -- @param[opt=250] lockWaitInterval number
    -- @return number LockState
    -- @return number timePassed
    lock: (timeout = math.huge, lockWaitInterval = DEFAULT_LOCK_WAIT_INTERVAL) =>
        -- Without a working OS primitive we can't coordinate across states/processes;
        -- degrade to a process-local grant so DepCtrl keeps functioning, and warn once.
        unless @_primitive.isOpen
            unless @_state.held
                @logger\warn msgs.lock.unavailable, @namespace, @resource, @holderName, @instanceId
                @_state.held = true
                @acquiredAt = os.time!
                @_writeHolder!
            return @@LockState.Held, 0

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
                    if @_primitive\tryLock!
                        @_state.held = true
                        @acquiredAt = os.time!
                        @_writeHolder!
                        @logger\trace msgs.lock.attained, @holderName, @instanceId, @namespace, @resource
                        return @@LockState.Held, timePassed

                    -- held by someone else: surface who, and warn when the holder's lease has
                    -- lapsed (likely crashed or stalled). Informational only -- a Global file
                    -- lock self-heals on crash, and a live holder's lock is never force-stolen.
                    record = @_readHolder!
                    holderDesc = @_describeHolder record
                    deadline = @_holderDeadline record
                    if deadline and os.time! > deadline
                        @logger\warn msgs.lock.staleHolder, @namespace, @resource, holderDesc, os.time! - deadline

                    @logger\trace msgs.lock.heldByOther, @namespace, @resource, holderDesc, lockWaitInterval
                    Timer.sleep lockWaitInterval unless timeout == 0
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
        unless @_state.held
            return nil, msgs.release.failed\format @namespace, @resource, @holderName, @instanceId, msgs.release.notHeld
        @_primitive\unlock!
        @_clearHolder!
        @_state.held = false
        @acquiredAt = nil
        @_leaseExpiresMono = nil
        @logger\trace msgs.release.released, @holderName, @instanceId, @namespace, @resource
        return true, @@LockState.Available

    --- Refreshes the held lock's lease when it is close to expiring, re-stamping its recorded
    -- expiry to @expiresAfter from now. This only affects the metadata on the this Lock instance
    -- and the side file, so waiters don't mistake a busy holder for a crashed one. The underlying
    -- OS lock remains held until explicitly released. To avoid unnecessary writes, the side file
    -- is only updated when the remaining lease is approaching expiry.
    -- @param expiryThreshold? number renews only if the remaining lease is <= this many
    --   milliseconds. -1 forces an unconditional refresh. Defaults to whichever is larger of
    --   half the lease or RENEW_SAFETY_MARGIN_MS (capped at the full lease), so a refresh
    --   always lands well before expiry even under scheduling latency.
    -- @return boolean|nil renewed true if refreshed, false if still fresh
    -- @return string|nil err set (with nil renewed) only when the lock isn't held
    renew: (expiryThreshold) =>
        return nil, msgs.renew.notHeld unless @_state.held
        return false unless @recordHolder and @_leaseExpiresMono
        validForMs = @expiresAfter * 1000
        threshold = expiryThreshold or math.min math.max(validForMs / 2, RENEW_SAFETY_MARGIN_MS), validForMs
        unless threshold < 0  -- negative forces a refresh
            remainingMs = (@_leaseExpiresMono - Timer.getTime!) * 1000
            return false if remainingMs > threshold
        @_writeHolder!
        return true

    --- Acquires a lock for the given args and runs the provided body function.
    -- Releases the lock when the body function completes or throws.
    -- Passes the held Lock as an argument to the body function, so it can call renew on it if needed.
    -- @param args table Lock constructor args, plus optional timeout/lockWaitInterval applied to the acquire
    -- @param body function called with the held Lock; its return values are passed through
    -- @return any the body's return values on success, or nil + err on failure to acquire
    @guard = (args, body) =>
        lock = @ args
        state = lock\lock args.timeout or math.huge, args.lockWaitInterval or DEFAULT_LOCK_WAIT_INTERVAL
        unless state == @LockState.Held
            return nil, msgs.guard.notAcquired\format lock.namespace, lock.resource, lock.holderName, lock.instanceId, state
        results = table.pack pcall body, lock
        lock\release!
        error results[2], 0 unless results[1]
        return unpack results, 2, results.n
