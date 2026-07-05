export script_name = "DependencyControl Toolbox"
export script_description = "Provides DependencyControl maintenance and configuration tools."
export script_version = "0.3.0"
export script_author = "line0"
export script_namespace = "l0.DependencyControl.Toolbox"

DepCtrl = require "l0.DependencyControl"
Common = DepCtrl.Common
constants = require "l0.DependencyControl.Constants"
depRec = DepCtrl {
    feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/DependencyControl.json",
    {
        {"l0.DependencyControl", version: "0.7.0"}
    }
}
logger = DepCtrl.logger
logger.usePrefixWindow = false

msgs = {
    install: {
        scanning: "Scanning %d available feeds...",
        createScriptUpdateRecordFailed: "Failed to create an update record for %s '%s' from feed %s: %s"
    }
    uninstall: {
        running: "Uninstalling %s '%s'..."
        success: "%s '%s' was removed successfully. Reload your automation scripts or restart Aegisub for the changes to take effect."
        lockedFiles: "%s Some script files are still in use and will be deleted during the next restart/reload:\n%s"
        error: "Error: %s"
    }
    scheduleUpdatesAndRegisterTests: {
        moduleLoadFailed: "Couldn't load module '%s' to schedule updates/register its tests: %s"
        registerMacrosError: "Error registering test macros for module '%s': %s"
        scheduleError: "Unexpected error scheduling update for record '%s': %s"
    }
    macroConfig: {
        hints: {
            customMenu: "Lets you sort your automation macros into submenus. Use / to denote submenu levels."
            userFeed: "When set the updater will use this feed exclusively to update the script in question."
        }
    }
    manageFeeds: {
        scanning:       "Discovering feeds — this fetches each known feed and may take a moment..."
        noFeeds:        "DependencyControl doesn't know about any feeds yet."
        openFailed:     "Couldn't open a browser for %s."
        sourcedWarning: "%s %s will change the update source of these installed packages:\n%s\n\nProceed?"
        cantBlockBootstrap: "Refusing that block — it would match DependencyControl's own feed and disable all trust."
    }
}

-- Shared Functions

buildInstalledDlgList = (scriptType, config, isUninstall) ->
    list, map, protectedModules = {}, {}, {}
    if isUninstall
        protectedModules[mdl.moduleName] = true for mdl in *DepCtrl.version.requiredModules
        protectedModules[DepCtrl.version.moduleName] = true

    for namespace, script in pairs config.c[scriptType]
        continue if protectedModules[namespace]
        item = "%s v%s%s"\format script.name, DepCtrl.SemanticVersioning\toString(script.version),
                                 script.activeChannel and " [#{script.activeChannel}]" or ""
        list[#list+1] = item
        table.sort list, (a, b) -> a\lower! < b\lower!
        map[item] = script
    return list, map

getConfig = (section) ->
    config = DepCtrl.config\getSectionHandler section
    config.c.macros or= {} if not section or #section == 0
    return config

getKnownFeeds = (config) ->
    getScriptFeeds = (t) -> [v.userFeed or v.feed for _,v in pairs config.c[t] when v.feed or v.userFeed]

    -- fetch all feeds and look for further known feeds
    recurse = (feeds, knownFeeds = {}, feedList = {}) ->
        for url in *feeds
            feed = DepCtrl.UpdateFeed url
            continue if knownFeeds[url] or not feed.data
            feedList[#feedList+1], knownFeeds[url] = feed, true
            recurse feed\getKnownFeeds!, knownFeeds, feedList
        return knownFeeds, feedList

    -- get additional feeds added by the user
    knownFeeds, feedList = recurse DepCtrl.config.c.extraFeeds
    -- collect feeds from all installed automation scripts and modules
    recurse getScriptFeeds("modules"), knownFeeds, feedList
    recurse getScriptFeeds("macros"), knownFeeds, feedList

    return feedList

getScriptListDlg = (macros, modules) ->
    {
        {label: "Automation Scripts: ", class: "label",    x: 0, y: 0, width: 1,  height: 1                               },
        {name:  "macro",                class: "dropdown", x: 1, y: 0, width: 1,  height: 1, items: macros, value: ""     },
        {label: "Modules: ",            class: "label",    x: 0, y: 1, width: 1,  height: 1                               },
        {name:  "module",               class: "dropdown", x: 1, y: 1, width: 1,  height: 1, items: modules, value: ""    }
    }

runUpdaterTask = (scriptData, isInstall) ->
    return unless scriptData

    task, code, extErr = DepCtrl.updater\addTask scriptData, nil, nil, nil, scriptData.channel,
                                                 DepCtrl.Updater.UpdateReason.UserRequested
    return task\run! if task
    with scriptData
         logger\log DepCtrl.Updater.getUpdaterErrorMsg code, .moduleName or .name,
            .moduleName and Common.ScriptType.Module or Common.ScriptType.Automation, isInstall, extErr

-- Macros

install = ->
    config = getConfig!

    addAvailableToInstall = (tbl, feed, scriptType) ->
        scriptTypeConfigAndFeedKeyName = Common.ScriptTypeSection[scriptType]

        for namespace, data in pairs feed.data[scriptTypeConfigAndFeedKeyName]
            scriptData, err = feed\getScript namespace, scriptType, nil, false
            if err
                logger\warn msgs.install.createScriptUpdateRecordFailed\format Common.terms.scriptType.singular[scriptType], namespace, feed.url, err
                continue

            channels, defaultChannel = scriptData\getChannels!
            tbl[namespace] or= {}
            for channel in *channels
                record = scriptData.data.channels[channel]
                verNum = DepCtrl.SemanticVersioning\toNumber record.version
                unless config.c[scriptTypeConfigAndFeedKeyName][namespace] or (tbl[namespace][channel] and verNum < tbl[namespace][channel].verNum)
                    tbl[namespace][channel] = { name: scriptData.name, version: record.version, verNum: verNum, feed: feed.url,
                                                default: defaultChannel == channel, moduleName: scriptType == Common.ScriptType.Module and namespace }
        return tbl

    buildDlgList = (tbl) ->
        list, map = {}, {}
        for namespace, channels in pairs tbl
            for channel, rec in pairs channels
                item = "%s v%s%s"\format rec.name, rec.version, rec.default and "" or " [#{channel}]"
                list[#list+1] = item
                table.sort list, (a, b) -> a\lower! < b\lower!
                map[item] = { :namespace, :channel, feed: rec.feed, name: rec.name, virtual: true,
                              moduleName: rec.moduleName }

        return list, map

    -- get a list of the highest versions of automation scripts and modules
    -- we can install but wich are not yet installed
    macros, modules, feeds = {}, {}, getKnownFeeds config

    logger\log msgs.install.scanning, #feeds
    for feed in *feeds
        macros = addAvailableToInstall macros, feed, Common.ScriptType.Automation
        modules = addAvailableToInstall modules, feed, Common.ScriptType.Module

    -- build macro and module lists as well as reverse mappings
    moduleList, moduleMap = buildDlgList modules
    macroList, macroMap = buildDlgList macros

    btn, res = aegisub.dialog.display getScriptListDlg macroList, moduleList
    return unless btn

    -- create and run the update tasks
    macro, mdl = macroMap[res.macro], moduleMap[res.module]
    runUpdaterTask mdl, true
    runUpdaterTask macro, true

uninstall = ->
    doUninstall = (script) ->
        return unless script
        scriptType = script.moduleName and "Module" or "Macro"
        logger\log msgs.uninstall.running, scriptType, script.name
        success, details = DepCtrl(script)\uninstall!
        if success == nil
            if "table" == type details
                -- error may be a string or a file list
                details = table.concat ["#{path}: #{res[2]}" for path, res in pairs details when res[1] == nil], "\n"
            logger\log msgs.uninstall.error, details
        else
            msg = msgs.uninstall.success\format scriptType, script.name
            logger\log if success
                msg
            else
                fileList = table.concat ["#{path} (#{res[2]})" for path, res in pairs details when res[1] != true], "\n"
                msgs.uninstall.lockedFiles\format msg, fileList

        return success

    config = getConfig!

    -- build macro and module lists as well as reverse mappings
    moduleList, moduleMap = buildInstalledDlgList "modules", config, true
    macroList, macroMap = buildInstalledDlgList "macros", config, true

    btn, res = aegisub.dialog.display getScriptListDlg macroList, moduleList
    return unless btn

    macro, mdl = macroMap[res.macro], moduleMap[res.module]
    doUninstall mdl
    doUninstall macro

update = ->
    config = getConfig!

    -- build macro and module lists as well as reverse mappings
    moduleList, moduleMap = buildInstalledDlgList "modules", config
    macroList, macroMap = buildInstalledDlgList "macros", config

    btn, res = aegisub.dialog.display getScriptListDlg macroList, moduleList
    return unless btn

    -- create and run the update tasks
    macro, mdl = macroMap[res.macro], moduleMap[res.module]
    runUpdaterTask mdl, false
    runUpdaterTask macro, false

macroConfig = ->
    config = getConfig "macros"

    dlg, i = {}, 1
    for nsp, macro in pairs config.userConfig
        dlg[i*5+t-1] = tbl for t, tbl in ipairs {
            {label: macro.name,              class: "label",  x: 0, y: i, width: 1,  height: 1  },
            {label: "Menu Group: ",          class: "label",  x: 1, y: i, width: 1,  height: 1  },
            {name:  "#{nsp}.customMenu",     class: "edit",   x: 2, y: i, width: 1,  height: 1,
             text: macro.customMenu or "",    hint: msgs.macroConfig.hints.customMenu           },
            {label: "Custom Update Feed: ",  class: "label",  x: 3, y: i, width: 1,  height: 1  },
            {name:  "#{nsp}.userFeed",       class: "edit",   x: 4, y: i, width: 1,  height: 1,
             text: macro.userFeed or "",      hint: msgs.macroConfig.hints.userFeed             }
        }
        i += 1
    btn, res = aegisub.dialog.display dlg
    return unless btn

    for k, v in pairs res
        nsp, prop = k\match "(.+)%.(.+)"
        if config.c[nsp][prop] and v == ""
            config.c[nsp][prop] = nil
        elseif v != ""
            config.c[nsp][prop] = v

    config\save!

-- A simple yes/no confirmation dialog. Returns true only when the user chooses Yes.
confirmDialog = (message) ->
    btn = aegisub.dialog.display {{class: "label", x: 0, y: 0, width: 1, height: 1, label: message}},
                                 {"Yes", "No"}, {ok: "Yes", cancel: "No"}
    btn == "Yes"

-- our feeds all live under raw.githubusercontent.com; abbreviate that host in the UI and expand it back on input
shortenUrl = (url) -> (url\gsub "^https://raw%.githubusercontent%.com/", "ghuc://")
expandUrl  = (url) -> (url\gsub "^ghuc://", "https://raw.githubusercontent.com/")

-- Add/remove the user's extraFeeds (discovery roots): check feeds to drop and/or type a new one, Apply, re-open.
manageExtraFeeds = (feedTrust) ->
    while true
        feeds = [url for url in *(DepCtrl.config.c.extraFeeds or {})]
        table.sort feeds
        dlg = {}
        if #feeds == 0
            dlg[#dlg + 1] = {class: "label", x: 0, y: 0, width: 3, height: 1, label: "You have no extra feeds."}
        else
            dlg[#dlg + 1] = {class: "label", x: 0, y: 0, width: 3, height: 1, label: "Your extra feeds (discovery roots):"}
            for i, url in ipairs feeds
                dlg[#dlg + 1] = {class: "label",    x: 0, y: i, width: 2, height: 1, label: shortenUrl url}
                dlg[#dlg + 1] = {class: "checkbox", x: 2, y: i, width: 1, height: 1, name: "remove#{i}", label: "Remove", value: false}
        addY = #feeds + 1
        dlg[#dlg + 1] = {class: "label", x: 0, y: addY, width: 1, height: 1, label: "Add feed URL:"}
        dlg[#dlg + 1] = {class: "edit",  x: 1, y: addY, width: 2, height: 1, name: "newFeed", text: "", hint: "full URL or ghuc:// shorthand"}

        btn, res = aegisub.dialog.display dlg, {"Apply", "Close"}, {ok: "Apply", cancel: "Close"}
        break if not btn or btn == "Close"

        for i = 1, #feeds
            feedTrust\removeExtraFeed feeds[i] if res["remove#{i}"]
        newFeed = res.newFeed and res.newFeed\match "^%s*(.-)%s*$"
        feedTrust\addExtraFeed expandUrl(newFeed) if newFeed and #newFeed > 0

-- Add/remove block entries. Official blocks (from DepCtrl's own feed) are read-only; user blocks can be
-- removed. New blocks match by prefix or exact URL, with an optional reason; blocking the bootstrap feed is refused.
manageBlockList = (feedTrust) ->
    BlockMatchMode = DepCtrl.FeedTrust.BlockMatchMode
    while true
        blocks = feedTrust\getBlockedFeeds!
        table.sort blocks, (a, b) -> a.url < b.url
        dlg = {}
        if #blocks == 0
            dlg[#dlg + 1] = {class: "label", x: 0, y: 0, width: 3, height: 1, label: "The block list is currently empty."}
        else
            dlg[#dlg + 1] = {class: "label", x: 0, y: 0, width: 2, height: 1, label: "Blocked feed"}
            dlg[#dlg + 1] = {class: "label", x: 2, y: 0, width: 1, height: 1, label: "Mode"}
            dlg[#dlg + 1] = {class: "label", x: 3, y: 0, width: 2, height: 1, label: "Reason"}
            for i, entry in ipairs blocks
                dlg[#dlg + 1] = {class: "label", x: 0, y: i, width: 2, height: 1, label: shortenUrl entry.url}
                dlg[#dlg + 1] = {class: "label", x: 2, y: i, width: 1, height: 1, label: entry.matchMode}
                dlg[#dlg + 1] = {class: "label", x: 3, y: i, width: 2, height: 1, label: entry.reason or ""}
                if entry.isOfficial
                    dlg[#dlg + 1] = {class: "label", x: 5, y: i, width: 1, height: 1, label: "(official)"}
                else
                    dlg[#dlg + 1] = {class: "checkbox", x: 5, y: i, width: 1, height: 1, name: "remove#{i}", label: "Remove", value: false}
        addY = #blocks + 1
        dlg[#dlg + 1] = {class: "label",    x: 0, y: addY,     width: 1, height: 1, label: "Add block:"}
        dlg[#dlg + 1] = {class: "edit",     x: 1, y: addY,     width: 2, height: 1, name: "newUrl", text: "", hint: "feed URL/prefix, full or ghuc://"}
        dlg[#dlg + 1] = {class: "dropdown", x: 3, y: addY,     width: 1, height: 1, name: "newMode",
                         items: {BlockMatchMode.Prefix, BlockMatchMode.Exact}, value: BlockMatchMode.Prefix}
        dlg[#dlg + 1] = {class: "label",    x: 0, y: addY + 1, width: 1, height: 1, label: "Reason:"}
        dlg[#dlg + 1] = {class: "edit",     x: 1, y: addY + 1, width: 4, height: 1, name: "newReason", text: ""}

        btn, res = aegisub.dialog.display dlg, {"Apply", "Close"}, {ok: "Apply", cancel: "Close"}
        break if not btn or btn == "Close"

        for i, entry in ipairs blocks
            feedTrust\unblock entry.url if not entry.isOfficial and res["remove#{i}"]
        newUrl = res.newUrl and res.newUrl\match "^%s*(.-)%s*$"
        if newUrl and #newUrl > 0
            expanded = expandUrl newUrl
            candidate = {url: expanded, matchMode: res.newMode}
            if DepCtrl.FeedTrust\matchesBlockEntry constants.DEPCTRL_FEED_URL, candidate
                logger\log msgs.manageFeeds.cantBlockBootstrap
            else
                reason = res.newReason and #res.newReason > 0 and res.newReason or nil
                feedTrust\block expanded, {matchMode: res.newMode, :reason}

-- Single source of truth for the Manage Feeds glyphs, shared by the feed-list rendering (`manageFeeds`) and
-- the Help legend (`manageFeedsHelp`). Change a glyph here and both follow.
glyphs = {
    -- OK column (reachability)
    reachable:     "✓"
    unreachable:   "✗"
    unknown:       "?"
    -- Trust column (Harvey balls: official = left half, user = right half, both = full)
    untrusted:     "⭘"
    trustOfficial: "◐"
    trustUser:     "◑"
    trustBoth:     "⬤"
    blocked:       "⊘"
    -- Known column
    ownFeed:       "★"
    officialKnown: "☆"
    transitive:    "≫"
    -- Cust column (your customizations)
    extraFeed:     "E"
    override:      "O"
    -- Pkg column (a package's own feed refs)
    declared:      "D"
    advertised:    "A"
    -- Use column
    inUse:         "↻"
}

-- A read-only reference explaining the feed-list columns and their glyphs, opened from the Help button.
manageFeedsHelp = ->
    sections = {
        {"OK",     "Feed reachability, filled in after Discover: ❬ #{glyphs.reachable} ❭ reachable · ❬ #{glyphs.unreachable} ❭ unreachable · ❬ #{glyphs.unknown} ❭ not checked yet"}
        {"Trust",  "How DependencyControl treats the feed: ❬ #{glyphs.untrusted} ❭ untrusted · ❬ #{glyphs.trustOfficial} ❭ officially trusted · ❬ #{glyphs.trustUser} ❭ user-trusted · ❬ #{glyphs.trustBoth} ❭ official + user · ❬ #{glyphs.blocked} ❭ blocked"}
        {"Known",  "How the feed is known to DependencyControl: ❬ #{glyphs.ownFeed} ❭ its own feed · ❬ #{glyphs.officialKnown} ❭ official (listed in its feed) · ❬ #{glyphs.transitive} ❭ transitive (advertised by another feed) · ❬ #{glyphs.unknown} ❭ not checked yet"}
        {"Cust",   "Your customizations: ❬ #{glyphs.extraFeed} ❭ a feed in your extraFeeds (a discovery root) · ❬ #{glyphs.override} ❭ your per-package feed override"}
        {"Pkg",    "A package's own feed references: ❬ #{glyphs.declared} ❭ declared by an installed package · ❬ #{glyphs.advertised} ❭ advertised by a package's dependency"}
        {"Use",    "Whether the feed is the effective update source of an installed package: ❬ #{glyphs.inUse} ❭ yes"}
        {"Action", "Trust, Block, Unblock, Remove the feed, or open the feed in the DepCtrl Browser for details."}
    }
    dlg = { {class: "label", x: 0, y: 0, width: 4, height: 1, label: "Manage Feeds — what each column means"} }
    for i, s in ipairs sections
        dlg[#dlg + 1] = {class: "label", x: 0, y: i + 1, width: 1, height: 1, label: s[1]}
        dlg[#dlg + 1] = {class: "label", x: 1, y: i + 1, width: 7, height: 1, label: s[2]}
    aegisub.dialog.display dlg, {"Close"}, {ok: "Close", cancel: "Close"}

-- Lets the user see and manage the feeds DependencyControl knows about and their trust status. The reachable
-- feeds are gathered (or crawled) via FeedInventory; FeedManager computes the per-feed actions and executes
-- them through the shared feedTrust. Aegisub's dialog toolkit has no list widget, so this uses the
-- redisplay-loop / row-grid pattern: pick an action per feed, apply, re-open.
manageFeeds = ->
    feedTrust     = DepCtrl.updater.feedTrust
    FeedInventory = DepCtrl.FeedInventory
    FeedManager   = DepCtrl.FeedManager
    FeedAction    = FeedManager.FeedAction
    TrustStatus   = DepCtrl.FeedTrust.TrustStatus
    Provenance    = FeedInventory.Provenance
    openUrl       = require "l0.DependencyControl.helpers.open-url"

    -- The config splits feed lists (under the "config" section that DepCtrl.config points at) from the installed
    -- packages (the top-level "macros"/"modules" sections). FeedInventory/FeedManager expect both under one `.c`,
    -- so present a merged view: package sections by their handler, everything else via the live config.
    macrosKey  = Common.ScriptTypeSection[Common.ScriptType.Automation]
    modulesKey = Common.ScriptTypeSection[Common.ScriptType.Module]
    getSectionData = (key) ->
        view = DepCtrl.config\getSectionHandler key
        view and view.c or {}
    mergedC = setmetatable {[macrosKey]: getSectionData(macrosKey), [modulesKey]: getSectionData(modulesKey)},
                           {__index: DepCtrl.config.c}
    mergedConfig = {c: mergedC}

    inventory = FeedInventory mergedConfig, feedTrust
    manager   = FeedManager   feedTrust

    actionLabels = {
        [FeedAction.Trust]:       "Trust"
        [FeedAction.Block]:       "Block"
        [FeedAction.Unblock]:     "Unblock"
        [FeedAction.Remove]:      "Remove"
        [FeedAction.OpenBrowser]: "Browser"
    }
    actionByLabel = {label, action for action, label in pairs actionLabels}
    trustGlyphs = {
        [TrustStatus.TrustedOfficial]: glyphs.trustOfficial
        [TrustStatus.TrustedUser]:     glyphs.trustUser
        [TrustStatus.TrustedBoth]:     glyphs.trustBoth
        [TrustStatus.Untrusted]:       glyphs.untrusted
        [TrustStatus.Blocked]:         glyphs.blocked
    }
    provenanceLabels = {
        [Provenance.OfficialDepCtrl]:      "DependencyControl's own feed"
        [Provenance.OfficialKnown]:        "known to DependencyControl"
        [Provenance.UserExtra]:            "in your extra feeds"
        [Provenance.PackageDeclared]:      "declared by an installed package"
        [Provenance.PackageOverride]:      "an installed package's feed override"
        [Provenance.DependencyAdvertised]: "advertised by a package dependency"
        [Provenance.TransitiveKnown]:      "advertised by another feed"
    }
    describeProvenance = (row) -> table.concat [provenanceLabels[p] or p for p in *row.provenance], "; "

    -- "Known" folds official and transitive knowledge into one column: DepCtrl's own feed, an officially-known
    -- feed listed in its feed, or a transitively-known feed advertised by another feed (shown only when not
    -- official). Transitive knowledge isn't determined until a Discover has run, so it reads unknown until then.
    getKnownGlyph = (has, row, discovered) ->
        return glyphs.ownFeed if has[Provenance.OfficialDepCtrl]
        return glyphs.officialKnown if has[Provenance.OfficialKnown]
        return glyphs.unknown unless discovered
        has[Provenance.TransitiveKnown] and glyphs.transitive or ""

    -- "Cust" (your customizations: extra feed / override) and "Pkg" (a package's own feed refs: declared /
    -- advertised) groups can co-occur, so each shows letter marks for whichever are present. Every glyph is
    -- called with (has, row, discovered); most use only `has`.
    provColumns = {
        {header: "Know",  glyph: getKnownGlyph}
        {header: "Cust",  glyph: (has) -> (has[Provenance.UserExtra] and glyphs.extraFeed or "") .. (has[Provenance.PackageOverride] and glyphs.override or "")}
        {header: "Pkg",   glyph: (has) -> (has[Provenance.PackageDeclared] and glyphs.declared or "") .. (has[Provenance.DependencyAdvertised] and glyphs.advertised or "")}
        {header: "Use",   glyph: (has, row) -> row.inUse and glyphs.inUse or ""}
    }

    -- prompts for an optional block reason; returns the reason (possibly "") or nil if the user cancels
    promptBlockReason = (url) ->
        btn, res = aegisub.dialog.display {
            {class: "label", x: 0, y: 0, width: 2, height: 1, label: "Reason for blocking #{url} (optional):"}
            {class: "edit",  x: 0, y: 1, width: 2, height: 1, name: "reason", text: ""}
        }, {"Block", "Cancel"}, {ok: "Block", cancel: "Cancel"}
        return nil unless btn == "Block"
        res.reason

    buildDialog = (rows, discovered) ->
        feedCol   = 2                                   -- feed URL sits after the OK (x0) and Trust (x1) columns
        feedWidth = 4
        provStart = feedCol + feedWidth
        actionCol = provStart + #provColumns
        dlg = {
            {class: "label", x: 0,         y: 0, width: 1,         height: 1, label: "OK"}
            {class: "label", x: 1,         y: 0, width: 1,         height: 1, label: "Trust"}
            {class: "label", x: feedCol,   y: 0, width: feedWidth, height: 1, label: "Feed"}
            {class: "label", x: actionCol, y: 0, width: 1,         height: 1, label: "Action"}
        }
        for j, col in ipairs provColumns
            dlg[#dlg + 1] = {class: "label", x: provStart + j - 1, y: 0, width: 1, height: 1, label: col.header}
        for i, row in ipairs rows
            has = {p, true for p in *row.provenance}
            reach = discovered and (row.reachable and glyphs.reachable or glyphs.unreachable) or glyphs.unknown   -- unknown until a Discover has fetched
            items = {"—"}
            items[#items + 1] = actionLabels[a] for a in *row.actions
            dlg[#dlg + 1] = {class: "label", x: 0,       y: i, width: 1,         height: 1, label: reach}
            dlg[#dlg + 1] = {class: "label", x: 1,       y: i, width: 1,         height: 1, label: trustGlyphs[row.trustStatus] or glyphs.unknown}
            dlg[#dlg + 1] = {class: "label", x: feedCol, y: i, width: feedWidth, height: 1, label: shortenUrl row.url}
            for j, col in ipairs provColumns
                dlg[#dlg + 1] = {class: "label", x: provStart + j - 1, y: i, width: 1, height: 1, label: col.glyph(has, row, discovered)}
            dlg[#dlg + 1] = {class: "dropdown", x: actionCol, y: i, width: 1, height: 1, name: "action#{i}",
                             items: items, value: "—", hint: describeProvenance row}
        dlg

    applySelections = (res, rows) ->
        for i, row in ipairs rows
            label = res["action#{i}"]
            continue if not label or label == "—"
            action = actionByLabel[label]
            continue unless action

            if action == FeedAction.OpenBrowser
                ok = openUrl.open row.browserUrl
                logger\log msgs.manageFeeds.openFailed, row.url unless ok
                continue

            if action == FeedAction.Block or action == FeedAction.Remove
                sourced = inventory\getPackagesSourcedFrom row.url
                if #sourced > 0
                    verb = action == FeedAction.Block and "Blocking" or "Removing"
                    message = msgs.manageFeeds.sourcedWarning\format verb, row.url, table.concat(sourced, "\n")
                    continue unless confirmDialog message

            opts = {}
            if action == FeedAction.Block
                reason = promptBlockReason row.url
                continue if reason == nil
                opts.reason = reason if reason != ""

            manager\applyAction action, row, opts

    discovered = false
    while true
        logger\log msgs.manageFeeds.scanning if discovered
        entries = discovered and inventory\crawl! or inventory\gather!
        rows = FeedManager.buildRows entries
        if #rows == 0
            logger\log msgs.manageFeeds.noFeeds
            return
        btn, res = aegisub.dialog.display buildDialog(rows, discovered),
                                          {"Apply", "Discover", "Extra Feeds", "Block List", "Help", "Close"}, {ok: "Apply", cancel: "Close"}
        break if not btn or btn == "Close"
        switch btn
            when "Discover"    then discovered = true
            when "Extra Feeds" then manageExtraFeeds feedTrust
            when "Block List"  then manageBlockList feedTrust
            when "Help"        then manageFeedsHelp!
            else applySelections res, rows

depRec\registerMacros{
    {"Install Script", "Installs an automation script or module on your system.", install},
    {"Update Script", "Manually check and perform updates to any installed script.", update},
    {"Uninstall Script", "Removes an automation script or module from your system.", uninstall},
    {"Manage Feeds", "See and manage the feeds DependencyControl knows about and their trust status.", manageFeeds},
    {"Macro Configuration", "Lets you change per-automation script settings.", macroConfig},
}, "DependencyControl"

-- Force-loads all installed modules, then sweeps the live record registry to schedule
-- periodic update checks for every record and register unit test menus for modules.
-- Automation scripts schedule their own update checks on macro invocation and register
-- their own test menus within their own Aegisub environment.
scheduleUpdatesAndRegisterTests = ->
    config = getConfig!

    for namespace in pairs (config.c.modules or {})
        success, err = pcall require, namespace
        unless success
            logger\trace msgs.scheduleUpdatesAndRegisterTests.moduleLoadFailed, namespace, tostring err

    for _, record in pairs DepCtrl\getAllRegisteredRecords!
        success, errMsgOrErrCode, errDetail = pcall DepCtrl.updater\scheduleUpdate, record
        if not success
            logger\trace msgs.scheduleUpdatesAndRegisterTests.scheduleError, record.name or record.namespace, errMsgOrErrCode
        elseif errMsgOrErrCode < 0
            logger\trace msgs.scheduleUpdatesAndRegisterTests.scheduleError, record.name or record.namespace, 
                DepCtrl.Updater.getUpdaterErrorMsg errMsgOrErrCode, record.name or record.namespace, record.scriptType, false, errDetail
        
        if record.tests and record.scriptType == Common.ScriptType.Module
            success, errMsg = pcall record.tests\registerMacros
            unless success
                logger\trace msgs.scheduleUpdatesAndRegisterTests.registerMacrosError, record.name or record.namespace, errMsg

    DepCtrl.updater\releaseLock!

scheduleUpdatesAndRegisterTests!
