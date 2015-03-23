UpdateFeed = require "l0.DependencyControl.UpdateFeed"
fileOps = require "l0.DependencyControl.FileOps"
Logger = require "l0.DependencyControl.Logger"
DownloadManager = require "DM.DownloadManager"
PreciseTimer = require "PT.PreciseTimer"

class UpdaterBase
    @logger = Logger fileBaseName: @@__name
    @config = nil  -- set on creation of the Updater
    msgs = {
        updateError: {
            [0]: "Couldn't %s %s '%s' because of a paradox: module not found but updater says up-to-date (%s)"
            [1]: "Couldn't %s %s '%s' because the updater is disabled."
            [2]: "Skipping %s of %s '%s': namespace '%s' doesn't conform to rules."
            [3]: "Skipping %s of unmanaged %s '%s'."
            [4]: "No remaining feed available to %s %s '%s' from."
            [6]: "Couldn't retrieve data required to %s %s '%s'. Required version: %s."
            [5]: "Skipped %s of %s '%s': Another update initiated by %s is already running."
            [15]: "Couldn't %s %s '%s' because its requirements could not be satisfied:"
            [30]: "Couldn't %s %s '%s': failed to create temporary download directory %s"
            [35]: "Aborted %s of %s '%s' because the feed contained a missing or malformed SHA-1 hash for file %s."
            [50]: "Couldn't finish %s of %s '%s' because some files couldn't be moved to their target location:\n"
            [55]: "%s of %s '%s' succeeded, couldn't be located by the module loader."
            [56]: "%s of %s '%s' succeeded, but an error occured while loading the module:\n%s"
            [57]: "%s of %s '%s' succeeded, but it's missing a DependencyControl version record."
            [100]: "Error (%d) in component %s during %s of %s '%s':\n— %s"
        }
        updaterErrorComponent: {"DownloadManager (adding download)", "DownloadManager"}
    }

    getUpdaterErrorMsg: (code, name, ...) =>
        args = {...}
        if code <= -100
            -- Generic downstream error
            -- VarArgs: 1: isModule, 2: isFetch, 3: error msg
            return msgs.updateError[100]\format -code, msgs.updaterErrorComponent[math.floor(-code/100)],
                   args[2] and "fetch" or "update", args[1] and "module" or "macro", name, args[3]
        else
            -- Updater error:
            -- VarArgs: 1: isModule, 2: isFetch, 3: additional information
            return msgs.updateError[-code]\format args[2] and "fetch" or "update",
                                                  args[1] and "module" or "macro",
                                                  name, args[3]

class UpdateTask extends UpdaterBase
    DependencyControl = nil
    dlm = DownloadManager!
    msgs = {
        checkFeed: {
            downloadFailed: "Failed to download feed: %s"
            noData: "The feed doesn't have any update information for %s '%s'."
            badChannel: "The specified update channel '%s' wasn't present in the feed."
            invalidVersion: "The feed contains an invalid version record for %s '%s' (channel: %s): %s."
            unsupportedPlatform: "No download available for your platform '%s' (channel: %s)."
            noFiles: "No files available to download for your platform '%s' (channel: %s)."
        }
        run: {
            starting: "Starting %supdate of %s '%s' (v%s)... "
            fetching: "Trying to %sfetch missing %s '%s'..."
            feedCandidates: "Trying %d candidate feeds (%s mode)..."
            feedTrying: "Checking feed %d/%d (%s)..."
            upToDate: "%s '%s' is up-to-date (v%s)."
            noFeedAvailExt: "%s (installed: %s; available: %s)"
            noUpdate: "Feed has no new update."
        }

        performUpdate: {
            updateReqs: "Checking requirements..."
            updateReady: "Update ready. Using temporary directory '%s'."
            fileUnchanged: "Skipped unchanged file '%s'."
            fileAddDownload: "Added Download %s ==> '%s'."
            filesDownloading: "Downloading %d files..."
            movingFiles: "Downloads complete. Now moving files to Aegisub automation directory '%s'..."
            movedFile: "Moved '%s' ==> '%s'."
            moveFileFailed: "Failed to move '%s' ==> '%s': %s"
            updSuccess: "%s of %s '%s' (v%s) complete."
            reloadNotice: "Please rescan your autoload directory for the changes to take effect."
        }
        refreshRecord: {
            unsetVirtual: "Update initated by another macro already fetched %s '%s', switching to update mode."
            otherUpdate: "Update initated by another macro already updated %s '%s' to v%s."
        }
    }

    new: (@record, targetVersion = 0, @addFeeds, @exhaustive, @updater) =>
        DependencyControl or= require "l0.DependencyControl"
        assert @record.__class == DependencyControl, "First parameter must be a #{DependencyControl.__name} object."

        @triedFeeds = {}
        @status = nil
        @targetVersion = @record\getVersionNumber targetVersion

        return nil, -1 unless @@config.c.updaterEnabled
        return nil, -2 unless @record\validateNamespace!

    set: (targetVersion, @addFeeds, @exhaustive) =>
        @targetVersion = @record\getVersionNumber targetVersion
        return @

    checkFeed: (feedUrl) =>
        -- get feed contents
        feed = UpdateFeed feedUrl, false
        unless feed.data -- no cached data available, perform download
            success, err = feed\fetch!
            unless success
                return nil, msgs.checkFeed.downloadFailed\format err

        -- select our script and update channel
        updateRecord = feed\getScript @record.namespace, @record.moduleName, @record.config, false
        unless updateRecord
            return nil, msgs.checkFeed.noData\format @record.moduleName and "module" or "macro", @record.name

        success, currentChannel = updateRecord\setChannel!
        unless success
            return nil, msgs.checkFeed.badChannel\format currentChannel

        -- check if an update is available and satisfies our requirements
        res, version = @record\checkVersion updateRecord.version
        if res == nil
            return nil, msgs.checkFeed.invalidVersion\format @record.moduleName and "module" or "macro",
                                                             @record.name, currentChannel, tostring updateRecord.version
        elseif res or @targetVersion > version
            return false, nil, version

        -- check if our platform is supported/files are available to download
        res, platform = updateRecord\checkPlatform!
        unless res
            return nil, msgs.checkFeed.unsupportedPlatform\format platform, currentChannel
        if #updateRecord.files == 0
            return nil, msgs.checkFeed.noFiles\format platform, currentChannel

        return true, updateRecord, version


    run: (waitLock, exhaustive = @@config.c.tryAllFeeds or @@exhaustive) =>
        -- check if the script was already updated
        if @updated and not exhaustive and @record\checkVersion @targetVersion
            return 2

        -- build feed list
        userFeed, haveFeeds, feeds = @record.config.c.userFeed, {}, {}
        if userFeed and not @triedFeeds[userFeed]
            feeds[1] = userFeed
        else
            unless @triedFeeds[@record.feed] or haveFeeds[@record.feed]
                feeds[1] = @record.feed
            for feed in *@addFeeds
                unless @triedFeeds[feed] or haveFeeds[feed]
                    feeds[#feeds+1] = feed

            for feed in *@@config.c.extraFeeds
                unless @triedFeeds[feed] or haveFeeds[feed]
                    feeds[#feeds+1] = feed

        return -4 if #feeds == 0

        -- get a lock on the updater
        success, otherHost = @updater\getLock waitLock
        return -5, otherHost unless success

        -- check feeds for update until we find and update or run out of feeds to check
        -- normal mode:     check feeds until an update matching the required version is found
        -- exhaustive mode: check all feeds for updates and pick the highest version

        @@logger\log msgs.run.feedCandidates, #feeds, exhaustive and "exhaustive" or "normal"
        @@logger.indent += 1

        maxVer, updateRecord = 0
        for i, feed in ipairs feeds
            @@logger\log msgs.run.feedTrying, i, #feeds, feed

            res, rec, version = @checkFeed feed
            @triedFeeds[feed] = true
            if res == nil
                @@logger\log rec
            elseif version > maxVer
                maxVer = version
                if res
                    updateRecord = rec
                    break unless exhaustive
            else
                @@logger\trace msgs.run.noUpdate

        @@logger.indent -= 1

        local code, res
        wasVirtual = @record.virtual
        unless updateRecord
            -- for a script to be marked up-to-date it has to installed on the user's system
            -- and the version must at least be that returned by at least one feed
            if maxVer>0 and not @record.virtual and @targetVersion <= @record.version
                @@logger\log msgs.run.upToDate, @record.moduleName and "Module" or "Macro",
                                                @record.name, @record\getVersionString!
                return 0

            res = msgs.run.noFeedAvailExt\format @record\getVersionString(@targetVersion),
                                                 @record.virtual and "no" or @record\getVersionString!,
                                                 maxVer<1 and "none" or @record\getVersionString maxVer
            code = -6

        unless code
            code, res = @performUpdate updateRecord

        if code < 1
            @@logger\log @getUpdaterErrorMsg code, @record.name, @record.moduleName, wasVirtual, res
        return code, res


    performUpdate: (update) =>
        -- try to load required modules first to see if all dependencies are satisfied
        -- this may trigger more updates
        reqs = update.requiredModules
        if reqs and #reqs > 0
            @@logger\log msgs.performUpdate.updateReqs
            @@logger.indent += 1
            success, err = @record\loadModules reqs, {@record.feed}
            @@logger.indent -= 1
            unless success
                @@logger.indent += 1
                @@logger\log err
                @@logger.indent -= 1
                return -15, err

            -- since circular dependencies are possible, our task may have completed in the meantime
            -- so check again if we still need to update
            return 2 if  @updated and @record\checkVersion update.version


        -- download updated scripts to temp directory
        -- check hashes before download, only update changed files

        tmpDir = aegisub.decode_path "?temp/l0.#{DependencyControl.__name}_#{'%04X'\format math.random 0, 16^4-1}"
        res, err = fileOps.createDir tmpDir
        return -30, "#{tmpDir} (#{err})" unless res

        @@logger\log msgs.performUpdate.updateReady, tmpDir

        scriptSubDir = @record.moduleName and @record.moduleName\gsub("%.","/") or @record.namespace
        scriptDir = aegisub.decode_path "?user/automation/#{@record.moduleName and 'include' or 'autoload'}"
        baseName, tmpBaseName = "#{scriptDir}/#{scriptSubDir}", "#{tmpDir}/#{scriptSubDir}"

        dlm\clear!
        for file in *update.files
            continue if file.delete
            tmpName, name, prettyName = tmpBaseName..file.name, baseName..file.name, scriptSubDir..file.name

            unless type(file.sha1)=="string" and #file.sha1 == 40 and tonumber(file.sha1, 16)
                return -35, "#{prettyName} (#{tostring(file.sha1)\lower!})"

            if dlm\checkFileSHA1 name, file.sha1
                @@logger\log msgs.performUpdate.fileUnchanged, prettyName
                continue

            dl, err = dlm\addDownload file.url, tmpName, file.sha1
            return -140, err unless dl
            dl.targetFile = name
            @@logger\log msgs.performUpdate.fileAddDownload, file.url, prettyName

        dlm\waitForFinish (progress) ->
            @@logger\progress progress, msgs.performUpdate.filesDownloading, dlm.downloadCount
            return true
        @@logger\progress!

        if dlm.failedCount>0
            err = @@logger\format ["#{dl.url}: #{dl.error}" for dl in *dlm.failedDownloads], 1
            return -245, err


        -- move files to their destination directory and clean up

        @@logger\log msgs.performUpdate.movingFiles, scriptDir
        moveErrors = {}
        @@logger.indent += 1
        for dl in *dlm.downloads
            res, err = fileOps.moveFile dl.outfile, dl.targetFile
            -- don't immediately error out if moving of a single file failed
            -- try to move as many files as possible and let the user handle the rest
            if res
                @@logger\log msgs.performUpdate.movedFile, dl.outfile, dl.targetFile
            else
                @@logger\log msgs.performUpdate.moveFileFailed, dl.outfile, dl.targetFile, err
                moveErrors[#moveErrors+1] = err
        @@logger.indent -= 1

        if #moveErrors>0
            return -50, @@logger\format moveErrors, 1
        else lfs.rmdir tmpDir
        os.remove baseName..file.name for file in *update.files when file.delete

        -- Nuke old module refs and reload
        oldVer, wasVirtual = @record.version, @record.virtual

        if @record.moduleName
            ref = @record\loadModule @record, false, true
            unless ref
                if ref._error
                    return -56, @@logger\format ref._error, 1
                else return -55

            return -57 unless ref.version.__class == DependencyControl
            -- get a fresh version record
            @ref, @record = ref, ref.version
            -- Update complete, refresh module information/configuration
            -- For automation scripts/macros this will be done on reload
            @record\writeConfig!
        else
            @record.version, @record.virtual, @record.unmanaged = @record\getVersionNumber update.version


        @updated = true
        @@logger\log msgs.performUpdate.updSuccess, wasVirtual and "Download" or "Update",
                                                    @record.moduleName and "module" or "macro",
                                                    @record.name, @record\getVersionString!

        -- Diplay changelog
        @@logger\log update\getChangelog @record, (@record.getVersionNumber oldVer) + 1
        @@logger\log msgs.performUpdate.reloadNotice

        -- TODO: check handling of private module copies (need extra return value?)
        return 1, @record\getVersionString!


    refreshRecord: =>
        with @record
            wasVirtual, oldVersion = .virtual, .version
            \loadConfig true
            if wasVirtual and not .virtual or .version > oldVersion
                @updated = true
                @ref = \loadModule @record, false, true if .moduleName
                if wasVirtual
                    @@logger\log msgs.refreshRecord.unsetVirtual, .moduleName and "module" or "macro", .name
                else
                    @@logger\log msgs.refreshRecord.otherUpdate, .moduleName and "module" or "macro", .name, \getVersionString!

class Updater extends UpdaterBase
    msgs = {
        getLock: {
            orphaned: "Ignoring orphaned in-progress update started by %s."
            waitFinished: "Waited %d seconds."
            abortWait: "Timeout reached after %d seconds."
            waiting: "Waiting for update intiated by %s to finish..."
        }
        require: {
            macroPassed: "%s is not a module."
            upToDate: "Tried to require an update for up-to-date module '%s'."
        }
        scheduleUpdate: {
            updaterDisabled: "Skipping update check for %s (Updater disabled)."
            runningUpdate: "Running scheduled update for %s '%s'..."
        }
    }
    new: (@host = script_namespace, globalConfig, logger) =>
        @tasks = macros: {}, modules: {}
        super.config = globalConfig
        super.logger = logger if logger

    addTask: (record, targetVersion, addFeeds = {}, exhaustive) =>
        task = @tasks[record.type][record.namespace]
        if task
            return task\set targetVersion, addFeeds, exhaustive
        else
            task = UpdateTask record, targetVersion, addFeeds, exhaustive, @
            @tasks[record.type][record.namespace] = task
            return task, err

    require: (record, ...) =>
        @@logger\assert record.moduleName, msgs.require, record.name or record.namespace
        @@logger\log "%s module '%s'...", record.virtual and "Fetching required" or "Updating outdated", record.name
        task, code = @addTask record, ...
        code, res = task\run true if task

        if code >= 1
            return task.ref
        elseif code == 0
            -- usually we know in advance if a module is up to date so there's no reason to block other updaters
            -- but we'll make sure to handle this case gracefully, anyway
            @@logger\debug msgs.require.upToDate, task.record.name or task.record.moduleName
            return task.record.loadModule task.record.moduleName

        -- pass on update errors
        return nil, code, res

    scheduleUpdate: (record) =>
        unless @@config.c.updaterEnabled
            @@logger\trace msgs.scheduleUpdate.updaterDisabled, record.name or record.namespace
            return -1

        -- no regular updates for non-existing or unmanaged modules
        if record.virtual or record.unmanaged
            return -3

        -- the update interval has not yet been passed since the last update check
        if record.config.c.lastUpdateCheck and (record.config.c.lastUpdateCheck + @@config.c.updateInterval > os.time!)
            return false

        record.config.c.lastUpdateCheck = os.time!
        record.config\write!

        task = @addTask record -- no need to check for errors, because we've already accounted for those case
        @@logger\trace msgs.scheduleUpdate.runningUpdate, record.moduleName and "module" or "macro", record.name
        return task\run!


    getLock: (doWait, waitTimeout = @@config.c.updateWaitTimeout) =>
        return true if @hasLock

        @@config\load!
        running = @@config.c.updaterRunning
        if running and running.host != @host
            otherHost = running.host

            if running.time + @@config.c.updateOrphanTimeout < os.time!
                @@logger\log msgs.getLock.orphaned, running.host
            elseif doWait
                @@logger\log msgs.getLock.waiting, running.host
                timeout = waitTimeout
                while running and timeout > 0
                    PreciseTimer.sleep 1000
                    timeout -= 1
                    @@config\load!
                    running = @@config.c.updaterRunning
                @@logger\log timeout <= 0 and msgs.getLock.abortWait or msgs.getLock.waitFinished,
                           waitTimeout - timeout

            else return false, running.host

        -- register the running update in the config file to prevent collisions
        -- with other scripts trying to update the same modules

        @@config.c.updaterRunning = host: @host, time: os.time!
        @@config\write!
        @hasLock = true

        -- reload important module version information from configuration
        -- because another updater instance might have updated them in the meantime
        task.refreshRecord! for task in *@tasks.modules

        return true

    releaseLock: =>
        return false unless @hasLock
        @hasLock = false
        @@config.c.updaterRunning = false
        @@config\write!