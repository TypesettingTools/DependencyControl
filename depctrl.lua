#!/usr/bin/env luajit
-- DependencyControl CLI toolbox

local ffi      = require "ffi"
local lfs      = require "lfs"
local argparse = require "argparse"
require "moonscript"  -- installs moonscript's package.moonpath loader for .moon files

-- ── Path utilities ────────────────────────────────────────────────────────────

local isWindows = ffi.os == "Windows"
local pathSep   = isWindows and "\\" or "/"

local function dirname(path)
    return (path or ""):match("^(.*)[/\\][^/\\]*$") or "."
end

local function isAbsolute(path)
    return path:match("^%a:[/\\]") ~= nil  -- C:\...
        or path:match("^[/\\]") ~= nil      -- /... or \...
end

local function resolveAbsPath(path)
    if not isAbsolute(path) then
        return lfs.currentdir() .. pathSep .. path
    end
    return path
end

-- ── Argument parsing ──────────────────────────────────────────────────────────

local parser = argparse("depctrl", "DependencyControl CLI toolbox")
    :epilog("See README.md for detailed instructions.")
parser:command_target("command")

-- Selector options shared by all commands: repeat --target-module / --target-macro to pick
-- packages by namespace. With none given, a command operates on every package in the feed.
local function addTargets(cmd)
    cmd:option("--target-module", "Module namespace to operate on (repeatable; default: all)")
        :argname("<ns>"):count("*")
    cmd:option("--target-macro", "Macro namespace to operate on (repeatable; default: all)")
        :argname("<ns>"):count("*")
end

local testCmd = parser:command("test", "Run the unit test suite(s) for packages in a feed")
testCmd:option("-f --feed",       "Feed JSON path"):default("DependencyControl.json")
testCmd:option("-r --report-dir", "Directory for per-package CTRF JSON reports"):default("ctrf")
addTargets(testCmd)

local bundleCmd = parser:command("bundle", "Build a dist/ release bundle and zip archive")
bundleCmd:option("-f --feed",    "Feed JSON path"):default("DependencyControl.json")
bundleCmd:option("-o --out-dir", "Output directory; script files go into its dist/ subfolder"):default(".")
addTargets(bundleCmd)

local deployCmd = parser:command("deploy", "Deploy files directly to an output directory")
deployCmd:option("-f --feed",    "Feed JSON path"):default("DependencyControl.json")
deployCmd:option("-o --out-dir", "Output directory"):default(".")
deployCmd:flag("--clobber",    "Overwrite existing files (default)"):target("clobber")
deployCmd:flag("--no-clobber", "Skip files that already exist at the destination"):target("clobber"):action("store_false")
addTargets(deployCmd)

local updateFeedCmd = parser:command("update-feed",
    "Refresh SHA-1 hashes, version info, and file presence in a feed channel")
updateFeedCmd:option("-f --feed",    "Feed JSON path"):default("DependencyControl.json")
updateFeedCmd:option("-c --channel", "Channel to update (default: the channel marked default: true)")
    :argname("<name>")
updateFeedCmd:flag("-n --dry-run", "Print what would change without writing back")
addTargets(updateFeedCmd)

local args = parser:parse()

-- ── Resolve the launcher directory ───────────────────────────────────────────
-- Made absolute up-front so nothing downstream can be confused by CWD changes.

local launcherDir = dirname(arg and arg[0])
if launcherDir == "." then
    launcherDir = lfs.currentdir()
elseif not isAbsolute(launcherDir) then
    launcherDir = lfs.currentdir() .. pathSep .. launcherDir
end

-- ── Module resolution ─────────────────────────────────────────────────────────
-- The repo's modules/ tree is namespaced (modules/l0/…), so l0.* require paths map
-- straight onto it: moonscript's loader resolves .moon via package.moonpath, the
-- stock searcher the vendored .lua via package.path. No custom searcher needed.

local depCtrlModulesDir = launcherDir .. pathSep .. "modules"
package.path     = ("%s/?.lua;%s/?/init.lua;"):format(depCtrlModulesDir, depCtrlModulesDir) .. package.path
package.moonpath = ("%s/?.moon;%s/?/init.moon;"):format(depCtrlModulesDir, depCtrlModulesDir) .. (package.moonpath or "")

-- ── Aegisub shims ─────────────────────────────────────────────────────────────

local shims   = require "l0.AegisubShims"
local aegisub = shims.aegisub  -- pulled into local scope; global is set by the shim for sub-modules

-- ── Shared: workspace + DepCtrl bootstrap ────────────────────────────────────

local function setupDepCtrl(taskName)
    local tempBase  = shims.getPathToken("temp")
    local workspace = tempBase .. pathSep .. ("depctrl-" .. taskName .. "-%x"):format(os.time() % 0x100000)
    for _, token in ipairs({ "user", "local", "data", "temp" }) do
        shims.setPathToken(token, workspace .. pathSep .. token)
    end

    local FileOps = require "l0.DependencyControl.FileOps"
    FileOps.mkdir("?temp", false, true)
    FileOps.mkdir("?user/log", false, true)

    -- Disable the self-updater so loading DepCtrl does not trigger a network
    -- fetch of its own feed (slow, flaky, pointless outside Aegisub).
    local globalConfigPath = aegisub.decode_path("?user/config/l0.Record.json")
    FileOps.mkdir(globalConfigPath, true, true)
    do
        local json = require "l0.dkjson"
        local h = assert(io.open(globalConfigPath, "w"))
        h:write(json.encode({ config = { updaterEnabled = false } }))
        h:close()
    end

    return require "l0.DependencyControl"
end

-- ── Shared: feed loading, target filtering, source resolution ────────────────

-- Loads and expands a feed (Local mode resolves each file's on-disk source path).
local function loadFeed(feedPath)
    local UpdateFeed = require "l0.DependencyControl.UpdateFeed"
    local feed = UpdateFeed(nil, false, feedPath)
    local ok, err = feed:loadFile(feedPath, UpdateFeed.ExpansionMode.Local)
    if not ok then
        io.stderr:write("Error loading feed '" .. feedPath .. "': " .. tostring(err) .. "\n")
        os.exit(1)
    end
    return feed
end

-- Builds a ScriptTargetFilter from the --target-module/--target-macro selectors. With no
-- selectors it includes everything; otherwise just the named packages, by type.
local function buildFilter(cliArgs)
    local Common = require "l0.DependencyControl.Common"
    local filter = require("l0.DependencyControl.ScriptTargetFilter")()
    local mods, macros = cliArgs.target_module or {}, cliArgs.target_macro or {}
    if #mods == 0 and #macros == 0 then return filter:includeAll() end
    for _, ns in ipairs(mods)   do filter:include(Common.ScriptType.Module, ns)     end
    for _, ns in ipairs(macros) do filter:include(Common.ScriptType.Automation, ns) end
    return filter
end

-- Builds a `requireId -> source path` map from every file in the feed and registers it as a
-- fallback module searcher (after the standard ones), so packages whose source layout isn't
-- namespaced (e.g. a flat repo root) still resolve straight from the checkout. Namespaced
-- repos keep resolving via the stock moonpath/path searchers, which run first.
local function registerFeedSearcher(feed)
    local moonbase = require "moonscript.base"

    -- ".moon" -> "", "/Common.moon" -> ".Common", "/test/Common.moon" -> ".test.Common"
    local function leafSuffix(name)
        return (name:gsub("%.moon$", ""):gsub("%.lua$", ""):gsub("/", "."))
    end

    local sourceById = {}
    for file, _, pkg in feed:walkFiles() do
        local src = file.localFilePath
        if src then
            local base = file.type == "test" and (pkg.namespace .. ".test") or pkg.namespace
            local id = base .. leafSuffix(file.name)
            sourceById[id] = sourceById[id] or src  -- first channel wins; sources are channel-agnostic
        end
    end

    table.insert(package.loaders or package.searchers, function(modName)
        local src = sourceById[modName]
        if not src then return "\n\tno source mapped in feed for '" .. modName .. "'" end
        if src:match("%.moon$") then
            local chunk, err = moonbase.loadfile(src)
            if not chunk then error("error compiling " .. src .. ": " .. tostring(err)) end
            return chunk
        end
        return assert(loadfile(src))
    end)

    return sourceById
end

-- ── Command dispatch ──────────────────────────────────────────────────────────

-- ─── test ─────────────────────────────────────────────────────────────────────
if args.command == "test" then
    -- Resolve every test suite by its source require identifier, "<namespace>.test".
    -- Standard searchers resolve namespaced repos (e.g. DepCtrl's own modules/ tree);
    -- the feed searcher registered below catches non-namespaced ones. Set before any
    -- package is required, since requiring a managed module triggers test registration.
    DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER = function(scriptType, namespace)
        return namespace .. ".test"
    end

    setupDepCtrl("tests")
    local FileOps = require "l0.DependencyControl.FileOps"

    local feedPath = resolveAbsPath(args.feed)
    local feed     = loadFeed(feedPath)

    local selected = {}
    for pkg, scriptType in feed:walkPackages(buildFilter(args)) do
        selected[#selected + 1] = { namespace = pkg.namespace, scriptType = scriptType }
    end
    table.sort(selected, function(a, b) return a.namespace < b.namespace end)
    if #selected == 0 then
        io.stderr:write("No packages matched in feed '" .. feedPath .. "'.\n")
        os.exit(1)
    end
    registerFeedSearcher(feed)

    local reportDir = resolveAbsPath(args.report_dir)
    local ran, skipped, failed = 0, 0, 0

    for _, pkg in ipairs(selected) do
        local ns = pkg.namespace
        local okRequire, mod = pcall(require, ns)
        local record = okRequire and type(mod) == "table" and mod.version or nil

        if not okRequire then
            io.stderr:write(("! %s: failed to load (%s)\n"):format(ns, tostring(mod)))
            failed = failed + 1
        elseif not (record and record.__class and record.__class.__name == "DependencyControl") then
            io.stderr:write(("~ %s: not a DependencyControl-managed package, skipping\n"):format(ns))
            skipped = skipped + 1
        elseif record.haveTestSuite == false then
            io.stderr:write(("~ %s: no test suite found (%s), skipping\n"):format(ns, tostring(record.testSuiteLoadError)))
            skipped = skipped + 1
        elseif not record.testSuiteInitialized then
            io.stderr:write(("! %s: test suite failed to initialize (%s)\n"):format(ns, tostring(record.testSuiteInitializeError)))
            failed = failed + 1
        else
            io.stdout:write(("\n=== Testing %s ===\n"):format(ns))
            local success = record.tests:run()
            ran = ran + 1
            if not success then failed = failed + 1 end

            local reportPath = FileOps.joinPath(reportDir, ns .. ".json")
            local wrote, writeErr = record.tests:writeResults(reportPath)
            io.stderr:write(wrote and ("Wrote CTRF report to " .. reportPath .. "\n")
                or ("Warning: couldn't write CTRF report for " .. ns .. ": " .. tostring(writeErr) .. "\n"))
        end
    end

    io.stdout:write(("\n%d package(s) tested, %d skipped, %d failed.\n"):format(ran, skipped, failed))
    os.exit(failed > 0 and 1 or 0)

-- ─── bundle ───────────────────────────────────────────────────────────────────
elseif args.command == "bundle" then
    local feedPath  = resolveAbsPath(args.feed)
    local outputDir = resolveAbsPath(args.out_dir)

    setupDepCtrl("bundle")

    local FileOps       = require "l0.DependencyControl.FileOps"
    local ZipArchiver   = require "l0.DependencyControl.ZipArchiver"
    local GitRepository = require "l0.DependencyControl.GitRepository"

    local feed   = loadFeed(feedPath)
    local filter = buildFilter(args)

    local distDir = outputDir .. pathSep .. "dist"
    FileOps.remove(distDir, true)
    FileOps.mkdir(distDir, false, true)

    local fileCount, errCount = feed:deployFiles(distDir, filter, false)

    -- Name the archive after the feed's headline module (DepCtrl's own feed) where present,
    -- otherwise fall back to the first module version so other feeds still bundle.
    local mainVersion = feed:getModuleVersion("l0.DependencyControl")
    if not mainVersion then
        for ns in pairs(feed.data.modules or {}) do
            mainVersion = feed:getModuleVersion(ns)
            if mainVersion then break end
        end
        mainVersion = mainVersion or "0.0.0"
    end

    local suffix  = GitRepository(feed.feedDir):getVersionSuffix()
    local zipPath = outputDir .. pathSep .. (feed.data.name .. "-v%s%s.zip"):format(mainVersion, suffix)

    local zipOk = false
    if fileCount > 0 then
        local success, archiveErr = ZipArchiver(zipPath):addDirectory(distDir):write()
        if success then
            zipOk = true
        else
            io.stderr:write("Warning: archive creation failed: " .. tostring(archiveErr) .. "\n")
        end
    end

    local status = fileCount > 0 and "Bundle complete" or "Bundle produced no files"
    io.stdout:write(("\n%s: %d file(s) in %s, %d error(s)\n"):format(status, fileCount, distDir, errCount))
    if zipOk then io.stdout:write(("Archive: %s\n"):format(zipPath)) end
    os.exit(errCount > 0 and 1 or 0)

-- ─── deploy ───────────────────────────────────────────────────────────────────
elseif args.command == "deploy" then
    local feedPath  = resolveAbsPath(args.feed)
    local outputDir = resolveAbsPath(args.out_dir)
    local clobber   = args.clobber == true

    setupDepCtrl("deploy")

    local feed   = loadFeed(feedPath)
    local filter = buildFilter(args)

    local fileCount, errCount = feed:deployFiles(outputDir, filter, clobber)

    local status = fileCount > 0 and "Deploy complete" or "Deploy produced no files"
    io.stdout:write(("\n%s: %d file(s) deployed to %s, %d error(s)\n"):format(status, fileCount, outputDir, errCount))
    os.exit(errCount > 0 and 1 or 0)

-- ─── update-feed ──────────────────────────────────────────────────────────────
elseif args.command == "update-feed" then
    local feedPath = resolveAbsPath(args.feed)

    setupDepCtrl("update-feed")

    local UpdateFeed = require "l0.DependencyControl.UpdateFeed"
    local feed = UpdateFeed(nil, false, feedPath)

    registerFeedSearcher(feed)

    local stats, err = feed:updateFeed({
        channel   = args.channel,
        filter    = buildFilter(args),
        schemaDir = table.concat({ launcherDir, "schemas", "feed" }, pathSep),
        outPath   = args.dry_run and false or nil,
    })

    if not stats then
        io.stderr:write("Error updating feed: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    -- Per-package breakdown: one status line per package, with any errors indented beneath it.
    local changedWord = args.dry_run and "would change" or "updated"
    for _, pkg in ipairs(stats.packages) do
        local label = pkg.namespace .. (pkg.channel and (" (" .. pkg.channel .. ")") or "")
        local status
        if #pkg.errors > 0 then
            status = ("%d error%s"):format(#pkg.errors, #pkg.errors == 1 and "" or "s")
        elseif pkg.changed then
            status = changedWord
        else
            status = "no changes"
        end
        io.stdout:write(("  %-48s %s\n"):format(label, status))
        for _, e in ipairs(pkg.errors) do
            io.stderr:write("      ! " .. (tostring(e):gsub("\n", "\n        ")) .. "\n")
        end
    end

    -- Summary
    local total = #stats.packages
    if stats.changed > 0 then
        local verb = args.dry_run and "would change — dry run, nothing written" or ("updated in " .. feedPath)
        io.stdout:write(("\n%d of %d package(s) %s\n"):format(stats.changed, total, verb))
    else
        io.stdout:write("\nFeed is already up to date.\n")
    end
    if stats.errored > 0 then
        io.stdout:write(("%d package(s) had errors (see above).\n"):format(stats.errored))
    end
    os.exit(stats.errored > 0 and 1 or 0)
end
