lfs = require "lfs"
DownloadManager = require "DM.DownloadManager"
PreciseTimer = require "PT.PreciseTimer"

UpdateFeed = require "l0.DependencyControl.UpdateFeed"
fileOps =    require "l0.DependencyControl.FileOps"
Logger =     require "l0.DependencyControl.Logger"
Common =     require "l0.DependencyControl.Common"
ModuleLoader = require "l0.DependencyControl.ModuleLoader"
DependencyControl = nil

class UpdaterBase extends Common
    @logger = Logger fileBaseName: "DependencyControl.Updater"
    msgs = {
        updateError: {
            [0]: "Couldn't %s %s '%s' because of a paradox: module not found but updater says up-to-date (%s)"
            [1]: "Couldn't %s %s '%s' because the updater is disabled."
            [2]: "Skipping %s of %s '%s': namespace '%s' doesn't conform to rules."
            [3]: "Skipping %s of unmanaged %s '%s'."
            [4]: "No remaining feed available to %s %s '%s' from."
            [6]: "The %s of %s '%s' failed because no suitable package could be found %s."
            [5]: "Skipped %s of %s '%s': Another update initiated by %s is already running."
            [7]: "Skipped %s of %s '%s': An internet connection is currently not available."
            [10]: "Skipped %s of %s '%s': the update task is already running."
            [15]: "Couldn't %s %s '%s' because its requirements could not be satisfied:"
            [30]: "Couldn't %s %s '%s': failed to create temporary download directory %s"
            [35]: "Aborted %s of %s '%s' because the feed contained a missing or malformed SHA-1 hash for file %s."
            [50]: "Couldn't finish %s of %s '%s' because some files couldn't be moved to their target location:\n"
            [55]: "%s of %s '%s' succeeded, couldn't be located by the module loader."
            [56]: "%s of %s '%s' succeeded, but an error occured while loading the module:\n%s"
            [57]: "%s of %s '%s' succeeded, but it's missing a version record."
            [58]: "%s of unmanaged %s '%s' succeeded, but an error occured while creating a DependencyControl record: %s"
            [100]: "Error (%d) in component %s during %s of %s '%s':\n— %s"
        }
        updaterErrorComponent: {"DownloadManager (adding download)", "DownloadManager"}
    }

    getUpdaterErrorMsg: (code, name, scriptType, isInstall, detailMsg) =>
        if code <= -100
            -- Generic downstream error
            return msgs.updateError[100]\format -code, msgs.updaterErrorComponent[math.floor(-code/100)],
                   @@terms.isInstall[isInstall], @@terms.scriptType.singular[scriptType], name, detailMsg
        else
            -- Updater error:
            return msgs.updateError[-code]\format @@terms.isInstall[isInstall],
                                                  @@terms.scriptType.singular[scriptType],
                                                  name, detailMsg

class UpdateTask extends UpdaterBase
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
            starting: "Starting %s of %s '%s'... "
            fetching: "Trying to %sfetch missing %s '%s'..."
            feedCandidates: "Trying %d candidate feeds (%s mode)..."
            feedTrying: "Checking feed %d/%d (%s)..."
            upToDate: "The %s '%s' is up-to-date (v%s)."
            alreadyUpdated: "%s v%s has already been installed."
            noFeedAvailExt: "(required: %s; installed: %s; available: %s)"
            noUpdate: "Feed has no new update."
            skippedOptional: "Skipped %s of optional dependency '%s': %s"
            optionalNoFeed: "No feed available to download module from."
            optionalNoUpdate: "No suitable download could be found %s."
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
            unknownType: "Skipping file '%s': unknown type '%s'."
        }
        refreshRecord: {
            unsetVirtual: "Update initated by another macro already fetched %s '%s', switching to update mode."
            otherUpdate: "Update initated by another macro already updated %s '%s' to v%s."
        }
    }

    new: (@record, targetVersion = 0, @addFeeds, @exhaustive, @channel, @optional, @updater) =>
        DependencyControl or= require "l0.DependencyControl"
        assert @record.__class == DependencyControl, "First parameter must be a #{DependencyControl.__name} object."

        @logger = @updater.logger
        @triedFeeds = {}
        @status = nil
        @targetVersion = DependencyControl\parseVersion targetVersion

        -- set UpdateFeed settings
        @feedConfig = {
            downloadPath: aegisub.decode_path "?user/feedDump/"
            dumpExpanded: true
        } if @updater.config.c.dumpFeeds

        return nil, -1 unless @updater.config.c.updaterEnabled -- TODO: check if this even works
        return nil, -2 unless @record\validateNamespace!

    set: (targetVersion, @addFeeds, @exhaustive, @channel, @optional) =>
        @targetVersion = DependencyControl\parseVersion targetVersion
        return @

    checkFeed: (feedUrl) =>
        -- get feed contents
        feed = UpdateFeed feedUrl, false, nil, @feedConfig, @logger
        unless feed.data -- no cached data available, perform download
            success, err = feed\fetch!
            unless success
                return nil, msgs.checkFeed.downloadFailed\format err

        -- select our script and update channel
        updateRecord = feed\getScript @record.namespace, @record.scriptType, @record.config, false
        unless updateRecord
            return nil, msgs.checkFeed.noData\format @@terms.scriptType.singular[@record.scriptType], @record.name

        success, currentChannel = updateRecord\setChannel @channel
        unless success
            return nil, msgs.checkFeed.badChannel\format currentChannel

        -- check if an update is available and satisfies our requirements
        res, version = @record\checkVersion updateRecord.version
        if res == nil
            return nil, msgs.checkFeed.invalidVersion\format @@terms.scriptType.singular[@record.scriptType],
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


    run: (waitLock, exhaustive = @updater.config.c.tryAllFeeds or @@exhaustive) =>
        logUpdateError = (code, extErr, virtual = @virtual) ->
            if code < 0
                @logger\log @getUpdaterErrorMsg code, @record.name, @record.scriptType, virtual, extErr
            return code, extErr

        with @record do @logger\log msgs.run.starting, @@terms.isInstall[.virtual],
                                                       @@terms.scriptType.singular[.scriptType], .name

        -- don't perform update of a script when another one is already running for the same script
        return logUpdateError -10 if @running

        -- check if the script was already updated
        if @updated and not exhaustive and @record\checkVersion @targetVersion
            @logger\log msgs.run.alreadyUpdated, @record.name, DependencyControl\getVersionString @record.version
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
                    haveFeeds[feed] = true

            for feed in *@updater.config.c.extraFeeds
                unless @triedFeeds[feed] or haveFeeds[feed]
                    feeds[#feeds+1] = feed
                    haveFeeds[feed] = true

        if #feeds == 0
            if @optional
                @logger\log msgs.run.skippedOptional, @record.name,
                            @@terms.isInstall[@record.virtual], msgs.run.optionalNoFeed
                return 3

            return logUpdateError -4

        -- check internet connection
        return logUpdateError -7 unless dlm\isInternetConnected!

        -- get a lock on the updater
        success, otherHost = @updater\getLock waitLock
        return logUpdateError -5, otherHost unless success

        -- check feeds for update until we find and update or run out of feeds to check
        -- normal mode:     check feeds until an update matching the required version is found
        -- exhaustive mode: check all feeds for updates and pick the highest version

        @logger\log msgs.run.feedCandidates, #feeds, exhaustive and "exhaustive" or "normal"
        @logger.indent += 1

        maxVer, updateRecord = 0
        for i, feed in ipairs feeds
            @logger\log msgs.run.feedTrying, i, #feeds, feed

            res, rec, version = @checkFeed feed
            @triedFeeds[feed] = true
            if res == nil
                @logger\log rec
            elseif version > maxVer
                maxVer = version
                if res
                    updateRecord = rec
                    break unless exhaustive
                else @logger\trace msgs.run.noUpdate
            else
                @logger\trace msgs.run.noUpdate

        @logger.indent -= 1

        local code, res
        wasVirtual = @record.virtual
        unless updateRecord
            -- for a script to be marked up-to-date it has to installed on the user's system
            -- and the version must at least be that returned by at least one feed
            if maxVer>0 and not @record.virtual and @targetVersion <= @record.version
                @logger\log msgs.run.upToDate, @@terms.scriptType.singular[@record.scriptType],
                                               @record.name, DependencyControl\getVersionString @record.version
                return 0

            res = msgs.run.noFeedAvailExt\format @targetVersion == 0 and "any" or DependencyControl\getVersionString(@targetVersion),
                                                 @record.virtual and "no" or DependencyControl\getVersionString(@record.version),
                                                 maxVer<1 and "none" or DependencyControl\getVersionString maxVer

            if @optional
                @logger\log msgs.run.skippedOptional, @record.name, @@terms.isInstall[@record.virtual],
                                                      msgs.run.optionalNoUpdate\format res
                return 3

            return logUpdateError -6, res

        code, res = @performUpdate updateRecord
        return logUpdateError code, res, wasVirtual

    performUpdate: (update) =>
        finish = (...) ->
            @running = false
            if @record.virtual or @record.recordType == @@RecordType.Unmanaged
                ModuleLoader.removeDummyRef @record
            return ...

        -- don't perform update of a script when another one is already running for the same script
        return finish -10 if @running
        @running = true

        -- set a dummy ref (which hasn't yet been set for virtual and unmanaged modules)
        -- and record version to allow resolving circular dependencies
        if @record.virtual or @record.recordType == @@RecordType.Unmanaged
            ModuleLoader.createDummyRef @record
            @record\setVersion update.version

        -- try to load required modules first to see if all dependencies are satisfied
        -- this may trigger more updates
        reqs = update.requiredModules
        if reqs and #reqs > 0
            @logger\log msgs.performUpdate.updateReqs
            @logger.indent += 1
            success, err = ModuleLoader.loadModules @record, reqs, {@record.feed}
            @logger.indent -= 1
            unless success
                @logger.indent += 1
                @logger\log err
                @logger.indent -= 1
                return finish -15, err

            -- since circular dependencies are possible, our task may have completed in the meantime
            -- so check again if we still need to update
            return finish 2 if @updated and @record\checkVersion update.version


        -- download updated scripts to temp directory
        -- check hashes before download, only update changed files

        tmpDir = aegisub.decode_path "?temp/l0.#{DependencyControl.__name}_#{'%04X'\format math.random 0, 16^4-1}"
        res, dir = fileOps.mkdir tmpDir
        return finish -30, "#{tmpDir} (#{dir})" if res == nil

        @logger\log msgs.performUpdate.updateReady, tmpDir

        scriptSubDir = @record.namespace
        scriptSubDir = scriptSubDir\gsub "%.","/" if @record.scriptType == @@ScriptType.Module

        dlm\clear!
        for file in *update.files
            file.type or= "script"

            baseName = scriptSubDir .. file.name
            tmpName, prettyName = "#{tmpDir}/#{file.type}/#{baseName}", baseName
            switch file.type
                when "script"
                    file.fullName = "#{@record.automationDir}/#{baseName}"
                when "test"
                    file.fullName = "#{@record.testDir}/#{baseName}"
                    prettyName ..= " (Unit Test)"
                else
                    file.unknown = true
                    @logger\log msgs.performUpdate.unknownType, file.name, file.type
                    continue
            continue if file.delete

            unless type(file.sha1)=="string" and #file.sha1 == 40 and tonumber(file.sha1, 16)
                return finish -35, "#{prettyName} (#{tostring(file.sha1)\lower!})"

            if dlm\checkFileSHA1 file.fullName, file.sha1
                @logger\trace msgs.performUpdate.fileUnchanged, prettyName
                continue

            dl, err = dlm\addDownload file.url, tmpName, file.sha1
            return finish -140, err unless dl
            dl.targetFile = file.fullName
            @logger\trace msgs.performUpdate.fileAddDownload, file.url, prettyName

        dlm\waitForFinish (progress) ->
            @logger\progress progress, msgs.performUpdate.filesDownloading, #dlm.downloads
            return true
        @logger\progress!

        if #dlm.failedDownloads>0
            err = @logger\format ["#{dl.url}: #{dl.error}" for dl in *dlm.failedDownloads], 1
            return finish -245, err


        -- move files to their destination directory and clean up

        @logger\log msgs.performUpdate.movingFiles, @record.automationDir
        moveErrors = {}
        @logger.indent += 1
        for dl in *dlm.downloads
            res, err = fileOps.move dl.outfile, dl.targetFile, true
            -- don't immediately error out if moving of a single file failed
            -- try to move as many files as possible and let the user handle the rest
            if res
                @logger\trace msgs.performUpdate.movedFile, dl.outfile, dl.targetFile
            else
                @logger\log msgs.performUpdate.moveFileFailed, dl.outfile, dl.targetFile, err
                moveErrors[#moveErrors+1] = err
        @logger.indent -= 1

        if #moveErrors>0
            return finish -50, @logger\format moveErrors, 1
        else lfs.rmdir tmpDir
        os.remove file.fullName for file in *update.files when file.delete and not file.unknown

        -- Nuke old module refs and reload
        oldVer, wasVirtual = @record.version, @record.virtual

        -- Update complete, refresh module information/configuration
        if @record.scriptType == @@ScriptType.Module
            ref = ModuleLoader.loadModule @record, @record, false, true
            unless ref
                if @record._error
                    return finish -56, @logger\format @record._error, 1
                else return finish -55

            -- get a fresh version record
            if type(ref.version) == "table" and ref.version.__class.__name == DependencyControl.__name
                @record = ref.version
            else
                -- look for any compatible non-DepCtrl version records and create an unmanaged record
                return finish -57 unless ref.version
                success, rec = pcall DependencyControl, { moduleName: @record.moduleName, version: ref.version,
                                                          recordType: @@RecordType.Unmanaged, name: @record.name }
                return finish -58, rec unless success
                @record = rec
            @ref = ref

        else with @record
            .name, .version, .virtual = @record.name, DependencyControl\parseVersion update.version
            @record\writeConfig!

        @updated = true
        @logger\log msgs.performUpdate.updSuccess, @@terms.capitalize(@@terms.isInstall[wasVirtual]),
                                                   @@terms.scriptType.singular[@record.scriptType],
                                                   @record.name, DependencyControl\getVersionString @record.version

        -- Diplay changelog
        @logger\log update\getChangelog @record, (DependencyControl\parseVersion oldVer) + 1
        @logger\log msgs.performUpdate.reloadNotice

        -- TODO: check handling of private module copies (need extra return value?)
        return finish 1, DependencyControl\getVersionString @record.version


    refreshRecord: =>
        with @record
            wasVirtual, oldVersion = .virtual, .version
            \loadConfig true
            if wasVirtual and not .virtual or .version > oldVersion
                @updated = true
                @ref = ModuleLoader.loadModule @record, @record, false, true if .scriptType == @@ScriptType.Module
                if wasVirtual
                    @logger\log msgs.refreshRecord.unsetVirtual, @@terms.scriptType.singular[.scriptType], .name
                else
                    @logger\log msgs.refreshRecord.otherUpdate, @@terms.scriptType.singular[.scriptType], .name,
                                DependencyControl\getVersionString @record.version

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
    new: (@host = script_namespace, @config, @logger = @@logger) =>
        @tasks = {scriptType, {} for _, scriptType in pairs @@ScriptType when "number" == type scriptType}

    addTask: (record, targetVersion, addFeeds = {}, exhaustive, channel, optional) =>
        DependencyControl or= require "l0.DependencyControl"
        if record.__class != DependencyControl
            depRec = {saveRecordToConfig: false, readGlobalScriptVars: false}
            depRec[k] = v for k, v in pairs record
            record = DependencyControl depRec

        task = @tasks[record.scriptType][record.namespace]
        if task
            return task\set targetVersion, addFeeds, exhaustive, channel, optional
        else
            task, err = UpdateTask record, targetVersion, addFeeds, exhaustive, channel, optional, @
            @tasks[record.scriptType][record.namespace] = task
            return task, err

    require: (record, ...) =>
        @logger\assert record.scriptType == @@ScriptType.Module, msgs.require, record.name or record.namespace
        @logger\log "%s module '%s'...", record.virtual and "Installing required" or "Updating outdated", record.name
        task, code = @addTask record, ...
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

    scheduleUpdate: (record) =>
        unless @config.c.updaterEnabled
            @logger\trace msgs.scheduleUpdate.updaterDisabled, record.name or record.namespace
            return -1

        -- no regular updates for non-existing or unmanaged modules
        if record.virtual or record.recordType == @@RecordType.Unmanaged
            return -3

        -- the update interval has not yet been passed since the last update check
        if record.config.c.lastUpdateCheck and (record.config.c.lastUpdateCheck + @config.c.updateInterval > os.time!)
            return false

        record.config.c.lastUpdateCheck = os.time!
        record.config\write!

        task = @addTask record -- no need to check for errors, because we've already accounted for those case
        @logger\trace msgs.scheduleUpdate.runningUpdate, @@terms.scriptType.singular[record.scriptType], record.name
        return task\run!


    getLock: (doWait, waitTimeout = @config.c.updateWaitTimeout) =>
        return true if @hasLock

        @config\load!
        running, didWait = @config.c.updaterRunning

        if running and running.host != @host
            if running.time + @config.c.updateOrphanTimeout < os.time!
                @logger\log msgs.getLock.orphaned, running.host
            elseif doWait
                @logger\log msgs.getLock.waiting, running.host
                timeout, didWait = waitTimeout, true
                while running and timeout > 0
                    PreciseTimer.sleep 1000
                    timeout -= 1
                    @config\load!
                    running = @config.c.updaterRunning
                @logger\log timeout <= 0 and msgs.getLock.abortWait or msgs.getLock.waitFinished,
                           waitTimeout - timeout

            else return false, running.host

        -- register the running update in the config file to prevent collisions
        -- with other scripts trying to update the same modules
        -- TODO: store this flag in the db

        @config.c.updaterRunning = host: @host, time: os.time!
        @config\write!
        @hasLock = true

        -- reload important module version information from configuration
        -- because another updater instance might have updated them in the meantime
        if didWait
            task\refreshRecord! for _,task in pairs @tasks[@@ScriptType.Module]

        return true

    releaseLock: =>
        return false unless @hasLock
        @hasLock = false
        @config.c.updaterRunning = false
        @config\write!