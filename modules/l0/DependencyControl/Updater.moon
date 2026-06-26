constants = require "l0.DependencyControl.Constants"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
Logger =     require "l0.DependencyControl.Logger"
Common =     require "l0.DependencyControl.Common"
Lock =       require "l0.DependencyControl.Lock"
ModuleLoader = require "l0.DependencyControl.ModuleLoader"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
UpdateTask = require "l0.DependencyControl.UpdateTask"
DependencyControl = nil

UPDATER_LOCK_NAMESPACE = "#{constants.DEPCTRL_NAMESPACE}.Updater"
UPDATER_LOCK_RESOURCE_RUN  = "run"

-- the reason an update runs (see UpdateTask), used here for the addTask/require defaults
UpdateReason = UpdateTask.UpdateReason

-- Lazily loads and caches DependencyControl's own feed trust lists onto the given updater. Best-effort:
-- if the feed can't be loaded, only DepCtrl's own feed URL is treated as trusted and nothing as blocked.
loadOfficialFeedTrust = () =>
    return if @officialFeedTrust
    trusted, blocked = {[constants.DEPCTRL_FEED_URL]: true}, {}
    feed = UpdateFeed constants.DEPCTRL_FEED_URL, false, nil, nil, @logger
    if feed\ensureLoaded!
        Common.makeSet feed\getKnownFeeds!, trusted
        blocked = feed.data.blockedFeeds or {}
    @officialFeedTrust = {:trusted, :blocked}

---Coordinates background update checks and update task lifecycle.
---@class Updater
class Updater
    @logger = Logger fileBaseName: "DependencyControl.Updater"
    msgs = {
        acquireLock: {
            waiting: "Waiting for update initiated by %s to finish..."
        }
        require: {
            macroPassed: "%s is not a module."
            upToDate: "Tried to require an update for up-to-date module '%s'."
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

    ---Returns the feed URLs DependencyControl officially trusts (its own feed URL plus the feeds it
    ---advertises).
    ---@return table<string,boolean> trustedFeeds Officially trusted feed URLs.
    getOfficialTrustedFeeds: =>
        loadOfficialFeedTrust @
        @officialFeedTrust.trusted

    ---Returns the feed URL prefixes DependencyControl officially block-lists.
    ---@return string[] blockedFeeds Officially block-listed feed URL prefixes.
    getOfficialBlockedFeeds: =>
        loadOfficialFeedTrust @
        @officialFeedTrust.blocked

    ---Creates or updates a queued update task for a record.
    ---@param record Record|table A record, or a plain table to construct one from.
    ---@param targetVersion? number|string Minimum version to install.
    ---@param addFeeds? string[]
    ---@param optional? boolean Treat this as an optional dependency.
    ---@param channel? string Update channel to use.
    ---@param reason? UpdateReason Why the task runs (gates interactive prompts). Defaults to `AutoUpdate`, the least interactive.
    ---@return UpdateTask? task
    ---@return number? code
    ---@return string? detail
    addTask: (record, targetVersion, addFeeds = {}, optional, channel, reason = UpdateReason.AutoUpdate) =>
        DependencyControl or= require "l0.DependencyControl"
        if record.__class != DependencyControl
            depRec = {saveRecordToConfig: false, readGlobalScriptVars: false}
            depRec[k] = v for k, v in pairs record
            record = DependencyControl depRec

        targetVersionNumber, err = SemanticVersioning\toNumber targetVersion
        if (err) then return nil, -8, err

        task = @tasks[record.scriptType][record.namespace]
        return if task then with task
            .targetVersion = targetVersionNumber
            .addFeeds, .optional, .channel, .reason = addFeeds, optional, channel, reason

        task, code = UpdateTask record, targetVersionNumber, addFeeds, optional, channel, reason, @
        @tasks[record.scriptType][record.namespace] = task
        return task, code

    ---Ensures a module dependency is installed/updated and loadable.
    ---@param record Record
    ---@param targetVersion? number|string Minimum version to install.
    ---@param addFeeds? string[]
    ---@param optional? boolean Treat this as an optional dependency.
    ---@param channel? string Update channel to use.
    ---@param reason? UpdateReason Defaults to `DependencyResolution` — the reason this method exists; a caller (e.g. an installed provider) may pass another to carry its own reason through.
    ---@return any ref The loaded module reference, or nil on error.
    ---@return number? code
    ---@return string? detail
    require: (record, targetVersion, addFeeds, optional, channel, reason = UpdateReason.DependencyResolution) =>
        @logger\assert record.scriptType == Common.ScriptType.Module, msgs.require, record.name or record.namespace
        @logger\log "%s module '%s'...", record.virtual and "Installing required" or "Updating outdated", record.name
        task, code, res = @addTask record, targetVersion, addFeeds, optional, channel, reason
        code, res = task\run true if task

        if code == 0 and not task.updated
            -- usually we know in advance if a module is up to date so there's no reason to block other updaters
            -- but we'll make sure to handle this case gracefully, anyway
            @logger\debug msgs.require.upToDate, task.record.name or task.record.namespace
            return ModuleLoader.loadModule task.record, task.record.namespace
        elseif code >= 0
            return task.ref
        else -- pass on update errors
            return nil, code, res

    ---Performs a periodic non-blocking update check for a managed record.
    ---@param record Record
    ---@return number|boolean status A status code, or the task's run result.
    scheduleUpdate: (record) =>
        unless @config.c.updaterEnabled
            @logger\trace msgs.scheduleUpdate.updaterDisabled, record.name or record.namespace
            return -1

        -- no regular updates for non-existing or unmanaged modules
        if record.virtual or record.recordType == Common.RecordType.Unmanaged
            return -3

        -- the update interval has not yet been passed since the last update check
        if record.config.c.lastUpdateCheck and (record.config.c.lastUpdateCheck + @config.c.updateInterval > os.time!)
            return 0

        record.config.c.lastUpdateCheck = os.time!
        record.config\write!

        -- don't shadow scripts installed to the ?data automation dir with a ?user copy
        entryPath, isUserPath = record\getEntryPointPath!
        if isUserPath == false
            @logger\trace msgs.scheduleUpdate.protectedInstall, Common.terms.scriptType.singular[record.scriptType],
                          record.name or record.namespace, entryPath
            return -9, entryPath

        task = @addTask record -- no need to check for errors, because we've already accounted for those case
        @logger\trace msgs.scheduleUpdate.runningUpdate, Common.terms.scriptType.singular[record.scriptType], record.name
        return task\run!


    -- Lazily builds this updater's handle to the shared, cross-process updater lock.
    _getLockHandle: =>
        @lock or= Lock {
            namespace: UPDATER_LOCK_NAMESPACE, resource: UPDATER_LOCK_RESOURCE_RUN
            scope: Lock.Scope.Global, holderName: @host, logger: @logger
            expiresAfter: @config.c.updateOrphanTimeout
        }
        return @lock

    ---Acquires the global updater lock shared across scripts and processes.
    ---@param doWait boolean Wait for a concurrent update to finish instead of bailing out.
    ---@param waitTimeout? number Seconds to wait when doWait is set.
    ---@return boolean acquired
    ---@return string? lockOwner The holder script's name when acquisition failed.
    acquireLock: (doWait, waitTimeout = @config.c.updateWaitTimeout) =>
        return true if @hasLock
        lock = @_getLockHandle!

        if doWait
            holder = lock\getActiveHolder!
            @logger\log msgs.acquireLock.waiting, holder.holderName if holder and holder.holderName != @host

        state, timePassed = lock\lock doWait and waitTimeout * 1000 or 0
        unless state == Lock.LockState.Held
            holder = lock\getActiveHolder!
            return false, holder and holder.holderName

        @hasLock = true
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
Updater.PromptThreshold = UpdateTask.PromptThreshold
Updater.UpdateReason = UpdateTask.UpdateReason
Updater.SourceChoiceStickiness = UpdateTask.SourceChoiceStickiness
Updater.SourceFeedKind = UpdateTask.SourceFeedKind
Updater.FeedTrustDecision = UpdateTask.FeedTrustDecision
Updater.getUpdaterErrorMsg = UpdateTask.getUpdaterErrorMsg
Updater.UpdateTask = UpdateTask
return Updater
