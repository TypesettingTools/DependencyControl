constants = require "l0.DependencyControl.Constants"
FeedLoader = require "l0.DependencyControl.FeedLoader"
FeedTrust = require "l0.DependencyControl.FeedTrust"
Logger = require "l0.DependencyControl.Logger"
Common = require "l0.DependencyControl.Common"
Lock = require "l0.DependencyControl.Lock"
ModuleLoader = require "l0.DependencyControl.ModuleLoader"
SemanticVersion = require "l0.DependencyControl.SemanticVersion"
UpdateTask = require "l0.DependencyControl.UpdateTask"
DependencyControl = nil

UPDATER_LOCK_NAMESPACE = "#{constants.DEPCTRL_NAMESPACE}.Updater"
UPDATER_LOCK_RESOURCE_RUN = "run"

UpdateReason = UpdateTask.UpdateReason
UpdateStatus = UpdateTask.UpdateStatus

---Coordinates background update checks and update task lifecycle.
---@class Updater
---@field feedTrust FeedTrust The feed-trust model (official + user trust merge, trust queries, mutations).
---@field feedLoader FeedLoader The shared feed loader (owns the feed cache; builds every `UpdateFeed`).
class Updater
  @logger = Logger fileBaseName: "#{constants.DEPCTRL_SHORT_NAME}.Updater"

  -- Defaults for the config's `updates` section settings this class owns, applied when the key is unset.
  ---@type UpdateContextCeiling
  @defaultMode = UpdateTask.ContextCeiling.AutoUpdate
  @defaultCheckInterval = 302400
  @defaultWaitTimeout = 60
  @defaultOrphanTimeout = 50

  msgs = {
    acquireLock: {
      waiting: "Waiting for update initiated by %s to finish..."
    }
    require: {
      macroPassed: "%s is not a module."
      upToDate: "Tried to require an update for up-to-date module '%s'."
      notFoundDespiteInstalled: "its files were likely moved or deleted after installation, or installed for a different Aegisub setup — reinstalling the module should restore it"
    }
    scheduleUpdate: {
      updaterDisabled: "Skipping update check for %s (Updater disabled)."
      protectedInstall: "Skipping update check for %s '%s': its entry point (%s) is in Aegisub's data automation directory, managed outside of #{constants.DEPCTRL_NAME}."
      runningUpdate: "Running scheduled update for %s '%s'..."
    }
  }

  ---Creates an updater coordinator for one host script context.
  ---@param host? string Host script namespace (default script_namespace).
  ---@param config ConfigView The global DependencyControl config view.
  ---@param logger? Logger
  new: (@host = script_namespace, @config, @logger = @@logger) =>
    @tasks = {scriptType, {} for scriptType in *Common.ScriptType.values}
    -- one shared feed loader owns the on-disk feed cache and every UpdateFeed construction; feed trust
    -- is likewise a singleton so its cache and trust/block invalidations are visible across all consumers
    @@feedLoader or= FeedLoader @config, @@logger
    @feedLoader = @@feedLoader
    @@feedTrust or= FeedTrust @config, @@logger, @@feedLoader
    @feedTrust = @@feedTrust

  ---@private
  ---@param reason UpdateReason The context asking to run updates.
  ---@return boolean enabled True when the configured update mode (`updates.mode`, or its default when unset) allows that context.
  __isEnabledFor: (reason) =>
    UpdateTask.isWithinContextCeiling reason, @config.c.updates.mode or @@defaultMode

  ---Creates or updates a queued update task for a record.
  ---@param record PackageRecord|table A record, or a plain table to construct one from.
  ---@param targetVersion? number|string Minimum version to install.
  ---@param addFeeds? string[]
  ---@param optional? boolean Treat this as an optional dependency.
  ---@param channel? string Update channel to use.
  ---@param reason? UpdateReason Why the task runs; the configured update mode must allow it, and it gates interactive prompts. Defaults to `AutoUpdate`, the least interactive.
  ---@return UpdateTask? task
  ---@return UpdateStatus? code
  ---@return string? detail
  addTask: (record, targetVersion, addFeeds = {}, optional, channel, reason = UpdateReason.AutoUpdate) =>
    DependencyControl or= require "l0.DependencyControl"
    if record.__class != DependencyControl
      depRec = {saveRecordToConfig: false, readGlobalScriptVars: false}
      depRec[k] = v for k, v in pairs record
      record = DependencyControl depRec

    targetVersionNumber, err = SemanticVersion\toPacked targetVersion
    if (err) then return nil, UpdateStatus.InvalidVersion, err

    task = @tasks[record.scriptType][record.namespace]
    return if task then with task
      .targetVersion = targetVersionNumber
      .addFeeds, .optional, .channel, .reason = addFeeds, optional, channel, reason

    -- UpdateTask.new can't reject construction (a constructor's return value is discarded), so guard here
    return nil, UpdateStatus.UpdaterDisabled unless @__isEnabledFor reason
    return nil, UpdateStatus.InvalidNamespace unless record\validateNamespace!

    task = UpdateTask record, targetVersionNumber, addFeeds, optional, channel, reason, @
    @tasks[record.scriptType][record.namespace] = task
    return task

  ---Ensures a module dependency is installed/updated and loadable.
  ---@param record PackageRecord
  ---@param targetVersion? number|string Minimum version to install.
  ---@param addFeeds? string[]
  ---@param optional? boolean Treat this as an optional dependency.
  ---@param channel? string Update channel to use.
  ---@param reason? UpdateReason Defaults to `DependencyResolution` — the reason this method exists; a caller (e.g. an installed provider) may pass another to carry its own reason through.
  ---@return any ref The loaded module reference, or nil when the module couldn't be provided.
  ---@return UpdateStatus? code Outcome of the update run; always present when the ref is nil, with `SkippedOptional` marking a skipped optional dependency rather than a failure.
  ---@return string? detail Error detail for a failing code, or the paradox reason when an up-to-date module then can't be loaded.
  require: (record, targetVersion, addFeeds, optional, channel, reason = UpdateReason.DependencyResolution) =>
    @logger\assert record.scriptType == Common.ScriptType.Module, msgs.require.macroPassed, record.name or record.namespace
    @logger\log "%s module '%s'...", record.virtual and "Installing required" or "Updating outdated", record.name
    task, code, res = @addTask record, targetVersion, addFeeds, optional, channel, reason
    code, res = task\run true if task

    if code == UpdateStatus.UpToDate and not task.updated
      -- usually we know in advance if a module is up to date so there's no reason to block other updaters
      -- but we'll make sure to handle this case gracefully, anyway
      @logger\debug msgs.require.upToDate, task.record.name or task.record.namespace
      ref = ModuleLoader.loadModule task.record, task.record
      return ref if ref
      return nil, code, task.record._error or msgs.require.notFoundDespiteInstalled
    elseif code >= 0 -- any other non-negative outcome (Installed / AlreadyUpdated / SkippedOptional)
      return task.ref, code, res
    else -- pass on update errors
      return nil, code, res

  ---Performs a periodic non-blocking update check for a managed record.
  ---@param record PackageRecord
  ---@return UpdateStatus status The status code (the task's run result when an update actually runs).
  ---@return string? entryPath The resolved entry-point path, returned only with a ProtectedInstall status.
  scheduleUpdate: (record) =>
    unless @__isEnabledFor UpdateReason.AutoUpdate
      @logger\trace msgs.scheduleUpdate.updaterDisabled, record.name or record.namespace
      return UpdateStatus.UpdaterDisabled

    -- no regular updates for non-existing or unmanaged modules
    if record.virtual or record.recordType == Common.RecordType.Unmanaged
      return UpdateStatus.Unmanaged

    -- the update interval has not yet been passed since the last update check
    if record.config.c.lastUpdateCheck and (record.config.c.lastUpdateCheck + (@config.c.updates.checkInterval or @@defaultCheckInterval) > os.time!)
      return UpdateStatus.UpToDate

    record.config.c.lastUpdateCheck = os.time!
    record.config\save!

    -- don't shadow scripts installed to the ?data automation dir with a ?user copy
    entryPath, isUserPath = record\getEntryPointPath!
    if isUserPath == false
      @logger\trace msgs.scheduleUpdate.protectedInstall, Common.terms.scriptType.singular[record.scriptType],
        record.name or record.namespace, entryPath
      return UpdateStatus.ProtectedInstall, entryPath

    task = @addTask record -- no need to check for errors, because we've already accounted for those case
    @logger\trace msgs.scheduleUpdate.runningUpdate, Common.terms.scriptType.singular[record.scriptType], record.name
    return task\run!


  ---Acquires the global updater lock shared across scripts and processes.
  ---@param doWait boolean Wait for a concurrent update to finish instead of bailing out.
  ---@param waitTimeout? number Seconds to wait when doWait is set.
  ---@return boolean acquired
  ---@return string? lockOwner The holder script's name when acquisition failed.
  acquireLock: (doWait, waitTimeout = @config.c.updates.waitTimeout or @@defaultWaitTimeout) =>
    return true if @hasLock
    -- lazily build this updater's handle to the shared, cross-process lock on first acquire
    @lock or= Lock {
      namespace: UPDATER_LOCK_NAMESPACE, resource: UPDATER_LOCK_RESOURCE_RUN
      scope: Lock.Scope.Global, holderName: @host, logger: @logger
      expiresAfter: @config.c.updates.orphanTimeout or @@defaultOrphanTimeout
    }
    lock = @lock

    if doWait
      holder = lock\getActiveHolder!
      @logger\log msgs.acquireLock.waiting, holder.holderName if holder and holder.holderName != @host

    state, timePassed = lock\lock doWait and waitTimeout * 1000 or 0
    unless state == Lock.LockState.Held
      holder = lock\getActiveHolder!
      return false, holder and holder.holderName

    @hasLock = true
    -- a freshly acquired lock starts a new update pass: expire the feed cache so each feed is refetched
    -- once this pass (its snapshot is kept as an offline fallback), then reused by the pass's other tasks
    @feedLoader.cache\expireAll!
    -- if we actually had to wait, another updater may have updated modules in the meantime
    if timePassed > 0
      task\refreshRecord! for _,task in pairs @tasks[Common.ScriptType.Module]

    return true

  ---Renews the updater lock's lease if we currently hold it.
  renewLock: =>
    @lock\renew! if @hasLock and @lock

  ---Releases the global updater lock.
  ---@return boolean released
  releaseLock: =>
    return false unless @hasLock
    @hasLock = false
    @lock\release! if @lock
    return true

  ---Reports whether an update is currently running in any script or process.
  ---@return boolean running
  ---@return string? holderName The name of the script holding the updater lock.
  @isRunning = =>
    holder = Lock({
      namespace: UPDATER_LOCK_NAMESPACE, resource: UPDATER_LOCK_RESOURCE_RUN, scope: Lock.Scope.Global
    })\getActiveHolder!
    return holder != nil, holder and holder.holderName

-- Re-expose UpdateTask, its version-related enums, and its error-message decoder on the public API,
-- so callers holding only an Updater reference (e.g. ModuleLoader, the Toolbox) can reach them.
Updater.UpdateStatus = UpdateTask.UpdateStatus
Updater.ContextCeiling = UpdateTask.ContextCeiling
Updater.UpdateReason = UpdateTask.UpdateReason
Updater.SourceChoiceStickiness = UpdateTask.SourceChoiceStickiness
Updater.SourceFeedKind = UpdateTask.SourceFeedKind
Updater.FeedTrustDecision = UpdateTask.FeedTrustDecision
Updater.getUpdaterErrorMsg = UpdateTask.getUpdaterErrorMsg
Updater.UpdateTask = UpdateTask
return Updater
