lfs = require "lfs"
DownloadManager = require "DM.DownloadManager"
PreciseTimer = require "PT.PreciseTimer"

UpdateFeed =       require "l0.DependencyControl.UpdateFeed"
fileOps =          require "l0.DependencyControl.FileOps"
Logger =           require "l0.DependencyControl.Logger"
Common =           require "l0.DependencyControl.Common"
ModuleLoader =     require "l0.DependencyControl.ModuleLoader"
Package =          require "l0.DependencyControl.Package"
DependencyRecord = require "l0.DependencyControl.DependencyRecord"

import moon from require "moonscript.util"

DependencyControl = nil

class UpdaterBase
    @logger = Logger fileBaseName: "DependencyControl.Updater"
    msgs = {
        updateError: {
            [0]: "Couldn't %s %s '%s' because of a paradox: module not found but updater says up-to-date (%s)"
            [1]: "Couldn't %s %s '%s' because the updater is disabled."
            [2]: "Skipping %s of %s '%s': namespace '%s' doesn't conform to rules."
            [3]: "Skipping %s of unmanaged or not installed %s '%s'."
            [4]: "No remaining feed available to %s %s '%s' from."
            [6]: "The %s of %s '%s' failed because no suitable package could be found %s."
            [5]: "Skipped %s of %s '%s': Another update initiated by %s is already running."
            [7]: "Skipped %s of %s '%s': An internet connection is currently not available."
            [8]: "Failed to load install information required to %s %s '%s': %s"
            [9]: "Couldn't create update task: no valid DependencyControl package was supplied."
            [10]: "Skipped %s of %s '%s': the update task is already running."
            [15]: "Couldn't %s %s '%s' because its requirements could not be satisfied:"
            [30]: "Couldn't %s %s '%s': failed to create temporary download directory %s"
            [35]: "Aborted %s of %s '%s' because the feed contained a missing or malformed SHA-1 hash for file %s."
            [50]: "Couldn't finish %s of %s '%s' because some files couldn't be moved to their target location:\n"
            [55]: "%s of %s '%s' succeeded, couldn't be located by the module loader."
            [56]: "%s of %s '%s' succeeded, but an error occured while loading the module:\n%s"
            [57]: "%s of %s '%s' succeeded, but it's missing a version record."
            [58]: "%s of unmanaged %s '%s' succeeded, but an error occured while creating a DependencyControl record: %s"
            [59]: "%s of %s '%s' succeeded, but an error occured while refreshing package information from database: %s"
            [60]: "%s of %s '%s' succeeded, but an error occured while updating package information: %s"
            [100]: "%s Error (%d) during %s of %s '%s':\n— %s"
        }
        updaterErrorComponent: {
            [1]: "DownloadManager (adding download)",
            [2]: "DownloadManager"
            [9]: "Generic"
        }
    }

    @decodeError = (code, name, scriptType, isInstall, detailMsg) =>
        if code <= -100
            -- Generic downstream error
            return msgs.updateError[100]\format msgs.updaterErrorComponent[math.floor(-code/100)], -code,
                   Common.terms.isInstall[isInstall], Common.terms.scriptType.singular[scriptType], name, detailMsg
        else
            -- Updater error:
            return msgs.updateError[-code]\format Common.terms.isInstall[isInstall],
                                                  Common.terms.scriptType.singular[scriptType],
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
        new: {
            badPackage: "Can't create update task: invalid DependencyControl package."
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
            packageAlreadyRegistered: "Package '%s' has already been registered by another process during installation."
        }
        importUpdatedRegistryState: {
            alreadyInstalled: "An update initated by another script already installed %s '%s' v%s, switching to update mode."
            alreadyUpdated: "An update initated by another script already updated %s '%s' to v%s."
        }
    }

    new: (@package, targetVersion = 0, @addFeeds, @exhaustive, @channel, @optional, @updater) =>
        @logger or= @updater.logger
        @logger\assert Package == moon.type(@package), msgs.new.badPackage

        @triedFeeds = {}
        @status = nil
        @set targetVersion, @addFeeds, @exhaustive, @channel, @optional

        -- set UpdateFeed settings
        @feedConfig = {
            downloadPath: aegisub.decode_path "?user/feedDump/"
            dumpExpanded: true
        } if @updater.config.c.dumpFeeds

        @package\sync!

        isInstall = @package.installState == Package.InstallState.Absent
        @logger\assert @updater.config.c.updaterEnabled,
                       @@decodeError -1, @package.name or @package.namespace, @package.scriptType, isInstall

        @logger\assert Common.validateNamespace @package.namespace,
                       @@decodeError -2, @package.name or @package.namespace, @package.scriptType, isInstall

    set: (targetVersion, @addFeeds, @exhaustive, @channel, @optional) =>
        @channel or= @package.config.c.activeChannel

        @targetVersion = DependencyRecord\parseVersion targetVersion
        return @

    checkFeed: (feedUrl) =>
        -- get feed contents
        feed = UpdateFeed feedUrl, false, nil, @feedConfig, @logger
        unless feed.data -- no cached data available, perform download
            success, err = feed\fetch!
            unless success
                return nil, msgs.checkFeed.downloadFailed\format err

        -- select our script and update channel
        updateRecord = feed\getScript @package.namespace, @package.scriptType, false
        unless updateRecord
            return nil, msgs.checkFeed.noData\format Common.terms.scriptType.singular[@package.scriptType], @package.name

        success, currentChannel = updateRecord\setChannel @channel
        unless success
            return nil, msgs.checkFeed.badChannel\format currentChannel

        -- check if an update is available and satisfies our requirements
        res, version = @package.dependencyRecord\checkVersion updateRecord.version
        if res == nil
            return nil, msgs.checkFeed.invalidVersion\format Common.terms.scriptType.singular[@package.scriptType],
                                                             @package.name, currentChannel, tostring updateRecord.version
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
        @package\sync!
        isInstall = @package.installState == Package.InstallState.Absent

        logUpdateError = (code, extErr) ->
            if code < 0
                @logger\log @@decodeError code, @package.name, @package.scriptType,
                            isInstall, extErr
            return code, extErr


        with @package do @logger\log msgs.run.starting, Common.terms.isInstall[isInstall],
                                                        Common.terms.scriptType.singular[.scriptType], .name

        -- don't perform update of a script when another one is already running for the same script
        return logUpdateError -10 if @running

        -- check if the script was already updated
        if @updated and not exhaustive and @package.dependencyRecord\checkVersion @targetVersion
            @logger\log msgs.run.alreadyUpdated, @package.name, DependencyRecord\getVersionString @package.version
            return 2

        -- build feed list
        haveFeeds, feeds = {}, {}

        -- if the user specified an override feed, only ever consider that one
        overrideFeed = not isInstall and @package.config.c.overrideFeed
        if overrideFeed and not @triedFeeds[overrideFeed]
            feeds[1] = overrideFeed

        else
            unless @triedFeeds[@package.feed] or haveFeeds[@package.feed]
                feeds[1] = @package.feed
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
                @logger\log msgs.run.skippedOptional, @package.name,
                            Common.terms.isInstall[isInstall], msgs.run.optionalNoFeed
                return 3

            return logUpdateError -4

        -- check internet connection
        return logUpdateError -7 unless dlm\isInternetConnected!

        -- get a lock on the updater
        didWait, otherHost = @updater\getLock waitLock
        return logUpdateError -5, otherHost if didWait == nil

        -- reload important module version information from configuration
        -- because another updater instance might have updated them in the meantime
        if didWait
            -- TODO: make method of updater
            task\importUpdatedRegistryState! for _,task in pairs @updater.tasks[DependencyRecord.ScriptType.Module]

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
        unless updateRecord
            -- for a script to be marked up-to-date it has to installed on the user's system
            -- and the version must at least be that returned by at least one feed
            if maxVer>0 and not isInstall and @targetVersion <= @package.version
                @logger\log msgs.run.upToDate, Common.terms.scriptType.singular[@package.scriptType],
                                               @package.name, DependencyRecord\getVersionString @package.version
                return 0

            res = msgs.run.noFeedAvailExt\format @targetVersion == 0 and "any" or DependencyRecord\getVersionString(@targetVersion),
                                                 isInstall and "no" or DependencyRecord\getVersionString(@package.version),
                                                 maxVer<1 and "none" or DependencyRecord\getVersionString maxVer

            if @optional
                @logger\log msgs.run.skippedOptional, @package.name, Common.terms.isInstall[isInstall],
                                                      msgs.run.optionalNoUpdate\format res
                return 3

            return logUpdateError -6, res

        code, res = @performUpdate updateRecord
        return logUpdateError code, res, isInstall

    performUpdate: (update) =>
        DependencyControl or= require "l0.DependencyControl"
        @package\sync!
        isInstall = @package.installState == Package.InstallState.Absent

        finish = (...) ->
            @running = false
            if isInstall or @package.recordType == DependencyRecord.RecordType.Unmanaged
                ModuleLoader.removeDummyRef @package.dependencyRecord
            return ...

        -- don't perform update of a script when another one is already running for the same script
        return finish -10 if @running
        @running = true

        -- set a dummy ref for not-yet-installed and unmanaged modules
        -- and record version to allow resolving circular dependencies
        if isInstall or @package.recordType == DependencyRecord.RecordType.Unmanaged
            ModuleLoader.createDummyRef @package.dependencyRecord
            @package.depencyRecord\setVersion update.version

        -- try to load required modules first to see if all dependencies are satisfied
        -- this may trigger more updates
        reqs = update.requiredModules
        if reqs and #reqs > 0
            @logger\log msgs.performUpdate.updateReqs
            @logger.indent += 1
            success, err = ModuleLoader.loadModules @package.dependencyRecord, @package.dependencyRecord, reqs, {@package.feed}
            @logger.indent -= 1
            unless success
                @logger.indent += 1
                @logger\log err
                @logger.indent -= 1
                return finish -15, err

            -- since circular dependencies are possible, our task may have completed in the meantime
            -- so check again if we still need to update
            return finish 2 if @updated and @package.dependencyRecord\checkVersion update.version


        -- download updated scripts to temp directory
        -- check hashes before download, only update changed files

        tmpDir = aegisub.decode_path "?temp/l0.#{DependencyControl.__name}_#{'%04X'\format math.random 0, 16^4-1}"
        res, dir = fileOps.mkdir tmpDir
        return finish -30, "#{tmpDir} (#{dir})" if res == nil

        @logger\log msgs.performUpdate.updateReady, tmpDir

        scriptSubDir = @package.namespace
        scriptSubDir = scriptSubDir\gsub "%.","/" if @package.scriptType == DependencyRecord.ScriptType.Module

        dlm\clear!
        for file in *update.files
            file.type or= "script"

            baseName = scriptSubDir .. file.name
            tmpName, prettyName = "#{tmpDir}/#{file.type}/#{baseName}", baseName
            switch file.type
                when "script"
                    file.fullName = "#{@package.dependencyRecord.automationDir}/#{baseName}"
                when "test"
                    file.fullName = "#{@package.dependencyRecord.testDir}/#{baseName}"
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

        @logger\log msgs.performUpdate.movingFiles, @package.dependencyRecord.automationDir
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
        oldVer = @package.version


        -- Update complete, refresh module information/configuration

        -- modules can be (re)loaded instantly
        -- no matter if we're installing or updating
        if @package.scriptType == DependencyRecord.ScriptType.Module
            ref = ModuleLoader.loadModule @package.dependencyRecord, @package.dependencyRecord, false, true
            unless ref
                if @package.dependencyRecord._error
                    return finish -56, @logger\format @package.dependencyRecord._error, 1
                else return finish -55

            -- get a fresh version record
            if type(ref.version) == "table" and ref.version.__class.__name == DependencyControl.__name
                @package = ref.version.package
            else
                -- look for any compatible non-DepCtrl version records and create an unmanaged record
                return finish -57 unless ref.version
                success, rec = pcall DependencyRecord, { moduleName: @package.namespace, version: ref.version,
                                                        recordType: DependencyRecord.RecordType.Unmanaged, name: @package.name }
                return finish -58, rec unless success
                @package = rec.package
            @ref = ref

        else
            -- another process may have installed this script in the meantime
            if isInstall
                res, msg = @package\sync Package.SyncMode.ReadOnly
                if @package.InstallState != Package.InstallState.Absent
                    @logger\warn msgs.performUpdate.packageAlreadyRegistered, @package.namespace 
                return finish -59, msg unless res

            -- updated automation scripts have their install record updated
            -- with version information and metadata provided by the update feed
            @package\apply update
            @package.version = DependencyRecord\parseVersion update.version

            -- newly installed macros will only be available after the next script reload
            -- so we don't treat them as fully installed until they register themselves
            res, msg = @package\sync Package.SyncMode.PreferWrite, 
                                     @package.InstallState == Package.InstallState.Absent and Package.InstallState.Downloaded or nil
            return finish -60, msg unless res


        @updated = true
        @logger\log msgs.performUpdate.updSuccess, Common.terms.capitalize(Common.terms.isInstall[isInstall]),
                                                   Common.terms.scriptType.singular[@package.scriptType],
                                                   @package.name, DependencyRecord\getVersionString @package.version

        -- Display changelog
        @logger\log update\getChangelog 1 + DependencyRecord\parseVersion oldVer
        @logger\log msgs.performUpdate.reloadNotice

        -- TODO: check handling of private module copies (need extra return value?)
        return finish 1, DependencyRecord\getVersionString @package.version


    importUpdatedRegistryState: =>
        @updated, oldVersion, msg = false, @record.version
        if @record.__class == DummyRecord
            installState = InstalledPackage\getInstallState @record.namespace
            if installState >= InstalledPackage.InstallState.Downloaded
                @record.package = InstalledPackage @record
                @updated, msg = true, msgs.importUpdatedRegistryState.alreadyInstalled

        elseif @record.package\sync InstalledPackage.SyncMode.PreferRead and @record.version > oldVersion
            @updated = true, msgs.importUpdatedRegistryState.alreadyUpdated

        if @updated
            @logger\log msg, Common.terms.scriptType.singular[@record.scriptType],
                        @record.name, DependencyRecord\getVersionString @record.version

            if @record.scriptType == DependencyRecord.ScriptType.Module
                @ref = ModuleLoader.loadModule @record, @record, false, true


class Updater extends UpdaterBase
    msgs = {
        getLock: {
            orphaned: "Ignoring orphaned in-progress update started by %s."
            waitFinished: "Waited %d seconds."
            abortWait: "Timeout reached after %d seconds."
            waiting: "Waiting for update intiated by %s to finish..."
        }
        require: {
            notAModule: "Can only require a module, but supplied record for '%s' indicates type %s."
            upToDate: "Tried to require an update for up-to-date module '%s'."
            installingRequired: "Installing required module '%s'..."
            updatingOutdated: "Updating outdated moudle '%s'..."
        }
    }
    new: (@host = script_namespace, @config, @logger = @@logger) =>
        @tasks = {scriptType, {} for _, scriptType in pairs DependencyRecord.ScriptType when "number" == type scriptType}

    addTask: (package, targetVersion, addFeeds = {}, exhaustive, channel, optional) =>
        -- test for install
        isInstall = true

        if Package != moon.type package
            -- TODO: fix error message for non-objects
            return nil, -9, @@decodeError -9, package.name or package.namespace, package.scriptType, isInstall


        task = @tasks[package.scriptType][package.namespace]
        if task
            return task\set targetVersion, addFeeds, exhaustive, channel, optional

        unless @config.c.updaterEnabled
            return nil, -1, @@decodeError -1, package.name or package.namespace, package.scriptType, isInstall

        unless Common.validateNamespace package.namespace
            return nil, -2, @@decodeError -2, package.name or package.namespace, package.scriptType, isInstall

        success, task = pcall UpdateTask, package,
                              targetVersion, addFeeds, exhaustive, channel, optional, @
        unless success
            return nil, -999, @@decodeError -999,  package.name or package.namespace, package.scriptType, isInstall, task 

        @tasks[package.scriptType][package.namespace] = task
        return task

    require: (record, ...) =>
        package = if Package == moon.type record
            record
        else
            return nil, -9 unless DependencyRecord\isDependencyRecord record
            Package record, @logger
        package\sync!

        @logger\assert package.scriptType == DependencyRecord.ScriptType.Module,
                       msgs.require.notAModule, package.name or package.namespace,
                       Common.terms.scriptType.singular[package.scriptType]

        @logger\log msgs.require[package.installState == Package.InstallState.Absent and "installingRequired" or "updatingOutdated"],
                    package.name
        task, code = @addTask package, ...
        code, res = task\run true if task

        return if code == 0 and not task.updated
            -- usually we know in advance if a module is up to date so there's no reason to block other updaters
            -- but we'll make sure to handle this case gracefully, anyway
            @logger\debug msgs.require.upToDate, task.package.name or task.package.namespace
            ModuleLoader.loadModule task.package.dependencyRecord, task.package.namespace
        elseif code >= 0
            task.ref
        else nil, code, res -- pass on update errors

    scheduleUpdate: (record) =>
        package = if Package == moon.type record
            record
        else
            return nil, -9 unless DependencyRecord\isDependencyRecord record
            Package record, @logger
        package\sync!

        -- no regular updates for not (yet) installed or unmanaged modules
        if package.recordType == DependencyRecord.RecordType.Unmanaged or package.installState < Package.InstallState.Installed
            return -3

        return package\update!

    getLock: (doWait, waitTimeout = @config.c.updateWaitTimeout) =>
        return true if @hasLock

        @config\load!
        running, didWait = @config.c.updaterRunning, false

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

            else return nil, running.host

        -- register the running update in the config file to prevent collisions
        -- with other scripts trying to update the same modules
        -- TODO: store this flag in the db

        @config.c.updaterRunning = host: @host, time: os.time!
        @config\save!
        @hasLock = true

        return didWait

    releaseLock: =>
        return false unless @hasLock
        @hasLock = false
        @config.c.updaterRunning = false
        @config\save!