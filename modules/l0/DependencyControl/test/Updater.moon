-- Updater tests.
-- Called from test.moon as: (controls\requireTest "Updater")!
() ->
  Updater = require "l0.DependencyControl.Updater"
  Common = require "l0.DependencyControl.Common"
  ModuleLoader = require "l0.DependencyControl.ModuleLoader"
  SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
  Lock = require "l0.DependencyControl.Lock"
  UpdateTask = require "l0.DependencyControl.UpdateTask"
  DependencyControl = require "l0.DependencyControl"
  UpdateStatus = Updater.UpdateStatus

  -- A stub updater self for require(): @addTask returns the supplied task (whose run() yields the
  -- scripted code/detail), so require's dispatch is exercised without constructing a real UpdateTask.
  makeRequireUpdater = (task) ->
    setmetatable {
      logger: {assert: ((c) => c), log: ->, debug: ->, trace: ->}
      addTask: ((record, tv, af, opt, ch, rsn) => task)
    }, __index: Updater.__base

  -- A stub updater self for scheduleUpdate(): its config gates the run and @addTask returns opts.task.
  makeScheduleUpdater = (opts = {}) ->
    setmetatable {
      config: {c: {updaterEnabled: opts.updaterEnabled, updateInterval: opts.updateInterval or 0}}
      logger: {trace: ->, log: ->}
      addTask: ((record) => opts.task)
    }, __index: Updater.__base

  {
    _description: "Tests for Updater: feed-trust getters, require/scheduleUpdate dispatch, and lock handling."

    -- Updater.getOfficialTrustedFeeds / getOfficialBlockedFeeds return DependencyControl's officially
    -- trusted feed set and blocked-prefix list, loading the feed once and caching it on the instance.
    -- With a pre-seeded cache the getters must short-circuit (loadOfficialFeedTrust returns early)
    -- instead of rebuilding it: assertIs checks the cache is the *same* table after the call (reference
    -- equality), which a rebuild would replace.

    getOfficialTrustedFeeds_usesCacheWhenPresent: (ut) ->
      cached = {trusted: {"feed://a": true}, blocked: {}}
      updater = {officialFeedTrust: cached}
      ut\assertTrue Updater.getOfficialTrustedFeeds(updater)["feed://a"]
      ut\assertIs updater.officialFeedTrust, cached

    getOfficialBlockedFeeds_usesCacheWhenPresent: (ut) ->
      cached = {trusted: {}, blocked: {"https://bad.example/"}}
      updater = {officialFeedTrust: cached}
      ut\assertEquals Updater.getOfficialBlockedFeeds(updater), {"https://bad.example/"}
      ut\assertIs updater.officialFeedTrust, cached

    -- require: dispatches on the task's run() result.

    -- run reports up-to-date for a module that wasn't (re)installed → load the existing module
    require_upToDateLoadsModule: (ut) ->
      loadedRef = {loaded: true}
      ut\stub(ModuleLoader, "loadModule")\returns loadedRef
      task = {updated: false, ref: {wrong: true}, record: {namespace: "l0.dep", name: "Dep"}, run: ((wait) => UpdateStatus.UpToDate)}
      record = {scriptType: Common.ScriptType.Module, name: "Dep", namespace: "l0.dep", virtual: false}
      ut\assertEquals (Updater.require makeRequireUpdater(task), record, 0), loadedRef

    -- a successful (re)install returns the task's freshly-loaded ref
    require_successReturnsRef: (ut) ->
      task = {updated: true, ref: {the: "ref"}, record: {namespace: "l0.dep", name: "Dep"}, run: ((wait) => UpdateStatus.Installed)}
      record = {scriptType: Common.ScriptType.Module, name: "Dep", namespace: "l0.dep", virtual: false}
      ut\assertEquals (Updater.require makeRequireUpdater(task), record, 0), task.ref

    -- an update error (negative code) is passed through to the caller
    require_errorPropagates: (ut) ->
      task = {updated: false, ref: {}, record: {namespace: "l0.dep", name: "Dep"}, run: ((wait) => return UpdateStatus.NoSuitablePackage, "boom")}
      record = {scriptType: Common.ScriptType.Module, name: "Dep", namespace: "l0.dep", virtual: false}
      ref, code, detail = Updater.require makeRequireUpdater(task), record, 0
      ut\assertNil ref
      ut\assertEquals code, UpdateStatus.NoSuitablePackage
      ut\assertEquals detail, "boom"

    -- scheduleUpdate: guards, then runs a due update.

    scheduleUpdate_disabledRejected: (ut) ->
      updater = makeScheduleUpdater {updaterEnabled: false}
      ut\assertEquals (Updater.scheduleUpdate updater, {name: "X", namespace: "l0.x"}), UpdateStatus.UpdaterDisabled

    scheduleUpdate_virtualRejected: (ut) ->
      updater = makeScheduleUpdater {updaterEnabled: true}
      ut\assertEquals (Updater.scheduleUpdate updater, {virtual: true, name: "X", namespace: "l0.x"}), UpdateStatus.Unmanaged

    scheduleUpdate_withinIntervalSkips: (ut) ->
      updater = makeScheduleUpdater {updaterEnabled: true, updateInterval: 100000}
      record = {virtual: false, name: "X", namespace: "l0.x", config: {c: {lastUpdateCheck: os.time!}}}
      ut\assertEquals (Updater.scheduleUpdate updater, record), UpdateStatus.UpToDate

    -- the entry point is in Aegisub's ?data automation dir (isUserPath false) → don't shadow it
    scheduleUpdate_protectedInstallRejected: (ut) ->
      updater = makeScheduleUpdater {updaterEnabled: true, updateInterval: 0}
      record = {
        virtual: false, name: "X", namespace: "l0.x", scriptType: Common.ScriptType.Module
        config: {c: {}, save: (=>)}
        getEntryPointPath: (=> "data/path", false)
      }
      code, path = Updater.scheduleUpdate updater, record
      ut\assertEquals code, UpdateStatus.ProtectedInstall
      ut\assertEquals path, "data/path"

    scheduleUpdate_runsTaskWhenDue: (ut) ->
      task = {run: (=> UpdateStatus.Installed)}
      updater = makeScheduleUpdater {updaterEnabled: true, updateInterval: 0, :task}
      record = {
        virtual: false, name: "X", namespace: "l0.x", scriptType: Common.ScriptType.Module
        config: {c: {}, save: (=>)}
        getEntryPointPath: (=> "user/path", true)
      }
      ut\assertEquals (Updater.scheduleUpdate updater, record), UpdateStatus.Installed

    -- acquireLock / releaseLock / renewLock: the lock state machine.

    acquireLock_returnsTrueWhenAlreadyHeld: (ut) ->
      updater = setmetatable {hasLock: true, config: {c: {updateWaitTimeout: 5}}}, __index: Updater.__base
      ut\assertTrue Updater.acquireLock updater, false

    acquireLock_acquiresAndSetsHasLock: (ut) ->
      fakeLock = {lock: ((timeout) => Lock.LockState.Held, 0), getActiveHolder: (=>)}
      updater = setmetatable {
        hasLock: false, config: {c: {updateWaitTimeout: 5}}, logger: {log: ->}
        tasks: {[Common.ScriptType.Module]: {}}
        __getLockHandle: (=> fakeLock)
      }, __index: Updater.__base
      ut\assertTrue Updater.acquireLock updater, false
      ut\assertTrue updater.hasLock

    acquireLock_failsWhenHeldByOther: (ut) ->
      fakeLock = {lock: ((timeout) => Lock.LockState.Unavailable, 0), getActiveHolder: (=> {holderName: "OtherScript"})}
      updater = setmetatable {
        hasLock: false, config: {c: {updateWaitTimeout: 5}}, logger: {log: ->}
        __getLockHandle: (=> fakeLock)
      }, __index: Updater.__base
      ok, owner = Updater.acquireLock updater, false
      ut\assertFalse ok
      ut\assertEquals owner, "OtherScript"

    releaseLock_releasesWhenHeld: (ut) ->
      released = {}
      updater = setmetatable {hasLock: true, lock: {release: (=> released.called = true)}}, __index: Updater.__base
      ut\assertTrue Updater.releaseLock updater
      ut\assertFalse updater.hasLock
      ut\assertTrue released.called

    releaseLock_noopWhenNotHeld: (ut) ->
      updater = setmetatable {hasLock: false}, __index: Updater.__base
      ut\assertFalse Updater.releaseLock updater

    renewLock_renewsWhenHeld: (ut) ->
      renewed = {}
      updater = setmetatable {hasLock: true, lock: {renew: (=> renewed.called = true)}}, __index: Updater.__base
      Updater.renewLock updater
      ut\assertTrue renewed.called

    -- addTask: version parsing and task caching.

    addTask_versionParseErrorReturns: (ut) ->
      updater = setmetatable {tasks: {}}, __index: Updater.__base
      record = {__class: DependencyControl, scriptType: Common.ScriptType.Module, namespace: "l0.x"}
      task, code, err = Updater.addTask updater, record, "not-a-version"
      ut\assertNil task
      ut\assertEquals code, UpdateStatus.InvalidVersion
      ut\assertNotNil err

    -- a record with a queued task updates that task in place rather than creating a new one
    addTask_updatesExistingTask: (ut) ->
      existing = {targetVersion: 0}
      record = {__class: DependencyControl, scriptType: Common.ScriptType.Module, namespace: "l0.x"}
      updater = setmetatable {
        tasks: {[Common.ScriptType.Module]: {[record.namespace]: existing}}
      }, __index: Updater.__base
      task = Updater.addTask updater, record, "2.0.0", {"feed://a"}, true
      ut\assertIs task, existing
      ut\assertEquals existing.targetVersion, SemanticVersioning\toNumber "2.0.0"
      ut\assertTrue existing.optional

    -- a record with no queued task gets a fresh UpdateTask, which is cached under its scriptType/namespace
    addTask_createsNewTask: (ut) ->
      record = {__class: DependencyControl, scriptType: Common.ScriptType.Module, namespace: "l0.new", validateNamespace: => true}
      updater = setmetatable {
        tasks: {[Common.ScriptType.Module]: {}}
        logger: {log: ->, trace: ->}
        config: {c: {dumpFeeds: false, updaterEnabled: true}}
      }, __index: Updater.__base
      task = Updater.addTask updater, record, "1.0.0"
      ut\assertNotNil task
      ut\assertIs task.__class, UpdateTask
      ut\assertIs updater.tasks[Common.ScriptType.Module][record.namespace], task

    -- the updaterEnabled / namespace guards (moved out of UpdateTask.new, where a constructor's return is
    -- discarded) now reject task creation through addTask
    addTask_disabledUpdaterRejects: (ut) ->
      record = {__class: DependencyControl, scriptType: Common.ScriptType.Module, namespace: "l0.new", validateNamespace: => true}
      updater = setmetatable {
        tasks: {[Common.ScriptType.Module]: {}}, config: {c: {updaterEnabled: false}}
      }, __index: Updater.__base
      task, code = Updater.addTask updater, record, "1.0.0"
      ut\assertNil task
      ut\assertEquals code, UpdateStatus.UpdaterDisabled

    addTask_invalidNamespaceRejects: (ut) ->
      record = {__class: DependencyControl, scriptType: Common.ScriptType.Module, namespace: "bad ns", validateNamespace: => false}
      updater = setmetatable {
        tasks: {[Common.ScriptType.Module]: {}}, config: {c: {updaterEnabled: true}}
      }, __index: Updater.__base
      task, code = Updater.addTask updater, record, "1.0.0"
      ut\assertNil task
      ut\assertEquals code, UpdateStatus.InvalidNamespace

    _order: {
      "getOfficialTrustedFeeds_usesCacheWhenPresent", "getOfficialBlockedFeeds_usesCacheWhenPresent"
      "require_upToDateLoadsModule", "require_successReturnsRef", "require_errorPropagates"
      "scheduleUpdate_disabledRejected", "scheduleUpdate_virtualRejected"
      "scheduleUpdate_withinIntervalSkips", "scheduleUpdate_protectedInstallRejected"
      "scheduleUpdate_runsTaskWhenDue"
      "acquireLock_returnsTrueWhenAlreadyHeld", "acquireLock_acquiresAndSetsHasLock"
      "acquireLock_failsWhenHeldByOther", "releaseLock_releasesWhenHeld", "releaseLock_noopWhenNotHeld"
      "renewLock_renewsWhenHeld"
      "addTask_versionParseErrorReturns", "addTask_updatesExistingTask", "addTask_createsNewTask"
      "addTask_disabledUpdaterRejects", "addTask_invalidNamespaceRejects"
    }
  }
