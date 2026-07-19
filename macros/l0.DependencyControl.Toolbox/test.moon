UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
constants = require "l0.DependencyControl.Constants"
Common = require "l0.DependencyControl.Common"
DepCtrl = require "l0.DependencyControl"

-- Suite for the DependencyControl Toolbox macro. The Plumbing class proves the automation-script test
-- wiring (DependencyControl discovers the suite and hands it the script's registered macros + testExports);
-- the Urls/Age/InstalledList/UntrustedPrompt classes cover the pure and near-pure helpers; the remaining
-- classes drive the dialog flows end to end, stubbing aegisub.dialog.display and the Toolbox's collaborators
-- (the updater, config handler, feed inventory/manager, and the injected feed trust model).
UnitTestSuite "l0.DependencyControl.Toolbox", (macros, dependencies, testExports, controls) ->
  {:shortenUrl, :expandUrl, :formatAge, :buildInstalledDlgList, :promptUntrustedFeed,
    :confirmDialog, :manageExtraFeeds, :manageBlockList, :buttons, :feedActionLabels,
    :scheduleUpdatesAndRegisterTests} = testExports

  -- The UninstallFlow seam: its _setup swaps the DepCtrl class's __call for a constructor returning
  -- `uninstallSeam.record`, so the flow's `DepCtrl(script)\uninstall!` never builds (and registers) a real
  -- record. Held at suite scope because tests don't receive their class's setup context.
  uninstallSeam = {}

  -- a fake config the way buildInstalledDlgList reads it: config.c[section] is the installed-package map
  makeConfig = (section, entries) -> {c: {[section]: entries}}
  -- the set of script display names present in a buildInstalledDlgList map
  namesIn = (map) -> {v.name, true for _, v in pairs map}

  -- Stub aegisub.dialog.display to return a queued sequence of results, one per call: each entry is a
  -- {button, values} pair (or {false} to model a cancel). Exhausting the queue returns nil, which the
  -- redisplay loops read as "close". Returns the stub for call assertions.
  queueDialog = (ut, responses) ->
    i = 0
    ut\stub(aegisub.dialog, "display")\calls (...) ->
      i += 1
      r = responses[i] or {}
      unpack r, 1, #r

  -- Runs one Uninstall Script pass selecting "X v1.0.0", with the constructed record's uninstall returning
  -- the given values; returns how often uninstall ran. Requires the UninstallFlow construction seam.
  runUninstall = (ut, ...) ->
    results = table.pack ...
    ran = 0
    uninstallSeam.record = {
      uninstall: =>
        ran += 1
        unpack results, 1, results.n
    }
    ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {macros: {"a.x": {name: "X", version: "1.0.0"}}, modules: {}}}
    queueDialog ut, {{"OK", {macro: "X v1.0.0", module: ""}}}
    macros["Uninstall Script"].process!
    ran

  -- a fake FeedTrust recording the mutations the trust panels delegate to it; getBlockedFeeds hands back a
  -- fresh copy each call so a panel's in-place sort can't corrupt the source list across redisplay cycles
  makeFeedTrust = (blocked) ->
    calls = {block: {}, unblock: {}, trust: {}, addExtraFeed: {}, removeExtraFeed: {}}
    {
      :calls
      getBlockedFeeds: => [b for b in *(blocked or {})]
      block: (url, opts) => calls.block[#calls.block + 1] = {url, opts}
      unblock: (url) => calls.unblock[#calls.unblock + 1] = url
      trust: (url) => calls.trust[#calls.trust + 1] = url
      addExtraFeed: (url) => calls.addExtraFeed[#calls.addExtraFeed + 1] = url
      removeExtraFeed: (url) => calls.removeExtraFeed[#calls.removeExtraFeed + 1] = url
    }

  -- a minimal fake UpdateFeed exposing one installable automation script, enough for install discovery
  makeFakeFeed = ->
    scriptData = {
      name: "X"
      data: {channels: {main: {version: "1.0.0"}}}
      getChannels: => {"main"}, "main"
    }
    {
      url: "feed://x"
      data: {macros: {"a.x": true}, modules: {}}
      getScript: (ns, st) => scriptData, nil
    }

  {
    Plumbing: {
      _description: "Automation-script test wiring: registered macros and testExports reach the suite."

      -- every macro registered through registerMacros is exposed by name, carrying its unhooked process
      receivesRegisteredMacros: (ut) ->
        for name in *{"Install Script", "Update Script", "Uninstall Script", "Manage Feeds", "Macro Configuration"}
          ut\assertNotNil macros[name]
          ut\assertFunction macros[name].process

      -- the script's own internal helpers, passed straight through as testExports
      receivesTestExports: (ut) ->
        ut\assertNotNil testExports
        ut\assertFunction testExports.shortenUrl
        ut\assertFunction testExports.expandUrl
    }

    Urls: {
      _description: "shortenUrl/expandUrl: raw.githubusercontent.com <-> ghuc:// abbreviation."

      -- the raw.githubusercontent.com host collapses to the ghuc:// scheme
      shorten_abbreviatesHost: (ut) ->
        ut\assertEquals shortenUrl("https://raw.githubusercontent.com/TT/DepCtrl/master/x.json"),
          "ghuc://TT/DepCtrl/master/x.json"

      -- a URL on any other host is left untouched
      shorten_passesThroughOther: (ut) ->
        ut\assertEquals shortenUrl("https://example.com/feed.json"), "https://example.com/feed.json"

      -- ghuc:// expands back to the full raw.githubusercontent.com URL
      expand_restoresHost: (ut) ->
        ut\assertEquals expandUrl("ghuc://TT/DepCtrl/master/x.json"),
          "https://raw.githubusercontent.com/TT/DepCtrl/master/x.json"

      -- shorten then expand round-trips a raw.githubusercontent.com URL unchanged
      roundTrips: (ut) ->
        url = "https://raw.githubusercontent.com/TT/DepCtrl/master/x.json"
        ut\assertEquals expandUrl(shortenUrl url), url

      _order: {"shorten_abbreviatesHost", "shorten_passesThroughOther", "expand_restoresHost", "roundTrips"}
    }

    Age: {
      _description: "formatAge: compact 'time since' label for a feed's last-fetch timestamp."

      -- an absent timestamp (never fetched) renders as an em dash
      never_isDash: (ut) -> ut\assertEquals formatAge(nil), "—"

      -- under a minute reads as 'now'; larger spans round down into the coarsest unit that fits
      picksCoarsestUnit: (ut) ->
        now = os.time!
        ut\assertEquals formatAge(now), "now"
        ut\assertEquals formatAge(now - 120), "2m"
        ut\assertEquals formatAge(now - 7200), "2h"
        ut\assertEquals formatAge(now - 172800), "2d"
        ut\assertEquals formatAge(now - 1209600), "2w"
    }

    InstalledList: {
      _description: "buildInstalledDlgList: installed-package picker rows, with the uninstall protected-module guard."

      -- uninstall must not offer DependencyControl's own stack (its namespace is protected)
      uninstall_excludesProtected: (ut) ->
        config = makeConfig "modules", {
          [constants.DEPCTRL_NAMESPACE]: {name: "DepCtrl", version: "0.7.0"}
          "l0.Other": {name: "Other", version: "1.2.3"}
        }
        list, map = buildInstalledDlgList "modules", config, true
        names = namesIn map
        ut\assertNil names["DepCtrl"] -- protected on uninstall
        ut\assertTrue names["Other"]
        ut\assertEquals #list, 1

      -- install/update (not an uninstall) protects nothing, so every installed package is offered
      install_includesAll: (ut) ->
        config = makeConfig "modules", {
          [constants.DEPCTRL_NAMESPACE]: {name: "DepCtrl", version: "0.7.0"}
          "l0.Other": {name: "Other", version: "1.2.3"}
        }
        list, map = buildInstalledDlgList "modules", config, false
        names = namesIn map
        ut\assertTrue names["DepCtrl"]
        ut\assertTrue names["Other"]
        ut\assertEquals #list, 2

      -- rows are sorted case-insensitively by display name
      sortsByNameCaseInsensitively: (ut) ->
        config = makeConfig "macros", {
          "a.z": {name: "Zebra", version: "1.0.0"}
          "a.a": {name: "apple", version: "1.0.0"}
          "a.m": {name: "Mango", version: "1.0.0"}
        }
        list = buildInstalledDlgList "macros", config, false
        ut\assertEquals list, {"apple v1.0.0", "Mango v1.0.0", "Zebra v1.0.0"}

      -- a package with a non-default active channel shows the channel in brackets
      formatsActiveChannel: (ut) ->
        config = makeConfig "macros", {"a.x": {name: "X", version: "2.0.0", activeChannel: "beta"}}
        list = buildInstalledDlgList "macros", config, false
        ut\assertEquals list[1], "X v2.0.0 [beta]"

      -- an entry lacking name/version (e.g. an orphaned unmanaged record) still gets a row
      toleratesMissingVersionAndName: (ut) ->
        config = makeConfig "modules", {"a.orphan": {}}
        list = buildInstalledDlgList "modules", config, false
        ut\assertEquals list[1], "a.orphan v0.0.0"

      _order: {"uninstall_excludesProtected", "install_includesAll", "sortsByNameCaseInsensitively", "formatsActiveChannel", "toleratesMissingVersionAndName"}
    }

    UntrustedPrompt: {
      _description: "promptUntrustedFeed: maps the untrusted-feed dialog choice to a fetch decision + trust side effect."

      -- Trust: remembers the feed and fetches it
      trust_remembersAndFetches: (ut) ->
        ft = makeFeedTrust!
        ut\stub(aegisub.dialog, "display")\calls -> buttons.trust
        ut\assertTrue promptUntrustedFeed "feed://x", ft
        ut\assertEquals ft.calls.trust, {"feed://x"}
        ut\assertEquals #ft.calls.block, 0

      -- Fetch once: fetches without remembering
      fetchOnce_fetchesWithoutTrusting: (ut) ->
        ft = makeFeedTrust!
        ut\stub(aegisub.dialog, "display")\calls -> buttons.fetchOnce
        ut\assertTrue promptUntrustedFeed "feed://x", ft
        ut\assertEquals #ft.calls.trust, 0
        ut\assertEquals #ft.calls.block, 0

      -- Block: blocks the feed and refuses the fetch
      block_blocksAndRefuses: (ut) ->
        ft = makeFeedTrust!
        ut\stub(aegisub.dialog, "display")\calls -> buttons.block
        ut\assertFalse promptUntrustedFeed "feed://x", ft
        ut\assertEquals ft.calls.block[1][1], "feed://x"
        ut\assertEquals #ft.calls.trust, 0

      -- Skip (and dialog cancel): refuses the fetch, changing no trust state
      skip_refusesQuietly: (ut) ->
        ft = makeFeedTrust!
        ut\stub(aegisub.dialog, "display")\calls -> buttons.skip
        ut\assertFalse promptUntrustedFeed "feed://x", ft
        ut\assertEquals #ft.calls.trust, 0
        ut\assertEquals #ft.calls.block, 0

      _order: {"trust_remembersAndFetches", "fetchOnce_fetchesWithoutTrusting", "block_blocksAndRefuses", "skip_refusesQuietly"}
    }

    Confirm: {
      _description: "confirmDialog: a yes/no gate that is true only on Yes."

      yes_isTrue: (ut) ->
        ut\stub(aegisub.dialog, "display")\calls -> buttons.yes
        ut\assertTrue confirmDialog "proceed?"

      no_isFalse: (ut) ->
        ut\stub(aegisub.dialog, "display")\calls -> buttons.no
        ut\assertFalse confirmDialog "proceed?"

      _order: {"yes_isTrue", "no_isFalse"}
    }

    BlockList: {
      _description: "manageBlockList: the block-list panel — remove user blocks, add a block, refuse blocking the bootstrap feed."

      -- Close on the first display makes no changes
      close_makesNoChanges: (ut) ->
        ft = makeFeedTrust {{url: "feed://x", isOfficial: false, matchMode: DepCtrl.FeedTrust.BlockMatchMode.Prefix}}
        queueDialog ut, {{buttons.close}}
        manageBlockList ft
        ut\assertEquals #ft.calls.unblock, 0
        ut\assertEquals #ft.calls.block, 0

      -- a checked user block is unblocked; a checked official block is left alone (it has no remove control)
      removesUserBlockNotOfficial: (ut) ->
        ft = makeFeedTrust {
          {url: "feed://official", isOfficial: true, matchMode: DepCtrl.FeedTrust.BlockMatchMode.Prefix}
          {url: "feed://user", isOfficial: false, matchMode: DepCtrl.FeedTrust.BlockMatchMode.Prefix}
        }
        -- sorted by URL: [feed://official, feed://user] -> remove1 targets the official (ignored), remove2 the user
        queueDialog ut, {{buttons.apply, {remove1: true, remove2: true}}, {buttons.close}}
        manageBlockList ft
        ut\assertEquals ft.calls.unblock, {"feed://user"}

      -- a typed URL is added as a block carrying the chosen mode and reason
      addsBlockWithReason: (ut) ->
        ft = makeFeedTrust {}
        queueDialog ut, {
          {buttons.apply, {newUrl: "ghuc://bad/feed", newMode: DepCtrl.FeedTrust.BlockMatchMode.Exact, newReason: "malware"}}
          {buttons.close}
        }
        manageBlockList ft
        ut\assertEquals ft.calls.block[1][1], "https://raw.githubusercontent.com/bad/feed"
        ut\assertEquals ft.calls.block[1][2].matchMode, DepCtrl.FeedTrust.BlockMatchMode.Exact
        ut\assertEquals ft.calls.block[1][2].reason, "malware"

      -- blocking DependencyControl's own bootstrap feed is refused (it would collapse the trust root)
      refusesBootstrapBlock: (ut) ->
        ft = makeFeedTrust {}
        queueDialog ut, {
          {buttons.apply, {newUrl: constants.DEPCTRL_FEED_URL, newMode: DepCtrl.FeedTrust.BlockMatchMode.Exact}}
          {buttons.close}
        }
        manageBlockList ft
        ut\assertEquals #ft.calls.block, 0

      _order: {"close_makesNoChanges", "removesUserBlockNotOfficial", "addsBlockWithReason", "refusesBootstrapBlock"}
    }

    ExtraFeeds: {
      _description: "manageExtraFeeds: the discovery-roots panel — add a typed feed (expanding ghuc://), close cleanly."

      close_makesNoChanges: (ut) ->
        ft = makeFeedTrust!
        queueDialog ut, {{buttons.close}}
        manageExtraFeeds ft
        ut\assertEquals #ft.calls.addExtraFeed, 0
        ut\assertEquals #ft.calls.removeExtraFeed, 0

      -- a typed ghuc:// shorthand is trimmed and expanded before being added as a discovery root
      addsTypedFeedExpanded: (ut) ->
        ft = makeFeedTrust!
        queueDialog ut, {{buttons.apply, {newFeed: "  ghuc://x/y  "}}, {buttons.close}}
        manageExtraFeeds ft
        ut\assertEquals ft.calls.addExtraFeed, {"https://raw.githubusercontent.com/x/y"}
        ut\assertEquals #ft.calls.removeExtraFeed, 0

      _order: {"close_makesNoChanges", "addsTypedFeedExpanded"}
    }

    Update: {
      _description: "Update Script: picks installed packages and runs update tasks for the selection."

      -- cancelling the picker runs no update task
      cancel_runsNoTask: (ut) ->
        ran = {}
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {macros: {"a.x": {name: "X", version: "1.0.0"}}, modules: {}}}
        ut\stub(DepCtrl.updater, "addTask")\calls (self, sd) -> ran[#ran + 1] = sd
        queueDialog ut, {{false}}
        macros["Update Script"].process!
        ut\assertEquals #ran, 0

      -- selecting a macro runs an update task for exactly that package
      selectsMacro_runsItsTask: (ut) ->
        macroEntry = {name: "X", version: "1.0.0"}
        ran = {}
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {macros: {"a.x": macroEntry}, modules: {}}}
        ut\stub(DepCtrl.updater, "addTask")\calls (self, sd) ->
          ran[#ran + 1] = sd
          {run: => true}
        queueDialog ut, {{"OK", {macro: "X v1.0.0", module: ""}}}
        macros["Update Script"].process!
        ut\assertEquals #ran, 1
        ut\assertEquals ran[1], macroEntry
    }

    Uninstall: {
      _description: "Uninstall Script: builds the (protected-guarded) installed list and cancels cleanly."

      -- cancelling the picker uninstalls nothing (and never constructs a record to uninstall)
      cancel_uninstallsNothing: (ut) ->
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {macros: {"a.x": {name: "X", version: "1.0.0"}}, modules: {}}}
        dlg = queueDialog ut, {{false}}
        macros["Uninstall Script"].process!
        dlg\assertCalledOnce!
    }

    UninstallFlow: {
      _description: "Uninstall Script: a picker selection reaches PackageRecord uninstall, and every result shape is reported without erroring."

      -- A Stub can't stand in for a metamethod (LuaJIT requires __call to be a plain function), so the
      -- construction seam is swapped by hand and restored in the teardown, which runs even when a test fails.
      _setup: (ut) ->
        meta = getmetatable DepCtrl
        uninstallSeam.original = meta.__call
        meta.__call = (cls, script) -> uninstallSeam.record

      _teardown: (ut) ->
        (getmetatable DepCtrl).__call = uninstallSeam.original

      success_reportsAndRuns: (ut) ->
        ut\assertEquals runUninstall(ut, true, {}), 1

      errorWithStringDetail_reported: (ut) ->
        ut\assertEquals runUninstall(ut, nil, "record construction failed"), 1

      errorWithFileTableDetail_formatted: (ut) ->
        ut\assertEquals runUninstall(ut, nil, {["auto/x.moon"]: {nil, "access denied"}}), 1

      lockedFiles_formatted: (ut) ->
        ut\assertEquals runUninstall(ut, false, {["auto/x.moon"]: {false, "file in use"}}), 1

      _order: {"success_reportsAndRuns", "errorWithStringDetail_reported",
        "errorWithFileTableDetail_formatted", "lockedFiles_formatted"}
    }

    Install: {
      _description: "Install Script: crawls feeds for installable packages and runs install tasks for the selection."

      -- an unreachable (unfetched) feed contributes nothing; cancelling installs nothing
      skipsUnfetchedAndCancels: (ut) ->
        ran = {}
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {macros: {}, modules: {}}}
        crawl = ut\stub(DepCtrl.FeedInventory.__base, "crawl")\calls -> {{url: "feed://x", fetched: false}}
        ut\stub(DepCtrl.updater, "addTask")\calls (self, sd) -> ran[#ran + 1] = sd
        queueDialog ut, {{false}}
        macros["Install Script"].process!
        crawl\assertCalled!
        ut\assertEquals #ran, 0

      -- a fetched feed's available script is offered, and selecting it runs an install task for it
      selectsAvailableScript: (ut) ->
        ran = {}
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {macros: {}, modules: {}}}
        ut\stub(DepCtrl.FeedInventory.__base, "crawl")\calls -> {{url: "feed://x", fetched: true}}
        ut\stub(DepCtrl.FeedLoader.__base, "load")\calls -> makeFakeFeed!
        ut\stub(DepCtrl.updater, "addTask")\calls (self, sd) ->
          ran[#ran + 1] = sd
          {run: => true}
        queueDialog ut, {{"OK", {macro: "X v1.0.0", module: ""}}}
        macros["Install Script"].process!
        ut\assertEquals #ran, 1
        ut\assertEquals ran[1].namespace, "a.x"
        ut\assertEquals ran[1].feed, "feed://x"

      _order: {"skipsUnfetchedAndCancels", "selectsAvailableScript"}
    }

    MacroConfig: {
      _description: "Macro Configuration: writes non-empty edits into the per-macro config and saves."

      appliesEditsAndSaves: (ut) ->
        saved = {}
        cfg = {
          userConfig: {"a.x": {name: "X"}}
          c: {"a.x": {}}
          save: => saved.yes = true
        }
        ut\stub(DepCtrl.config, "getSectionHandler")\returns cfg
        dlg = queueDialog ut, {{"OK", {"a.x.customMenu": "Tools/Mine", "a.x.userFeed": ""}}}
        macros["Macro Configuration"].process!
        ut\assertEquals cfg.c["a.x"].customMenu, "Tools/Mine" -- non-empty edit written
        ut\assertNil cfg.c["a.x"].userFeed -- empty edit left unset
        ut\assertTrue saved.yes
        -- the built dialog is a gap-free array whose first row sits at y=0 (no wasted leading row)
        built = dlg._calls[1][1]
        ut\assertNotNil built[1]
        ut\assertEquals built[1].y, 0
    }

    ManageFeeds: {
      _description: "Manage Feeds: the redisplay loop dispatches Apply to feed actions and Discover to the crawl."

      -- The offline gather consults the live trust singleton, whose official-set load fetches the DepCtrl
      -- feed over the network on a cold cache; seed both accessors so no test run leaves the process.
      _setup: (ut) ->
        ut\stub(DepCtrl.updater.feedTrust, "getOfficialTrustedFeeds")\returns {}
        ut\stub(DepCtrl.updater.feedTrust, "getOfficialBlockedFeeds")\returns {}

      -- Close on the first render applies no feed action
      close_appliesNothing: (ut) ->
        rows = {{url: "feed://x", provenance: {}, trustStatus: DepCtrl.FeedTrust.TrustStatus.Untrusted, actions: {}, browserUrl: "http://b"}}
        ut\stub(DepCtrl.FeedManager, "buildRows")\calls -> rows
        applyAction = ut\stub DepCtrl.FeedManager.__base, "applyAction"
        queueDialog ut, {{buttons.close}}
        macros["Manage Feeds"].process!
        applyAction\assertNotCalled!

      -- Apply dispatches each row's chosen action to the feed manager
      apply_dispatchesSelectedAction: (ut) ->
        Trust = DepCtrl.FeedManager.FeedAction.Trust
        row = {url: "feed://x", provenance: {}, trustStatus: DepCtrl.FeedTrust.TrustStatus.Untrusted, actions: {Trust}, browserUrl: "http://b"}
        applied = {}
        ut\stub(DepCtrl.FeedManager, "buildRows")\calls -> {row}
        ut\stub(DepCtrl.FeedManager.__base, "applyAction")\calls (self, action, entry) ->
          applied[#applied + 1] = {action, entry}
          true
        queueDialog ut, {{buttons.apply, {action1: feedActionLabels[Trust]}}, {buttons.close}}
        macros["Manage Feeds"].process!
        ut\assertEquals #applied, 1
        ut\assertEquals applied[1][1], Trust
        ut\assertEquals applied[1][2], row

      -- Fetch/Discover switches the list source from the offline gather to the (here stubbed) network crawl
      discover_usesCrawl: (ut) ->
        rows = {{url: "feed://x", provenance: {}, trustStatus: DepCtrl.FeedTrust.TrustStatus.Untrusted, actions: {}, browserUrl: "http://b"}}
        ut\stub(DepCtrl.FeedManager, "buildRows")\calls -> rows
        crawl = ut\stub(DepCtrl.FeedInventory.__base, "crawl")\calls -> {}
        queueDialog ut, {{buttons.discover}, {buttons.close}}
        macros["Manage Feeds"].process!
        crawl\assertCalled!

      -- Block asks for a reason before dispatching, and the reason travels in the action options
      apply_blockPromptsForReason: (ut) ->
        Block = DepCtrl.FeedManager.FeedAction.Block
        row = {url: "feed://x", provenance: {}, trustStatus: DepCtrl.FeedTrust.TrustStatus.Untrusted, actions: {Block}, browserUrl: "http://b"}
        applied = {}
        ut\stub(DepCtrl.FeedManager, "buildRows")\calls -> {row}
        ut\stub(DepCtrl.FeedManager.__base, "applyAction")\calls (self, action, entry, opts) ->
          applied[#applied + 1] = {action, entry, opts}
          true
        ut\stub(DepCtrl.FeedInventory.__base, "getPackagesSourcedFrom")\returns {}
        queueDialog ut, {
          {buttons.apply, {action1: feedActionLabels[Block]}}
          {buttons.block, {reason: "compromised"}}
          {buttons.close}
        }
        macros["Manage Feeds"].process!
        ut\assertEquals #applied, 1
        ut\assertEquals applied[1][1], Block
        ut\assertEquals applied[1][3].reason, "compromised"

      -- declining the sourced-packages warning abandons the block before any prompt or dispatch
      apply_blockDeclinedOnSourcedWarning: (ut) ->
        Block = DepCtrl.FeedManager.FeedAction.Block
        row = {url: "feed://x", provenance: {}, trustStatus: DepCtrl.FeedTrust.TrustStatus.Untrusted, actions: {Block}, browserUrl: "http://b"}
        ut\stub(DepCtrl.FeedManager, "buildRows")\calls -> {row}
        applyAction = ut\stub DepCtrl.FeedManager.__base, "applyAction"
        ut\stub(DepCtrl.FeedInventory.__base, "getPackagesSourcedFrom")\returns {"a.pkg"}
        queueDialog ut, {
          {buttons.apply, {action1: feedActionLabels[Block]}}
          {false} -- the sourced warning, declined
          {buttons.close}
        }
        macros["Manage Feeds"].process!
        applyAction\assertNotCalled!

      _order: {"close_appliesNothing", "apply_dispatchesSelectedAction", "discover_usesCrawl",
        "apply_blockPromptsForReason", "apply_blockDeclinedOnSourcedWarning"}
    }

    StartupSweep: {
      _description: "scheduleUpdatesAndRegisterTests: the startup sweep schedules every record, registers module test menus, and survives per-record failures."

      -- every registered record gets a schedule attempt, module suites get their test menus registered
      -- (automation scripts register their own), an installed module that fails to load is tolerated,
      -- and the updater lock is released at the end
      sweepsRecordsAndRegistersModuleTests: (ut) ->
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {modules: {"toolbox.test.notARealModule": {}}}}
        registered = {}
        records = {
          {name: "Mod", namespace: "a.mod", scriptType: Common.ScriptType.Module, tests: {registerMacros: => registered.mdl = true}}
          {name: "Mac", namespace: "a.mac", scriptType: Common.ScriptType.Automation, tests: {registerMacros: => registered.macro = true}}
        }
        ut\stub(DepCtrl, "getAllRegisteredRecords")\returns records
        scheduled = {}
        ut\stub(DepCtrl.updater, "scheduleUpdate")\calls (self, record) ->
          scheduled[#scheduled + 1] = record.namespace
          0
        released = ut\stub DepCtrl.updater, "releaseLock"
        scheduleUpdatesAndRegisterTests!
        ut\assertEquals #scheduled, 2
        ut\assertTrue registered.mdl -- module suites are registered by the sweep
        ut\assertNil registered.macro -- automation scripts register their own
        released\assertCalledOnce!

      -- one record's raising scheduleUpdate (or a negative status) doesn't end the sweep for the rest
      toleratesPerRecordFailures: (ut) ->
        ut\stub(DepCtrl.config, "getSectionHandler")\returns {c: {modules: {}}}
        records = {
          {name: "Boom", namespace: "a.boom", scriptType: Common.ScriptType.Module}
          {name: "Denied", namespace: "a.denied", scriptType: Common.ScriptType.Module}
          {name: "Fine", namespace: "a.fine", scriptType: Common.ScriptType.Automation}
        }
        ut\stub(DepCtrl, "getAllRegisteredRecords")\returns records
        calls = 0
        ut\stub(DepCtrl.updater, "scheduleUpdate")\calls (self, record) ->
          calls += 1
          error "scheduler exploded" if record.name == "Boom"
          record.name == "Denied" and -1 or 0
        ut\stub DepCtrl.updater, "releaseLock"
        scheduleUpdatesAndRegisterTests!
        ut\assertEquals calls, 3

      _order: {"sweepsRecordsAndRegistersModuleTests", "toleratesPerRecordFailures"}
    }
  }
