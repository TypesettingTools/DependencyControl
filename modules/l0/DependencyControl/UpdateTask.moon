lfs = require "lfs"
Downloader = require "l0.DependencyControl.Downloader"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
fileOps =    require "l0.DependencyControl.FileOps"
Common =     require "l0.DependencyControl.Common"
Enum =       require "l0.DependencyControl.Enum"
ModuleLoader = require "l0.DependencyControl.ModuleLoader"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"

-- How preferred a candidate package source is, in highest-to-lowest trust order.
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

---A potential package source pooled during resolution to collect a feed's update record, where it came from
---and its trust status. 
---@class CandidatePackageSource
---@field updateRecord ScriptUpdateRecord The feed's update record for this candidate, channel already selected.
---@field feedUrl string URL of the feed the candidate was found in.
---@field isDirect boolean True when the feed offers the required package by name; false when via a provider.
---@field trustBand UpdaterTrustBand The candidate's trust band.
---@field providesVersion? string For a provider, the alias version range it declares (nil = any version).

---The outcome of resolving a package source: either a source to install or a status to return.
---@class UpdaterResolution
---@field installRequired boolean Whether the caller must perform an install/update.
---@field statusCode? number Status code to return when no install is required (e.g. 0 up-to-date, 3 skipped optional, or a negative error code).
---@field statusDetailMessage? any Detail accompanying statusCode (e.g. an untrusted feed URL or an error string).
---@field selectedSource? CandidatePackageSource The source to install; set when installRequired is true.
---@field stickiness? SourceChoiceStickiness The source-choice stickiness to persist; set when installRequired is true.
---@field maxVersion? number The highest candidate version found during resolution; set when installRequired is true.

---A ceiling on which updates are allowed to prompt the user for approval, in order of decreasing
---interactivity requirements.
---@alias PromptThreshold
---| 1 # UserRequested: prompt only for user-initiated actions (e.g. a UI like the Toolbox)
---| 2 # DependencyResolution: also prompt while installing/updating a module as a dependency
---| 3 # AutoUpdates: also prompt during background scheduled update checks
PromptThreshold = Enum "UpdaterPromptThreshold", {
    UserRequested:        1
    DependencyResolution: 2
    AutoUpdates:          3
}

-- Why a given update is running.
---@alias UpdateReason
---| "user-requested" # UserRequested: an explicit user/UI request (e.g. the Toolbox)
---| "dependency-resolution" # DependencyResolution: installing/updating a module as a dependency of another
---| "auto-update" # AutoUpdate: a background scheduled update check
UpdateReason = Enum "UpdateReason", {
    UserRequested:        "user-requested"
    DependencyResolution: "dependency-resolution"
    AutoUpdate:           "auto-update"
}

-- The lowest prompt threshold at which an update of each reason is allowed to prompt.
reasonPromptThreshold = {
    [UpdateReason.UserRequested]:        PromptThreshold.UserRequested
    [UpdateReason.DependencyResolution]: PromptThreshold.DependencyResolution
    [UpdateReason.AutoUpdate]:           PromptThreshold.AutoUpdates
}

-- The user's decision when asked to trust a candidate from an untrusted feed (a cancelled prompt is nil).
---@alias FeedTrustDecision
---| "once" # Once: use the untrusted feed for this install only
---| "always" # Always: add the feed to the user's trusted feeds
---| "never" # Never: add the feed to the user's blocked feeds
FeedTrustDecision = Enum "FeedTrustDecision", {
    Once:   "once"
    Always: "always"
    Never:  "never"
}

-- How sticky a remembered package-source choice is on subsequent resolutions of the same package.
---@alias SourceChoiceStickiness
---| "unset" # Unset: no preference recorded yet; resolve normally and prompt only if interactive
---| "once" # Once: prompt again whenever a choice remains, preselecting the remembered pick
---| "retain" # Retain: reuse the remembered pick whenever it's still eligible, without prompting
---| "pinned" # Pinned: always reuse the remembered pick; if it's gone, abort (required) or skip (optional)
---| "auto" # Auto: never prompt; always resolve via the ranking, refreshing the remembered pick for information
SourceChoiceStickiness = Enum "SourceChoiceStickiness", {
    Unset:  "unset"
    Once:   "once"
    Retain: "retain"
    Pinned: "pinned"
    Auto:   "auto"
}

-- Where a remembered package source came from.
---@alias SourceFeedKind
---| "self-declared" # SelfDeclared: the feed declared in the record
---| "user-feed" # UserFeed: the per-package user override feed
---| "provider" # Provider: another module that provides the required one (URL taken from the provider's own source)
---| "other" # Other: a third-party trusted/extra feed; stores a literal feedUrl
SourceFeedKind = Enum "SourceFeedKind", {
    SelfDeclared: "self-declared"
    UserFeed:     "user-feed"
    Provider:     "provider"
    Other:        "other"
}

---A package's remembered source, persisted per-package as `currentSource`.
---@class SourceChoiceRecord
---@field feedSource SourceFeedKind Where the source came from.
---@field feedUrl? string The literal feed URL; only stored (and required) for the `other` feedSource.
---@field channel string The update channel the source was resolved on.
---@field provider? { namespace: string, version?: string } The provider that satisfied the requirement, when resolved indirectly.
---@field stickiness SourceChoiceStickiness How sticky the choice is.

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
        [17]: "Couldn't %s %s '%s' because its pinned package source is no longer available. Update or clear the pin to proceed."
        [18]: "Aborted %s of %s '%s' at your request."
        [19]: "Couldn't %s %s '%s' because you blocked the feed (%s) it would be installed from."
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
        optionalBlocked: "you blocked the feed (%s) it would be installed from."
        optionalPinnedUnavailable: "its pinned package source is no longer available."
        optionalAborted: "aborted at your request."
        providerAmbiguous: "Multiple modules provide '%s'; selected '%s' (candidates: %s)."
        providerResolved: "Satisfying required module '%s' with provider %s '%s' (v%s)."
        providerInstallFailed: "Found a provider for '%s' (%s) but it couldn't be installed: %s"
        untrustedPrompt: "The %s of %s '%s' can only be satisfied from a feed DependencyControl doesn't trust:\n%s\n\nTrust this feed and proceed?"
        choosePrompt: "More than one source can supply '%s'. Choose which one to install:"
        choiceUnavailable: "Your remembered source for '%s' is no longer available. Please choose again:"
        choiceUntrustedFlag: " [untrusted]"
        trustedFeedAdded: "Added '%s' to your trusted feeds."
        blockedFeedAdded: "Added '%s' to your blocked feeds."
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
    __promptTrustFeed: {
        trustOnce: "Trust this time"
        trustAlways: "Always trust this feed"
        trustNever: "Never (block this feed)"
    }
    promptSelectSource: {
        once:   "Just This Once"
        retain: "Remember"
        pinned: "Pin/Lock"
        auto:   "Auto-Pick"
        abort:  "Cancel"
    }
    dialogCommon: {
        ok: "OK"
        cancel: "Cancel"
    }
}

---Mutable execution state for one install/update operation.
---@class UpdateTask
class UpdateTask
    ---@private
    @__downloader = Downloader!
    ---DependencyControl's own class, required lazily to break the circular dependency.
    ---@private
    @__DependencyControl = nil

    ---Converts updater status/error codes into user-facing error messages.
    ---@param code number
    ---@param name string
    ---@param scriptType ScriptType A Common.ScriptType value.
    ---@param isInstall boolean
    ---@param detailMsg? string
    ---@return string
    @getUpdaterErrorMsg = (code, name, scriptType, isInstall, detailMsg) ->
        if code <= -100
            -- Generic downstream error
            return msgs.updateError[100]\format -code, msgs.updaterErrorComponent[math.floor(-code/100)],
                   Common.terms.isInstall[isInstall], Common.terms.scriptType.singular[scriptType], name, detailMsg
        else
            -- Updater error:
            return msgs.updateError[-code]\format Common.terms.isInstall[isInstall],
                                                  Common.terms.scriptType.singular[scriptType],
                                                  name, detailMsg

    ---Creates an update task for one record.
    ---@param record Record
    ---@param targetVersionNumber? number Minimum version to install (default 0, i.e. any).
    ---@param addFeeds? string[]
    ---@param optional? boolean Treat this as an optional dependency.
    ---@param channel? string Update channel to use.
    ---@param reason? UpdateReason Why this task runs; a prompt is allowed only when this reason is permitted by that prompt kind's configured threshold.
    ---@param updater Updater
    new: (@record, targetVersionNumber = 0, @addFeeds, @optional, @channel, @reason, @updater) =>
        @@__DependencyControl or= require "l0.DependencyControl"
        assert @record.__class == @@__DependencyControl, "First parameter must be a #{@@__DependencyControl.__name} object."
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
    ---@private
    __loadFeed: (feedUrl) =>
        feed = UpdateFeed feedUrl, false, nil, @feedConfig, @logger
        unless feed.data -- no cached data available, perform download
            success, err = feed\fetch!
            return nil, msgs.checkFeed.downloadFailed\format err unless success
        return feed

    ---Looks up this task's module in an already-loaded feed (matched by namespace), returning its
    ---update record on the task's channel along with the parsed release version.
    ---@param feed UpdateFeed A feed loaded via __loadFeed.
    ---@return ScriptUpdateRecord|nil record The module's update record, or nil if absent/unusable.
    ---@return string? err Error message worth reporting (nil when the module simply isn't in this feed).
    ---@return number? version The candidate's parsed version number.
    ---@private
    checkFeed: (feed) =>
        updateRecord, err = feed\getScript @record.namespace, @record.scriptType, @record.config, false
        return nil, err unless updateRecord   -- err is nil for "not in this feed", set for a real error

        success, currentChannel = updateRecord\setChannel @channel
        return nil, msgs.checkFeed.badChannel\format currentChannel unless success

        version = SemanticVersioning\toNumber updateRecord.version
        unless version
            return nil, msgs.checkFeed.invalidVersion\format Common.terms.scriptType.singular[@record.scriptType],
                                                             @record.name, currentChannel, tostring updateRecord.version
        return updateRecord, nil, version

    ---Returns this task's merged trusted feed-URL set: DependencyControl's officially trusted feeds plus
    ---the user's `extraFeeds` and `trustedFeeds`.
    ---@return table<string,boolean> trustedFeeds Trusted feed URLs.
    getTrustedFeeds: =>
        config = @updater.config.c
        trustedFeeds = {url, true for url in pairs(@updater\getOfficialTrustedFeeds!)}
        Common.makeSet config.extraFeeds or {}, trustedFeeds
        Common.makeSet config.trustedFeeds or {}, trustedFeeds
        return trustedFeeds

    ---Returns this task's merged blocked feed-URL prefix list: DependencyControl's official block list plus
    ---the user's `blockedFeeds`. A matching prefix overrides any trust.
    ---@return string[] blockedFeeds Block-listed feed URL prefixes.
    getBlockedFeeds: =>
        config = @updater.config.c
        blockedFeeds = [prefix for prefix in *(@updater\getOfficialBlockedFeeds!)]
        blockedFeeds[#blockedFeeds + 1] = prefix for prefix in *(config.blockedFeeds or {})
        return blockedFeeds

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

    ---Resolves the feed URL a remembered source maps to. Every kind but `Other` derives its URL from
    ---current state, so a remembered choice survives a feed-URL migration.
    ---@param previousSource SourceChoiceRecord A persisted `currentSource` table.
    ---@return string? feedUrl The derived feed URL, or nil if it can't be determined.
    ---@private
    __resolveRememberedFeedUrl: (previousSource) =>
        switch previousSource.feedSource
            when SourceFeedKind.SelfDeclared then @record.feed
            when SourceFeedKind.UserFeed then @record.config.c.userFeed
            when SourceFeedKind.Other then previousSource.feedUrl
            when SourceFeedKind.Provider
                return nil unless previousSource.provider and previousSource.provider.namespace
                view = @updater.config\getSectionHandler Common.ScriptTypeSection[Common.ScriptType.Module]
                providerRecord = view and view.c and view.c[previousSource.provider.namespace]
                providerRecord and providerRecord.feed

    ---Finds the candidate corresponding to a remembered source that is still eligible to satisfy this task.
    ---@param candidates CandidatePackageSource[] Pooled candidates.
    ---@param previousSource SourceChoiceRecord A persisted `currentSource` table.
    ---@return CandidatePackageSource? candidate The matching, eligible candidate, or nil if none matches or it's no longer eligible.
    ---@private
    __matchRememberedCandidate: (candidates, previousSource) =>
        wantUrl = @__resolveRememberedFeedUrl previousSource
        return nil unless wantUrl
        viaProvider = previousSource.feedSource == SourceFeedKind.Provider
        for candidate in *candidates
            continue unless candidate.feedUrl == wantUrl
            if viaProvider
                continue if candidate.isDirect
                continue unless previousSource.provider and candidate.updateRecord.namespace == previousSource.provider.namespace
            else
                continue unless candidate.isDirect
            return candidate if @__getCandidateRankVersion candidate
        return nil

    ---Classifies which kind of source a provided candidate came from.
    ---@param candidate CandidatePackageSource The candidate to classify.
    ---@return SourceFeedKind
    ---@private
    __feedSourceOf: (candidate) =>
        return SourceFeedKind.Provider unless candidate.isDirect
        return SourceFeedKind.SelfDeclared if candidate.feedUrl == @record.feed
        return SourceFeedKind.UserFeed if candidate.feedUrl == @record.config.c.userFeed
        return SourceFeedKind.Other

    ---Records which source satisfied this task and how sticky the choice is, in the per-package
    ---`currentSource` config, so later resolutions can honor it. Writes only when something changed.
    ---@param selectedCandidate CandidatePackageSource The chosen candidate.
    ---@param stickiness? SourceChoiceStickiness The stickiness to record (defaults to the existing one, else `unset`).
    ---@private
    __persistSource: (selectedCandidate, stickiness) =>
        return unless @record.config
        existing = @record.config.c.currentSource
        feedSource = @__feedSourceOf selectedCandidate
        currentSource = {
            :feedSource
            channel: selectedCandidate.updateRecord.activeChannel or @channel
            stickiness: stickiness or (existing and existing.stickiness) or SourceChoiceStickiness.Unset
        }
        currentSource.feedUrl = selectedCandidate.feedUrl if feedSource == SourceFeedKind.Other
        unless selectedCandidate.isDirect
            currentSource.provider = {namespace: selectedCandidate.updateRecord.namespace, version: selectedCandidate.providesVersion}

        unchanged = existing and existing.feedSource == currentSource.feedSource and
                    existing.channel == currentSource.channel and existing.stickiness == currentSource.stickiness and
                    existing.feedUrl == currentSource.feedUrl and
                    (existing.provider and existing.provider.namespace) == (currentSource.provider and currentSource.provider.namespace) and
                    (existing.provider and existing.provider.version) == (currentSource.provider and currentSource.provider.version)
        return if unchanged

        @record.config.c.currentSource = currentSource
        @record.config\save!

    ---Reports whether a candidate can satisfy this task's requirements and, if so, the version used to rank it. 
    ---A direct candidate is judged and ranked by its release version; a provider by the alias version range it 
    ---declares (or any version when it declares ranked by the highest version that range covers.
    ---@param candidate CandidatePackageSource
    ---@return number? rankVersion The ranking version, or nil if the candidate is ineligible.
    ---@private
    __getCandidateRankVersion: (candidate) =>
        local rankVersion
        if candidate.isDirect
            versionNumber = SemanticVersioning\toNumber candidate.updateRecord.version
            return nil unless versionNumber and SemanticVersioning\check versionNumber, @targetVersion
            rankVersion = versionNumber
        else
            -- a provider is matched and ranked by its declared alias range, defaulting to any version
            range = candidate.providesVersion or "*"
            return nil unless SemanticVersioning\rangesIntersect range, ">=#{SemanticVersioning\toString @targetVersion}"
            rankVersion = SemanticVersioning\getRangeMaxVersion range
            return nil unless rankVersion
        return nil unless candidate.updateRecord\checkPlatform!
        return nil unless candidate.updateRecord.files and #candidate.updateRecord.files > 0
        rankVersion

    ---Selects the best candidate to satisfy this task's requirement from a pooled set, ranking by trust band, then
    ---version, then a deterministic tie-break.
    ---@param candidates CandidatePackageSource[] Pooled candidates, channel already selected on each record.
    ---@return CandidatePackageSource? selected The chosen candidate, or nil when none is eligible.
    ---@return CandidatePackageSource[]? tied The selected candidate plus any others tied with it on band and version (for an interactive chooser); nil when none is eligible.
    ---@return CandidatePackageSource[]? eligible All eligible candidates, sorted best-first (for the offer-all-sources chooser); nil when none is eligible.
    ---@private
    __selectCandidate: (candidates) =>
        eligibleCandidates = {}
        for candidate in *candidates
            rankVersion = @__getCandidateRankVersion candidate
            eligibleCandidates[#eligibleCandidates + 1] = {:candidate, :rankVersion} if rankVersion
        return nil if #eligibleCandidates == 0

        declaredFeed = @record.feed
        table.sort eligibleCandidates, (a, b) ->
            return a.candidate.trustBand < b.candidate.trustBand if a.candidate.trustBand != b.candidate.trustBand
            return a.rankVersion > b.rankVersion if a.rankVersion != b.rankVersion
            aDeclared, bDeclared = a.candidate.feedUrl == declaredFeed, b.candidate.feedUrl == declaredFeed
            return aDeclared if aDeclared != bDeclared
            return a.candidate.updateRecord.namespace < b.candidate.updateRecord.namespace

        winner, topVersion = eligibleCandidates[1].candidate, eligibleCandidates[1].rankVersion
        tied = [e.candidate for e in *eligibleCandidates when e.candidate.trustBand == winner.trustBand and e.rankVersion == topVersion]
        if #tied > 1
            @logger\log msgs.run.providerAmbiguous, @record.namespace, winner.updateRecord.namespace,
                        table.concat [c.updateRecord.namespace for c in *tied], ", "
        return winner, tied, [e.candidate for e in *eligibleCandidates]

    ---Installs a module that `provides` this task's required module, satisfying the requirement
    ---indirectly with that provider.
    ---@param provider ScriptUpdateRecord The selected provider's feed record.
    ---@param feedUrl string The feed the provider was found in, used as its primary feed.
    ---@return any ref The loaded provider module reference, or nil on failure.
    ---@return number? code Updater status code on failure.
    ---@return string? detail Error detail on failure.
    ---@private
    __installProvider: (provider, feedUrl) =>
        @@__DependencyControl or= require "l0.DependencyControl"
        providerRecord = @@.__DependencyControl {
            moduleName: provider.namespace, name: provider.name or provider.namespace,
            version: -1, virtual: true, feed: feedUrl, url: provider.url
        }
        addFeeds = [feed for feed in *@addFeeds]
        addFeeds[#addFeeds + 1] = feedUrl
        @updater\require providerRecord, @targetVersion, addFeeds, @optional, nil, @reason

    ---Reports whether this task may prompt the user for a given kind of prompt,
    ---e.g. to approve an untrusted feed or choose among multiple eligible candidates.
    ---@param threshold? PromptThreshold The configured threshold for this prompt kind.
    ---@return boolean
    ---@private
    __shouldPrompt: (threshold) =>
        return false unless @reason
        reasonPromptThreshold[@reason] <= (threshold or PromptThreshold.UserRequested)

    ---Adds a feed URL to the user's `trustedFeeds` config and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to trust.
    addTrustedFeed: (feedUrl) =>
        trustedFeeds = [url for url in *(@updater.config.c.trustedFeeds or {})]
        trustedFeeds[#trustedFeeds + 1] = feedUrl
        @updater.config.c.trustedFeeds = trustedFeeds
        @updater.config\save!
        @logger\log msgs.run.trustedFeedAdded, feedUrl

    ---Adds a feed URL to the user's `blockedFeeds` config and persists it.
    ---@param feedUrl string The exact (case-sensitive) feed URL to block.
    addBlockedFeed: (feedUrl) =>
        blockedFeeds = [url for url in *(@updater.config.c.blockedFeeds or {})]
        blockedFeeds[#blockedFeeds + 1] = feedUrl
        @updater.config.c.blockedFeeds = blockedFeeds
        @updater.config\save!
        @logger\log msgs.run.blockedFeedAdded, feedUrl

    ---Asks the user whether to proceed with a candidate from an untrusted feed. Depending on the user's choice,
    ---the feed may be added to the trusted or blocked lists.
    ---@param selectedCandidate CandidatePackageSource A candidate source from an untrusted feed.
    ---@return FeedTrustDecision? decision The user's decision, or nil if they cancelled.
    ---@private
    __promptTrustFeed: (selectedCandidate) =>
        msg = msgs.run.untrustedPrompt\format Common.terms.isInstall[@record.virtual],
                                              Common.terms.scriptType.singular[@record.scriptType],
                                              @record.name, selectedCandidate.feedUrl
        dlg = {{class: "label", label: msg, x: 0, y: 0, width: 1, height: 1}}
        buttons = {msgs.dialogCommon.cancel, msgs.__promptTrustFeed.trustOnce, msgs.__promptTrustFeed.trustAlways,
                   msgs.__promptTrustFeed.trustNever}

        btn = aegisub.dialog.display dlg, buttons, {cancel: msgs.dialogCommon.cancel}
        return nil if not btn or btn == msgs.dialogCommon.cancel

        switch btn
            when msgs.__promptTrustFeed.trustAlways
                @addTrustedFeed selectedCandidate.feedUrl
                return FeedTrustDecision.Always
            when msgs.__promptTrustFeed.trustNever
                @addBlockedFeed selectedCandidate.feedUrl
                return FeedTrustDecision.Never
        FeedTrustDecision.Once

    ---Lets the user pick a package source among the eligible candidates and how sticky that pick should be.
    ---Untrusted candidates are flagged in the list. Choosing "Auto-Pick" keeps the algorithm's pre-selected candidate.
    ---@param candidates CandidatePackageSource[] The candidates to choose from.
    ---@param selectedCandidate? CandidatePackageSource The candidate to pre-select (defaults to the first).
    ---@param noLongerAvailable? boolean Show the "remembered source unavailable" prompt instead of the default one.
    ---@return CandidatePackageSource? chosen The picked candidate, or nil if the user aborted.
    ---@return SourceChoiceStickiness? stickiness How sticky the pick should be, or nil if the user aborted.
    ---@private
    __promptSelectPackageSource: (candidates, selectedCandidate = candidates[1], noLongerAvailable) =>
        labelFor = (candidate) ->
            label = "#{candidate.updateRecord.name or candidate.updateRecord.namespace} (#{candidate.feedUrl})"
            label ..= msgs.run.choiceUntrustedFlag if candidate.trustBand and candidate.trustBand >= TrustBand.UntrustedDirect
            label
        candidatesByLabel = {labelFor(candidate), candidate for candidate in *candidates}

        prompt = noLongerAvailable and msgs.run.choiceUnavailable or msgs.run.choosePrompt
        dlg = {
            {class: "label", label: prompt\format(@record.namespace), x: 0, y: 0, width: 2, height: 1}
            {class: "dropdown", name: "choice", items: [labelFor c for c in *candidates], value: labelFor(selectedCandidate),
             x: 0, y: 1, width: 2, height: 1}
        }
        buttons = {msgs.promptSelectSource.once, msgs.promptSelectSource.retain, msgs.promptSelectSource.pinned,
                   msgs.promptSelectSource.auto, msgs.promptSelectSource.abort}
        btn, res = aegisub.dialog.display dlg, buttons, {cancel: msgs.promptSelectSource.abort}

        switch btn
            when msgs.promptSelectSource.auto then return selectedCandidate, SourceChoiceStickiness.Auto
            when msgs.promptSelectSource.once then return (candidatesByLabel[res.choice] or selectedCandidate), SourceChoiceStickiness.Once
            when msgs.promptSelectSource.retain then return (candidatesByLabel[res.choice] or selectedCandidate), SourceChoiceStickiness.Retain
            when msgs.promptSelectSource.pinned then return (candidatesByLabel[res.choice] or selectedCandidate), SourceChoiceStickiness.Pinned
        return nil, nil

    ---Runs the full update/install flow for this task.
    ---@param waitLock? boolean Wait for a concurrent update to finish instead of bailing.
    ---@return number statusCode
    ---@return any detail
    run: (waitLock) =>
        with @record do @logger\log msgs.run.starting, Common.terms.isInstall[.virtual],
                                                       Common.terms.scriptType.singular[.scriptType], .name

        -- don't perform update of a script when another one is already running for the same script
        return @__logUpdateError -10 if @running

        -- don't shadow scripts installed to the ?data automation dir with a ?user copy
        entryPath, isUserPath = @record\getEntryPointPath!
        if isUserPath == false
            return @__logUpdateError -9, entryPath

        -- check if the script was already updated
        if @updated and @record\checkVersion @targetVersion
            @logger\log msgs.run.alreadyUpdated, @record.name, SemanticVersioning\toString @record.version
            return 2

        -- check internet connection
        return @__logUpdateError -7 unless @@__downloader\isInternetConnected!

        -- get a lock on the updater
        success, otherHost = @updater\acquireLock waitLock
        return @__logUpdateError -5, otherHost unless success

        resolution = @__resolve!
        return resolution.statusCode, resolution.statusDetailMessage unless resolution.installRequired
        selectedSource, stickiness, maxVersion = resolution.selectedSource, resolution.stickiness, resolution.maxVersion

        -- remember which source satisfied this package and how sticky the choice is, for next time
        @__persistSource selectedSource, stickiness

        -- an installed module already satisfies the chosen (trusted) version
        if selectedSource.isDirect and not @record.virtual and @record\checkVersion selectedSource.updateRecord.version
            @logger\log msgs.run.upToDate, Common.terms.scriptType.singular[@record.scriptType],
                                           @record.name, SemanticVersioning\toString @record.version
            return 0

        wasVirtual = @record.virtual
        if selectedSource.isDirect
            code, res = @performUpdate selectedSource.updateRecord
            return @__logUpdateError code, res, wasVirtual

        -- for an indirect source, install the chosen provider in place of the required module
        ref, code, extErr = @__installProvider selectedSource.updateRecord, selectedSource.feedUrl
        unless ref
            @logger\trace msgs.run.providerInstallFailed, @record.namespace, selectedSource.updateRecord.namespace, tostring extErr
            code, detail = @__reportNoSuitablePackage maxVersion
            return code, detail
        @ref, @updated = ref, true
        @logger\log msgs.run.providerResolved, @record.namespace, Common.terms.scriptType.singular[Common.ScriptType.Module],
                    selectedSource.updateRecord.name or selectedSource.updateRecord.namespace, selectedSource.updateRecord.version
        return 1, selectedSource.updateRecord.version

    ---Logs the error message for a negative status code and returns the code and detail unchanged.
    ---Non-negative (success/skip) codes are returned without logging.
    ---@param statusCode number The updater status code.
    ---@param statusDetailMessage? string a message with further explanation of the outcome, if any.
    ---@param virtual? boolean Whether this is a fresh install (default: the record's current virtual flag).
    ---@return number statusCode the same code passed in.
    ---@return string? statusDetailMessage  the same status detail message passed in, if any.
    ---@private
    __logUpdateError: (statusCode, statusDetailMessage, virtual = @record.virtual) =>
        if statusCode < 0
            @logger\log UpdateTask.getUpdaterErrorMsg statusCode, @record.name, @record.scriptType, virtual, statusDetailMessage
        return statusCode, statusDetailMessage

    ---Logs and returns this task's "no suitable package" status — a skip if optional, else a failure.
    ---@param maxVersion number The highest candidate version seen during resolution (0 when none was found).
    ---@return number statusCode A negative failure code for a required dependency, or the skip code (3) for an optional one.
    ---@return string? statusDetailMessage The availability summary for a failure; nil for an optional skip.
    ---@private
    __reportNoSuitablePackage: (maxVersion) =>
        detail = msgs.run.noFeedAvailExt\format @targetVersion == 0 and "any" or SemanticVersioning\toString(@targetVersion),
                                                @record.virtual and "no" or SemanticVersioning\toString(@record.version),
                                                maxVersion < 1 and "none" or SemanticVersioning\toString maxVersion
        if @optional
            @logger\log msgs.run.skippedOptional, @record.name, Common.terms.isInstall[@record.virtual],
                                                  msgs.run.optionalNoUpdate\format detail
            return 3
        return @__logUpdateError -6, detail

    ---Resolves which package source should satisfy this task, without installing anything. May fetch feeds
    ---and prompt the user (to choose a package source or to approve an untrusted feed). The updater lock
    ---must already be held.
    ---@return UpdaterResolution resolution The source to install, or a status code to return when no install is needed.
    ---@private
    __resolve: =>
        withoutInstall = (statusCode, statusDetailMessage) -> {installRequired: false, :statusCode, :statusDetailMessage}

        -- Candidates are ranked by trust band. Feeds are fetched lazily per band, so we only reach for
        -- less-trusted feeds when no closer source can satisfy.
        config, userFeed, declaredFeed = @updater.config.c, @record.config.c.userFeed, @record.feed
        trusted, blocked = @getTrustedFeeds!, @getBlockedFeeds!
        isBlocked = (url) -> @@feedMatchesPrefix url, blocked

        -- the remembered package source for this package, and how sticky the user's last choice was
        remembered = @record.config.c.currentSource
        stickiness = remembered and remembered.stickiness or SourceChoiceStickiness.Unset
        -- a remembered provider stays pinned to its band so a version bump updates it in place instead of switching providers
        stickyProvider = remembered and remembered.provider and remembered.provider.namespace

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
                feed, errMsg = @__loadFeed feedUrl
                unless feed
                    @logger\log errMsg
                    continue
                rec, errMsg, version = @checkFeed feed

                if rec
                    maxVer = math.max maxVer, version
                    candidates[#candidates + 1] = {updateRecord: rec, feedUrl: feedUrl, isDirect: true, trustBand: bandOf(feedUrl, true)}
                elseif errMsg
                    @logger\log errMsg
                if @record.virtual
                    for provider in *feed\getProviders @record.namespace
                        -- the version range this provider declares for the required alias, if any
                        providesVersions = [e.version for e in *(provider.provides or {}) when type(e) == "table" and e.name == @record.namespace]
                        -- a trusted candidate from the sticky (remembered/installed) provider stays pinned (declared-direct band)
                        trustBand = (provider.namespace == stickyProvider and trusted[feedUrl]) and TrustBand.DeclaredDirect or bandOf(feedUrl, false)
                        candidates[#candidates + 1] = {updateRecord: provider, feedUrl: feedUrl, isDirect: false, :trustBand, providesVersion: providesVersions[1]}

        @logger.indent += 1
        -- a user-provided override feed is used exclusively and counts as trusted unless block-listed
        trusted[userFeed] = true if userFeed and not isBlocked userFeed

        local selected, tied, eligible
        -- A hard pin or soft-remember reuses the remembered source directly: load its feed first (it may
        -- sit in a lower or untrusted tier the cascade would never reach) and reuse it if still eligible.
        -- An exclusive userFeed still constrains it, so a remembered source outside userFeed counts as gone.
        reuse = nil
        if stickiness == SourceChoiceStickiness.Pinned or stickiness == SourceChoiceStickiness.Retain
            rememberedUrl = @__resolveRememberedFeedUrl remembered
            if rememberedUrl and (not userFeed or rememberedUrl == userFeed)
                gather {rememberedUrl}
                reuse = @__matchRememberedCandidate candidates, remembered

        if reuse
            selected = reuse
        elseif stickiness == SourceChoiceStickiness.Pinned
            -- pinned, but the remembered source is gone: don't silently switch to another one
            selected = nil
        elseif userFeed
            gather {userFeed}
            selected, tied, eligible = @__selectCandidate candidates
        else
            -- tier 1: the feed declared by / advertised in the record
            gather {declaredFeed}
            selected, tied, eligible = @__selectCandidate candidates

            unless selected and selected.trustBand == TrustBand.DeclaredDirect
                -- tier 2: trusted feeds (official and user-added)
                gather config.extraFeeds
                gather config.trustedFeeds
                gather [url for url in *@addFeeds when trusted[url]]
                gather [url for url in pairs(@updater\getOfficialTrustedFeeds!)] unless @optional -- don't trigger a registry-wide crawl for a nice-to-have
                selected, tied, eligible = @__selectCandidate candidates

                unless selected and selected.trustBand <= TrustBand.TrustedProvider
                    -- tier 3: untrusted feeds
                    gather [url for url in *@addFeeds when not trusted[url]]
                    selected, tied, eligible = @__selectCandidate candidates
        @logger.indent -= 1

        abortResolution = ->
            if @optional
                @logger\log msgs.run.skippedOptional, @record.name, Common.terms.isInstall[@record.virtual],
                                                      msgs.run.optionalAborted
                return 3
            return @__logUpdateError -18

        -- a hard pin whose remembered source vanished aborts (required) or skips (optional)
        if stickiness == SourceChoiceStickiness.Pinned and not reuse
            if @optional
                @logger\log msgs.run.skippedOptional, @record.name, Common.terms.isInstall[@record.virtual],
                                                      msgs.run.optionalPinnedUnavailable
                return withoutInstall 3
            code, detail = @__logUpdateError -17
            return withoutInstall code, detail

        unless selected
            if maxVer > 0 and not @record.virtual and @targetVersion <= @record.version
                -- dependency is already up-to-date, so no matter we don't have a candidate to install
                @logger\log msgs.run.upToDate, Common.terms.scriptType.singular[@record.scriptType],
                                               @record.name, SemanticVersioning\toString @record.version
                return withoutInstall 0

            code, detail = @__reportNoSuitablePackage maxVer
            return withoutInstall code, detail

        -- consult the remembered source choice to decide whether to let the user pick a package source.
        -- `auto` never asks and the reuse path already settled the pick, so neither prompts here.
        unless reuse or stickiness == SourceChoiceStickiness.Auto
            -- present every eligible candidate when configured to, otherwise only an exact band/version tie
            choices = config.packageChoiceOfferAllSources and eligible or tied
            allowPrompt = @__shouldPrompt config.packageChoicePromptThreshold
            remPick = remembered and @__matchRememberedCandidate candidates, remembered

            if stickiness == SourceChoiceStickiness.Retain
                -- the soft-remembered pick is gone: re-ask in interactive mode, downgrade to `once` otherwise
                if allowPrompt
                    pick, pickType = @__promptSelectPackageSource choices, selected, true
                    unless pick
                        code, detail = abortResolution!
                        return withoutInstall code, detail
                    selected, stickiness = pick, pickType
                else
                    stickiness = SourceChoiceStickiness.Once
            elseif choices and #choices > 1 and allowPrompt
                pick, pickType = @__promptSelectPackageSource choices, (remPick or selected)
                unless pick
                    code, detail = abortResolution!
                    return withoutInstall code, detail
                selected, stickiness = pick, pickType

        -- the chosen candidate is from an untrusted feed: install it only if the user is asked and approves
        if selected.trustBand >= TrustBand.UntrustedDirect
            trustDecision = @__shouldPrompt(@updater.config.c.feedTrustPromptThreshold) and @__promptTrustFeed selected
            unless trustDecision == FeedTrustDecision.Once or trustDecision == FeedTrustDecision.Always
                userBlockedFeed = trustDecision == FeedTrustDecision.Never
                if @optional
                    reason = (userBlockedFeed and msgs.run.optionalBlocked or msgs.run.optionalUntrusted)\format selected.feedUrl
                    @logger\log msgs.run.skippedOptional, @record.name, Common.terms.isInstall[@record.virtual], reason
                    return withoutInstall 3
                code, detail = @__logUpdateError (userBlockedFeed and -19 or -16), selected.feedUrl
                return withoutInstall code, detail

        return {installRequired: true, selectedSource: selected, :stickiness, maxVersion: maxVer}

    ---Downloads and installs files for a selected update entry.
    ---@param update ScriptUpdateRecord
    ---@return number statusCode
    ---@return table|string|nil detail
    ---@private
    performUpdate: (update) =>
        finish = (...) ->
            @running = false
            if @record.virtual or @record.updateRecordType == Common.RecordType.Unmanaged
                ModuleLoader.removeDummyRef @record
            return ...

        -- don't perform update of a script when another one is already running for the same script
        return finish -10 if @running
        @running = true

        -- set a dummy ref (which hasn't yet been set for virtual and unmanaged modules)
        -- and record version to allow resolving circular dependencies
        if @record.virtual or @record.updateRecordType == Common.RecordType.Unmanaged
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
        scriptSubDir = scriptSubDir\gsub "%.","/" if @record.scriptType == Common.ScriptType.Module

        @@__downloader\clear!
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

            dl, err = @@__downloader\addDownload file.url, tmpName, file.sha1
            return finish -140, err unless dl
            dl.targetFile = file.fullName
            @logger\trace msgs.performUpdate.fileAddDownload, file.url, prettyName

        @@__downloader\await (_, progress) ->
            @updater\renewLock!
            @logger\progress progress, msgs.performUpdate.filesDownloading, #@@__downloader.downloads
        @logger\progress!

        failedDownloads = [dl for dl in *@@__downloader.downloads when dl.status == Downloader.Download.Status.Failed]
        if #failedDownloads>0
            err = @logger\format ["#{dl.url}: #{dl.error}" for dl in *failedDownloads], 1
            return finish -245, err


        -- move files to their destination directory and clean up

        @logger\log msgs.performUpdate.movingFiles, @record.automationDir
        moveErrors = {}
        @logger.indent += 1
        for dl in *@@__downloader.downloads
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
        else fileOps.rmdir tmpDir   -- recurses by default: the temp dir still holds the per-type subdirectories
        os.remove file.fullName for file in *update.files when file.delete and not file.unknown

        -- Nuke old module refs and reload
        oldVer, wasVirtual = @record.version, @record.virtual

        -- Update complete, refresh module information/configuration
        if @record.scriptType == Common.ScriptType.Module
            ref = ModuleLoader.loadModule @record, @record, false, true
            unless ref
                if @record._error
                    return finish -56, @logger\format @record._error, 1
                else return finish -55

            -- get a fresh version record
            if type(ref.version) == "table" and ref.version.__class.__name == @@__DependencyControl.__name
                @record = ref.version
            else
                -- look for any compatible non-DepCtrl version records and create an unmanaged record
                return finish -57 unless ref.version
                success, rec = pcall @@__DependencyControl, { moduleName: @record.moduleName, version: ref.version,
                                                          recordType: Common.RecordType.Unmanaged, name: @record.name }
                return finish -58, rec unless success
                @record = rec
            @ref = ref

        else with @record
            .name = @record.name
            .virtual = false
            .version = SemanticVersioning\toNumber update.version
            @record\writeConfig!

        @updated = true
        @logger\log msgs.performUpdate.updSuccess, Common.terms.capitalize(Common.terms.isInstall[wasVirtual or false]),
                                                   Common.terms.scriptType.singular[@record.scriptType],
                                                   @record.name, SemanticVersioning\toString @record.version

        -- Display changelog
        @logger\log update\getChangelog @record, (SemanticVersioning\toNumber oldVer) + 1
        @logger\log msgs.performUpdate.reloadNotice

        -- TODO: check handling of private module copies (need extra return value?)
        return finish 1, SemanticVersioning\toString @record.version


    ---@private
    refreshRecord: =>
        with @record
            wasVirtual, oldVersion = .virtual, .version
            \loadConfig true
            if wasVirtual and not .virtual or .version > oldVersion
                @updated = true
                @ref = ModuleLoader.loadModule @record, @record, false, true if .scriptType == Common.ScriptType.Module
                if wasVirtual
                    @logger\log msgs.refreshRecord.unsetVirtual, Common.terms.scriptType.singular[.scriptType], .name
                else
                    @logger\log msgs.refreshRecord.otherUpdate, Common.terms.scriptType.singular[.scriptType], .name,
                                SemanticVersioning\toString @record.version

UpdateTask.PromptThreshold = PromptThreshold
UpdateTask.UpdateReason = UpdateReason
UpdateTask.SourceChoiceStickiness = SourceChoiceStickiness
UpdateTask.SourceFeedKind = SourceFeedKind
UpdateTask.FeedTrustDecision = FeedTrustDecision

-- Reveal the private dialog button labels to the unit tests without putting them on the public API.
return UnitTestSuite\withTestExports UpdateTask, {:msgs}
