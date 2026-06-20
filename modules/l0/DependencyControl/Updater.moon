lfs = require "lfs"
constants = require "l0.DependencyControl.Constants"
Downloader = require "l0.DependencyControl.Downloader"
Timer = require "l0.DependencyControl.Timer"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
fileOps =    require "l0.DependencyControl.FileOps"
Logger =     require "l0.DependencyControl.Logger"
Common =     require "l0.DependencyControl.Common"
Enum =       require "l0.DependencyControl.Enum"
Lock =       require "l0.DependencyControl.Lock"
ModuleLoader = require "l0.DependencyControl.ModuleLoader"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
DependencyControl = nil

UPDATER_LOCK_NAMESPACE = "#{constants.DEPCTRL_NAMESPACE}.Updater"
UPDATER_LOCK_RESOURCE_RUN  = "run"

-- How preferred a candidate package source is, lowest value first.
---@alias UpdaterTrustBand
---| 1 # DeclaredDirect: the declared/own feed, trusted, offering the module by name
---| 2 # TrustedDirect: another trusted feed, offering the module by name
---| 3 # TrustedProvider: a trusted feed, offering a module that provides it
---| 4 # UntrustedDirect: an untrusted feed, offering the module by name
---| 5 # UntrustedProvider: an untrusted feed, offering a provider
TrustBand = Enum "UpdaterTrustBand", {
    DeclaredDirect:    1
    TrustedDirect:     2
    TrustedProvider:   3
    UntrustedDirect:   4
    UntrustedProvider: 5
}

---Shared updater error decoding and base behavior.
---@class UpdaterBase: DependencyControlCommon
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
            [8]: "Couldn't %s %s '%s' because the requested version is invalid: %s"
            [9]: "Skipped %s of %s '%s' because its entry point (%s) is in Aegisub's data automation directory. If it's managed by a system package manager, please update it through that instead."
            [10]: "Skipped %s of %s '%s': the update task is already running."
            [15]: "Couldn't %s %s '%s' because its requirements could not be satisfied:"
            [16]: "Couldn't %s %s '%s' because a suitable package was only found in an untrusted feed (%s). Add it to your trusted feeds to proceed."
            [30]: "Couldn't %s %s '%s': failed to create temporary download directory %s"
            [33]: "Aborted %s of %s '%s' because it attempted to deploy a file (%s) outside of its namespaced path."
            [35]: "Aborted %s of %s '%s' because the feed contained a missing or malformed SHA-1 hash for file %s."
            [50]: "Couldn't finish %s of %s '%s' because some files couldn't be moved to their target location:\n"
            [55]: "%s of %s '%s' succeeded, couldn't be located by the module loader."
            [56]: "%s of %s '%s' succeeded, but an error occurred while loading the module:\n%s"
            [57]: "%s of %s '%s' succeeded, but it's missing a version record."
            [58]: "%s of unmanaged %s '%s' succeeded, but an error occurred while creating a DependencyControl record: %s",
            [100]: "Error (%d) in component %s during %s of %s '%s':\n— %s"
        }
        updaterErrorComponent: {"DownloadManager (adding download)", "DownloadManager"}
    }

    ---Converts updater status/error codes into user-facing error messages.
    ---@param code number
    ---@param name string
    ---@param scriptType integer A Common.ScriptType value.
    ---@param isInstall boolean
    ---@param detailMsg? string
    ---@return string
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

---Mutable execution state for one install/update operation.
---@class UpdateTask: UpdaterBase
class UpdateTask extends UpdaterBase
    downloader = Downloader!
    msgs = {
        checkFeed: {
            downloadFailed: "Failed to download feed: %s"
            badChannel: "The specified update channel '%s' wasn't present in the feed."
            invalidVersion: "The feed contains an invalid version record for %s '%s' (channel: %s): %s."
        }
        run: {
            starting: "Starting %s of %s '%s'... "
            fetching: "Trying to %sfetch missing %s '%s'..."
            feedChecking: "Checking feed %s..."
            upToDate: "The %s '%s' is up-to-date (v%s)."
            alreadyUpdated: "%s v%s has already been installed."
            noFeedAvailExt: "(required: %s; installed: %s; available: %s)"
            skippedOptional: "Skipped %s of optional dependency '%s': %s"
            optionalNoUpdate: "No suitable download could be found %s."
            optionalUntrusted: "a suitable package was only found in an untrusted feed (%s)."
            providerAmbiguous: "Multiple modules provide '%s'; selected '%s' (candidates: %s)."
            providerResolved: "Satisfying required module '%s' with provider %s '%s' (v%s)."
            providerInstallFailed: "Found a provider for '%s' (%s) but it couldn't be installed: %s"
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
            unsetVirtual: "Update initiated by another macro already fetched %s '%s', switching to update mode."
            otherUpdate: "Update initiated by another macro already updated %s '%s' to v%s."
        }
    }

    ---Creates an update task for one record.
    ---@param record Record
    ---@param targetVersionNumber? number Minimum version to install (default 0, i.e. any).
    ---@param addFeeds? string[]
    ---@param optional? boolean Treat this as an optional dependency.
    ---@param channel? string Update channel to use.
    ---@param updater Updater
    new: (@record, targetVersionNumber = 0, @addFeeds, @optional, @channel, @updater) =>
        DependencyControl or= require "l0.DependencyControl"
        assert @record.__class == DependencyControl, "First parameter must be a #{DependencyControl.__name} object."
        assert type(targetVersionNumber) == "number", "Second parameter must be a semantic version number in integer format."

        @logger = @updater.logger
        @triedFeeds = {}
        @status = nil
        @targetVersion = targetVersionNumber

        -- set UpdateFeed settings
        @feedConfig = {
            downloadPath: aegisub.decode_path "?user/feedDump/"
            dumpExpanded: true
        } if @updater.config.c.dumpFeeds

        return nil, -1 unless @updater.config.c.updaterEnabled -- TODO: check if this even works
        return nil, -2 unless @record\validateNamespace!

    ---Loads a candidate feed, downloading it if necessary.
    ---@param feedUrl string
    ---@return UpdateFeed? feed The loaded feed, or nil on download failure.
    ---@return string? err Error message on failure.
    loadFeed: (feedUrl) =>
        feed = UpdateFeed feedUrl, false, nil, @feedConfig, @logger
        unless feed.data -- no cached data available, perform download
            success, err = feed\fetch!
            return nil, msgs.checkFeed.downloadFailed\format err unless success
        return feed

    ---Looks up this task's module in an already-loaded feed (matched by namespace), returning its
    ---update record on the task's channel along with the parsed release version.
    ---@param feed UpdateFeed A feed loaded via loadFeed.
    ---@return ScriptUpdateRecord|nil record The module's update record, or nil if absent/unusable.
    ---@return string? err Error message worth reporting (nil when the module simply isn't in this feed).
    ---@return number? version The candidate's parsed version number.
    checkFeed: (feed) =>
        updateRecord, err = feed\getScript @record.namespace, @record.scriptType, @record.config, false
        return nil, err unless updateRecord   -- err is nil for "not in this feed", set for a real error

        success, currentChannel = updateRecord\setChannel @channel
        return nil, msgs.checkFeed.badChannel\format currentChannel unless success

        version = SemanticVersioning\toNumber updateRecord.version
        unless version
            return nil, msgs.checkFeed.invalidVersion\format @@terms.scriptType.singular[@record.scriptType],
                                                             @record.name, currentChannel, tostring updateRecord.version
        return updateRecord, nil, version

    ---Returns this task's trusted and blocked feed-URL sets: DependencyControl's official lists merged with the user's
    ---config (`extraFeeds`, `trustedFeeds`, `blockedFeeds`). A blocked URL always overrides a trusted one.
    ---@return table<string,boolean> trusted Trusted feed URLs.
    ---@return string[] blocked Officially block-listed feed URL prefixes.
    ---@return table<string,boolean> official The officially trusted feeds as per DependencyControl's own feed.
    getFeedTrust: =>
        official, officialBlocked = @updater\getOfficialFeedTrust!
        config = @updater.config.c
        trusted = {url, true for url in pairs official}
        trusted[url] = true for url in *(config.extraFeeds or {})
        trusted[url] = true for url in *(config.trustedFeeds or {})
        blocked = [prefix for prefix in *officialBlocked]
        blocked[#blocked + 1] = prefix for prefix in *(config.blockedFeeds or {})
        return trusted, blocked, official

    ---Reports whether a feed URL is matched by any of the given prefixes. 
    ---Matching is case-insensitive to align with the case-insensitive nature of domain names (and at least some path systems).
    ---Used for evasion-resistant feed block list matching.
    ---@param url? string The feed URL to test.
    ---@param prefixes? string[] The URL prefixes to match against.
    ---@return boolean matches True if the URL matches any prefix, false otherwise.
    @feedMatchesPrefix = (url, prefixes = {}) =>
        return false unless url
        url = url\lower!
        for prefix in *prefixes
            prefix = prefix\lower!
            return true if #prefix > 0 and url\sub(1, #prefix) == prefix
        return false

    ---Returns the namespace of the installed module whose persisted record lists `alias` in its
    ---`provides`, or nil if none does. Lets resolution of a not-yet-loaded alias prefer the provider
    ---that's already installed over switching to a different one.
    ---@param alias string The bare module name to look for in installed modules' `provides` lists.
    ---@return string? namespace The namespace of the installed module that provides `alias`, or nil if none does.
    getInstalledProviderFor: (alias) =>
        view = @updater.config\getSectionHandler @@ScriptType.name.legacy[@@ScriptType.Module]
        return unless view and view.c
        for namespace, record in pairs view.c
            continue unless type(record) == "table"
            for entry in *(record.provides or {})
                return namespace if (type(entry) == "table" and entry.name or entry) == alias

    ---Selects the best candidate to satisfy this task's requirement from a pooled set, ranking by trust band, then
    ---version, then a deterministic tie-break. A candidate must support the current platform and have files to install.
    ---A direct candidate is matched and ranked by its release version; a provider by the alias version range it declares
    ---(or any version in case it doesn't), ranked by the highest version that range covers.
    ---@param candidates { record: ScriptUpdateRecord, feedUrl: string, direct: boolean, band: UpdaterTrustBand, providesVersion?: string }[] Pooled candidates, channel already selected on each record.
    ---@return { record: ScriptUpdateRecord, feedUrl: string, direct: boolean, band: UpdaterTrustBand, providesVersion?: string }? selected The chosen candidate, or nil when none is eligible.
    selectCandidate: (candidates) =>
        atLeastTarget = ">=#{SemanticVersioning\toString @targetVersion}"
        eligible = {}
        for candidate in *candidates
            local rankVersion
            if candidate.direct
                versionNumber = SemanticVersioning\toNumber candidate.record.version
                continue unless versionNumber and SemanticVersioning\check versionNumber, @targetVersion
                rankVersion = versionNumber
            else
                -- a provider is matched and ranked by its declared alias range, defaulting to any version
                range = candidate.providesVersion or "*"
                continue unless SemanticVersioning\rangesIntersect range, atLeastTarget
                rankVersion = SemanticVersioning\getRangeMaxVersion range
                continue unless rankVersion
            continue unless candidate.record\checkPlatform!
            continue unless candidate.record.files and #candidate.record.files > 0
            eligible[#eligible + 1] = {:candidate, :rankVersion}

        return nil if #eligible == 0
        declaredFeed = @record.feed
        table.sort eligible, (a, b) ->
            return a.candidate.band < b.candidate.band if a.candidate.band != b.candidate.band
            return a.rankVersion > b.rankVersion if a.rankVersion != b.rankVersion
            aDeclared, bDeclared = a.candidate.feedUrl == declaredFeed, b.candidate.feedUrl == declaredFeed
            return aDeclared if aDeclared != bDeclared
            return a.candidate.record.namespace < b.candidate.record.namespace

        winner, topVersion = eligible[1].candidate, eligible[1].rankVersion
        tied = [e.candidate.record.namespace for e in *eligible when e.candidate.band == winner.band and e.rankVersion == topVersion]
        if #tied > 1
            @logger\log msgs.run.providerAmbiguous, @record.namespace, winner.record.namespace, table.concat tied, ", "
        return winner

    ---Installs a module that `provides` this task's required module, satisfying the requirement
    ---indirectly with that provider.
    ---@param provider ScriptUpdateRecord The selected provider's feed record.
    ---@param feedUrl string The feed the provider was found in, used as its primary feed.
    ---@return any ref The loaded provider module reference, or nil on failure.
    ---@return number? code Updater status code on failure.
    ---@return string? detail Error detail on failure.
    installProvider: (provider, feedUrl) =>
        DependencyControl or= require "l0.DependencyControl"
        providerRecord = DependencyControl {
            moduleName: provider.namespace, name: provider.name or provider.namespace,
            version: -1, virtual: true, feed: feedUrl, url: provider.url
        }
        addFeeds = [feed for feed in *@addFeeds]
        addFeeds[#addFeeds + 1] = feedUrl
        @updater\require providerRecord, @targetVersion, addFeeds, @optional

    ---Runs the full update/install flow for this task.
    ---@param waitLock? boolean Wait for a concurrent update to finish instead of bailing.
    ---@return number statusCode
    ---@return any detail
    run: (waitLock) =>
        logUpdateError = (code, extErr, virtual = @record.virtual) ->
            if code < 0
                @logger\log @getUpdaterErrorMsg code, @record.name, @record.scriptType, virtual, extErr
            return code, extErr

        with @record do @logger\log msgs.run.starting, @@terms.isInstall[.virtual],
                                                       @@terms.scriptType.singular[.scriptType], .name

        -- don't perform update of a script when another one is already running for the same script
        return logUpdateError -10 if @running

        -- don't shadow scripts installed to the ?data automation dir with a ?user copy
        entryPath, isUserPath = @record\getEntryPointPath!
        if isUserPath == false
            return logUpdateError -9, entryPath

        -- check if the script was already updated
        if @updated and @record\checkVersion @targetVersion
            @logger\log msgs.run.alreadyUpdated, @record.name, SemanticVersioning\toString @record.version
            return 2

        -- check internet connection
        return logUpdateError -7 unless downloader\isInternetConnected!

        -- get a lock on the updater
        success, otherHost = @updater\acquireLock waitLock
        return logUpdateError -5, otherHost unless success

        -- Resolve which package, from which feed, satisfies the requirement. Candidates are ranked according
        -- to trust bands.Feeds are fetched lazily per-trust band, so we only reach for less-trusted feeds 
        -- when no closer source can satisfy. 
        config, userFeed, declaredFeed = @updater.config.c, @record.config.c.userFeed, @record.feed
        trusted, blocked, official = @getFeedTrust!
        isBlocked = (url) -> @@feedMatchesPrefix url, blocked

        installedProviderNamespace = @record.virtual and @getInstalledProviderFor @record.namespace

        bandOf = (feedUrl, direct) ->
            if trusted[feedUrl]
                return direct and (feedUrl == declaredFeed and TrustBand.DeclaredDirect or TrustBand.TrustedDirect) or TrustBand.TrustedProvider
            return direct and TrustBand.UntrustedDirect or TrustBand.UntrustedProvider

        maxVer, candidates = 0, {}

        -- Gather candidates from a list of feed URLs, skipping any that are blocked or already tried.
        gather = (feedUrls) ->
            for feedUrl in *(feedUrls or {})
                continue if not feedUrl or @triedFeeds[feedUrl] or isBlocked feedUrl
                @triedFeeds[feedUrl] = true
                @updater\renewLock!
                @logger\trace msgs.run.feedChecking, feedUrl
                feed, errMsg = @loadFeed feedUrl
                unless feed
                    @logger\log errMsg
                    continue
                rec, errMsg, version = @checkFeed feed

                if rec
                    maxVer = math.max maxVer, version
                    candidates[#candidates + 1] = {record: rec, feedUrl: feedUrl, direct: true, band: bandOf(feedUrl, true)}
                elseif errMsg
                    @logger\log errMsg
                if @record.virtual
                    for provider in *feed\getProviders @record.namespace
                        -- the version range this provider declares for the required alias, if any
                        providesVersions = [e.version for e in *(provider.provides or {}) when type(e) == "table" and e.name == @record.namespace]
                        -- a trusted candidate from the already-installed provider stays pinned (declared-direct band)
                        band = (provider.namespace == installedProviderNamespace and trusted[feedUrl]) and TrustBand.DeclaredDirect or bandOf(feedUrl, false)
                        candidates[#candidates + 1] = {record: provider, feedUrl: feedUrl, direct: false, :band, providesVersion: providesVersions[1]}

        @logger.indent += 1
        local selected
        if userFeed
            -- a user-provided override feed is used exclusively unless block-listed.
            trusted[userFeed] = true unless isBlocked userFeed
            gather {userFeed}
            selected = @selectCandidate candidates
        else
            -- tier 1: the feed declared by / advertised in the record
            gather {declaredFeed}
            selected = @selectCandidate candidates

            unless selected and selected.band == TrustBand.DeclaredDirect
                -- tier 2: trusted feeds (official and user-added)
                gather config.extraFeeds
                gather config.trustedFeeds
                gather [url for url in *@addFeeds when trusted[url]]
                gather [url for url in pairs official] unless @optional -- don't trigger a registry-wide crawl for a nice-to-have
                selected = @selectCandidate candidates

                unless selected and selected.band <= TrustBand.TrustedProvider
                    -- tier 3: untrusted feeds
                    gather [url for url in *@addFeeds when not trusted[url]]
                    selected = @selectCandidate candidates
        @logger.indent -= 1

        local code, res
        wasVirtual = @record.virtual

        noSuitablePackage = ->
            detail = msgs.run.noFeedAvailExt\format @targetVersion == 0 and "any" or SemanticVersioning\toString(@targetVersion),
                                                    @record.virtual and "no" or SemanticVersioning\toString(@record.version),
                                                    maxVer < 1 and "none" or SemanticVersioning\toString maxVer
            if @optional
                @logger\log msgs.run.skippedOptional, @record.name, @@terms.isInstall[@record.virtual],
                                                      msgs.run.optionalNoUpdate\format detail
                return 3
            return logUpdateError -6, detail

        unless selected
            if maxVer > 0 and not @record.virtual and @targetVersion <= @record.version
                -- dependency is already up-to-date, so no matter we don't have a candidate to install
                @logger\log msgs.run.upToDate, @@terms.scriptType.singular[@record.scriptType],
                                               @record.name, SemanticVersioning\toString @record.version
                return 0
            
            return noSuitablePackage!

        -- the only candidates were from untrusted feeds: don't install one non-interactively
        if selected.band >= TrustBand.UntrustedDirect
            if @optional
                @logger\log msgs.run.skippedOptional, @record.name, @@terms.isInstall[@record.virtual],
                                                      msgs.run.optionalUntrusted\format selected.feedUrl
                return 3
            return logUpdateError -16, selected.feedUrl

        -- an installed module already satisfies the chosen (trusted) version
        if selected.direct and not @record.virtual and @record\checkVersion selected.record.version
            @logger\log msgs.run.upToDate, @@terms.scriptType.singular[@record.scriptType],
                                           @record.name, SemanticVersioning\toString @record.version
            return 0

        if selected.direct
            code, res = @performUpdate selected.record
            return logUpdateError code, res, wasVirtual

        -- indirect: install the chosen provider in place of the required module
        ref, code, extErr = @installProvider selected.record, selected.feedUrl
        unless ref
            @logger\trace msgs.run.providerInstallFailed, @record.namespace, selected.record.namespace, tostring extErr
            return noSuitablePackage!
        @ref, @updated = ref, true
        @logger\log msgs.run.providerResolved, @record.namespace, @@terms.scriptType.singular[@@ScriptType.Module],
                    selected.record.name or selected.record.namespace, selected.record.version
        return 1, selected.record.version

    ---Downloads and installs files for a selected update entry.
    ---@param update ScriptUpdateRecord
    ---@return number statusCode
    ---@return table|string|nil detail
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

        tmpDir = fileOps.getTempDir!
        res, dir = fileOps.mkdir tmpDir
        
        return finish -30, "#{tmpDir} (#{dir})" if res == nil

        @logger\log msgs.performUpdate.updateReady, tmpDir

        scriptSubDir = @record.namespace
        scriptSubDir = scriptSubDir\gsub "%.","/" if @record.scriptType == @@ScriptType.Module

        downloader\clear!
        for file in *update.files
            file.type or= "script"

            baseName = scriptSubDir .. file.name
            tmpName, prettyName = "#{tmpDir}/#{file.type}/#{baseName}", baseName
            switch file.type
                when "script", "test"
                    return finish -33, file.name if file.name\match "%.%."
                    file.fullName = UpdateFeed\getFileDeployPath @record.namespace, @record.scriptType, file.name, file.type

                    prettyName ..= " (Unit Test)" if file.type == "test"
                else
                    file.unknown = true
                    @logger\log msgs.performUpdate.unknownType, file.name, file.type
                    continue
            continue if file.delete

            unless type(file.sha1)=="string" and #file.sha1 == 40 and tonumber(file.sha1, 16)
                return finish -35, "#{prettyName} (#{tostring(file.sha1)\lower!})"

            if fileOps.verifyHash file.fullName, file.sha1
                @logger\trace msgs.performUpdate.fileUnchanged, prettyName
                continue

            dl, err = downloader\addDownload file.url, tmpName, file.sha1
            return finish -140, err unless dl
            dl.targetFile = file.fullName
            @logger\trace msgs.performUpdate.fileAddDownload, file.url, prettyName

        downloader\await (_, progress) ->
            @updater\renewLock!
            @logger\progress progress, msgs.performUpdate.filesDownloading, #downloader.downloads
        @logger\progress!

        failedDownloads = [dl for dl in *downloader.downloads when dl.status == Downloader.Download.Status.Failed]
        if #failedDownloads>0
            err = @logger\format ["#{dl.url}: #{dl.error}" for dl in *failedDownloads], 1
            return finish -245, err


        -- move files to their destination directory and clean up

        @logger\log msgs.performUpdate.movingFiles, @record.automationDir
        moveErrors = {}
        @logger.indent += 1
        for dl in *downloader.downloads
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
            .name = @record.name
            .virtual = false
            .version = SemanticVersioning\toNumber update.version
            @record\writeConfig!

        @updated = true
        @logger\log msgs.performUpdate.updSuccess, @@terms.capitalize(@@terms.isInstall[wasVirtual or false]),
                                                   @@terms.scriptType.singular[@record.scriptType],
                                                   @record.name, SemanticVersioning\toString @record.version

        -- Display changelog
        @logger\log update\getChangelog @record, (SemanticVersioning\toNumber oldVer) + 1
        @logger\log msgs.performUpdate.reloadNotice

        -- TODO: check handling of private module copies (need extra return value?)
        return finish 1, SemanticVersioning\toString @record.version


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
                                SemanticVersioning\toString @record.version

---Coordinates background update checks and update task lifecycle.
---@class Updater: UpdaterBase
class Updater extends UpdaterBase
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
        @tasks = {scriptType, {} for _, scriptType in pairs @@ScriptType when "number" == type scriptType}

    ---Loads DependencyControl's own feed and returns its official trust lists.
    ---Best-effort: if the feed can't be loaded, only DepCtrl's own feed URL is treated as trusted
    -- and nothing as officially blocked.
    ---@return table<string,boolean> trusted Officially trusted feed URLs.
    ---@return string[] blocked Officially block-listed feed URL prefixes.
    getOfficialFeedTrust: =>
        unless @officialFeedTrust
            trusted, blocked = {[constants.DEPCTRL_FEED_URL]: true}, {}
            feed = UpdateFeed constants.DEPCTRL_FEED_URL, false, nil, nil, @logger
            if feed\ensureLoaded!
                trusted[url] = true for url in *feed\getKnownFeeds!
                blocked = feed.data.blockedFeeds or {}
            @officialFeedTrust = {:trusted, :blocked}
        return @officialFeedTrust.trusted, @officialFeedTrust.blocked

    ---Creates or updates a queued update task for a record.
    ---@param record Record|table A record, or a plain table to construct one from.
    ---@param targetVersion? number|string Minimum version to install.
    ---@param addFeeds? string[]
    ---@param optional? boolean Treat this as an optional dependency.
    ---@param channel? string Update channel to use.
    ---@return UpdateTask? task
    ---@return number? code
    ---@return string? detail
    addTask: (record, targetVersion, addFeeds = {}, optional, channel) =>
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
            .addFeeds, .optional, .channel = addFeeds, optional, channel

        task, code = UpdateTask record, targetVersionNumber, addFeeds, optional, channel, @
        @tasks[record.scriptType][record.namespace] = task
        return task, code

    ---Ensures a module dependency is installed/updated and loadable.
    ---@param record Record
    ---@param ... any Forwarded to addTask (targetVersion, addFeeds, ...).
    ---@return any ref The loaded module reference, or nil on error.
    ---@return number? code
    ---@return string? detail
    require: (record, ...) =>
        @logger\assert record.scriptType == @@ScriptType.Module, msgs.require, record.name or record.namespace
        @logger\log "%s module '%s'...", record.virtual and "Installing required" or "Updating outdated", record.name
        task, code, res = @addTask record, ...
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
        if record.virtual or record.recordType == @@RecordType.Unmanaged
            return -3

        -- the update interval has not yet been passed since the last update check
        if record.config.c.lastUpdateCheck and (record.config.c.lastUpdateCheck + @config.c.updateInterval > os.time!)
            return 0

        record.config.c.lastUpdateCheck = os.time!
        record.config\write!

        -- don't shadow scripts installed to the ?data automation dir with a ?user copy
        entryPath, isUserPath = record\getEntryPointPath!
        if isUserPath == false
            @logger\trace msgs.scheduleUpdate.protectedInstall, @@terms.scriptType.singular[record.scriptType],
                          record.name or record.namespace, entryPath
            return -9, entryPath

        task = @addTask record -- no need to check for errors, because we've already accounted for those case
        @logger\trace msgs.scheduleUpdate.runningUpdate, @@terms.scriptType.singular[record.scriptType], record.name
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
            task\refreshRecord! for _,task in pairs @tasks[@@ScriptType.Module]
        
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

-- Exposed for unit testing the task-level virtual-package resolution helpers (internal API).
Updater.UpdateTask = UpdateTask
return Updater
