SQLiteDatabase = require "l0.DependencyControl.SQLiteDatabase"
Logger         = require "l0.DependencyControl.Logger"
PreciseTimer   = require "PT.PreciseTimer"
Enum           = require "l0.DependencyControl.Enum"

LOCKS_TABLE = "Locks"
DEFAULT_LOCK_WAIT_INTERVAL = 250
DEFAULT_EXPIRY_DURATION = 5*60
DEFAULT_HOLDER_NAME = "unknown"

class Lock
  msgs = {
    new: {
      failedDbConnect: "Failed to connect to the Lock database (%s)."
      lockNotReleased: "Lock holder '%s' (%s) did not release its lock on resource '%s.%s' before discarding it, cleaning up..."
    }
    getState: {
      failedGetLockState: "Failed to get lock state for resource '%s.%s': %s"
      purgingExpired: "Lock on resource '%s.%s' previously held by '%s' (%s) expired %s seconds ago - purging..."
      failedPurgeExpired: "Failed to purge expired lock for resource '%s.%s': %s"
    }
    lock: {
      trying: "Trying to get a lock on resource '%s.%s' for holder '%s' (%s). Timeout in %ims..."
      failed: "Could not attain lock on resource '%s.%s' for holder '%s' (%s): %s"
      heldByOther: "Lock is currently held by '%s' (%s), retrying in %ims..."
      alreadyHeld: "'%s' (%s) is already holding the lock on resource '%s.%s'."
      attained: "'%s' (%s) attained the lock on resource '%s.%s'."
      snatchedAway: "Someone else snatched away the lock on resourceu '%s.%s' before holder '%s' (%s) could acquire it."
      timeout: "Gave up trying to attain a lock on resource '%s.%s' for holder '%s' (%s) after timeout was reached."
    }
    release: {
      failed: "Could not release lock on resource '%s.%s' for '%s' (%s): %s"
      heldByOther: "lock is currently held by '%s' (%s)"
      notHeld: "lock is not currently held by anyone"
      released: "'%s' (%s) released its lock on resource '%s.%s'."
    }
  }

  db = nil
  @logger = Logger fileBaseName: "DependencyControl.Lock"

  @LockState = Enum "LockState", {
    Unavailable: 0
    Available: 1
    Held: 2
  }, @logger
  LockState or= @LockState

  @uuid = ->
    -- https://gist.github.com/jrus/3197011
    "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"\gsub "[xy]", (c) ->
      v = c == "x" and math.random(0, 0xf) or math.random 8, 0xb
      return "%x"\format v

  new: (args) =>
    {namespace: @namespace, resource: @resource, holderName: @holderName, logger: @logger, expires: @expiresAfter} = args
    @logger or= @@logger
    @expiresAfter or= DEFAULT_EXPIRY_DURATION
    @holderName or= DEFAULT_HOLDER_NAME

    unless db
      db, msg = SQLiteDatabase "l0.DependencyControl.Lock", nil, 200, @logger
      @logger\assert db, msgs.new.failedDbConnect, msg

    @instanceId = @@uuid!

    -- release any still held locks when this object is garbage collected 
    -- requires a proxy userdata object in luajit, which doesn't support Lua 5.2 table finalizers
    -- make sure the finalizer does not hold a reference to this object, or it will never be garbage collected
    namespace, resource, holderName, instanceId, logger = @namespace, @resource, @holderName, @instanceId, @logger
    canary = newproxy true
    (getmetatable canary).__gc = ->
      selfGetState = -> getState namespace, resource, holderName, instanceId, logger
      _, state = pcall selfGetState -- any exception in userdata finalizer will crash Aegisub
      if state == LockState.Held
        pcall logger.warn, logger, msgs.new.lockNotReleased, holder, instanceId, namespace, resource
        pcall release, namespace, resource, holderName, instanceId, logger, selfGetState
                       

    meta = getmetatable @
    setmetatable @, {
      __metatable: meta
      __index: meta.__index
      __canary: canary
    }

  getState = (namespace, resource, holderName, instanceId, logger) ->
    now = os.time!
    res, msg = db\selectFirst LOCKS_TABLE, nil, Namespace: namespace, Resource: resource
    return switch res
      when nil then msgs.getState.failedGetLockState\format namespace, resource, msg
      when false then LockState.Available
      else
        if res.Expires < now
          logger\debug msgs.getState.purgingExpired, namespace, resource, res.Holder, res.InstanceID, res.Expires - now
          res, msg = db\delete LOCKS_TABLE, Namespace: namespace, Resource: resource
          if res
            LockState.Available
          else nil, msgs.getState.failedPurgeExpired\format msg

        elseif res.Holder == holderName and res.InstanceID == instanceId
          LockState.Held

        else LockState.Unavailable, res.Holder, res.InstanceID

  getState: => getState @namespace, @resource, @holderName, @instanceId, @logger

  lock: (timeout = math.huge, lockWaitInterval = DEFAULT_LOCK_WAIT_INTERVAL) =>
    timePassed = 0
    while timeout == math.huge or timeout >= timePassed
      @logger\trace msgs.lock.trying, @namespace, @resource, @holderName, @instanceId,
                    timeout - timePassed

      state, holder, instanceId = @getState!
      switch state
        when @@LockState.Unavailable
          @logger\trace msgs.lock.heldByOther, holder, instanceId, lockWaitInterval 
          PreciseTimer.sleep lockWaitInterval unless timeout == 0
          timePassed += lockWaitInterval
          continue

        when @@LockState.Held
          @logger\trace msgs.lock.alreadyHeld, @holderName, @instanceId, @namespace, @resource
          return @@LockState.Held, timePassed

        when @@LockState.Available
          res, msg, code = db\insert LOCKS_TABLE, {
            Namespace: @namespace
            Resource: @resource
            Holder: @holderName
            InstanceID: @instanceId
            Expires: os.time! + @expiresAfter
          }

          if res
            @logger\trace msgs.lock.attained, @holderName, @instanceId, @namespace, @resource
            return @@LockState.Held, timePassed
          
          -- someone else may have snatched the lock since we last refreshed the state
          if code == SQLiteDatabase.Result.CONSTRAINT
            @logger\trace msgs.lock.snatchedAway, @namespace, @resource, @holderName, @instaceId
            continue

          return nil, msgs.lock.failed\format @namespace, @resource, @holderName, @instanceId, msg

        when nil
          return nil, msgs.lock.failed\format @namespace, @resource, @holderName, @instanceId, holder

    @logger\trace msgs.lock.timeout, @namespace, @resource, @holderName, @instanceId
    return @@LockState.Unavailable, timePassed

      
  tryLock: =>
    return @lock 0


  release = (namespace, resource, holderName, instanceId, logger, getStateFunc) ->
    state, holder, holderInstanceId = getStateFunc!
    return switch state
      when LockState.Held
        res, msg = db\delete LOCKS_TABLE, Namespace: namespace, Resource: resource
        if res
          logger\trace msgs.release.released, holderName, instanceId, namespace, resource
          true, LockState.Available
        else nil, msgs.release.failed\format namespace, resource, holderName, instanceId, msg

      when LockState.Available
        false, msgs.release.failed\format namespace, resource, holderName, instanceId, msgs.release.notHeld

      when LockState.Unavailable
        nil, msgs.release.failed\format namespace, resource, holderName, instanceId,
                                        msgs.release.heldByOther\format holder, holderInstanceId

      else nil, msgs.release.failed\format namespace, resource, holderName, instanceId, holder

  release: => release @namespace, @resource, @holderName, @instanceId, @logger, -> @getState!