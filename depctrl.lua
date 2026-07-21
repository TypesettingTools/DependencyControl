#!/usr/bin/env luajit
-- DependencyControl CLI toolbox

local ffi = require "ffi"
local lfs = require "lfs"
local argparse = require "argparse"
require "moonscript" -- installs moonscript's package.moonpath loader for .moon files

-- ── Path utilities ────────────────────────────────────────────────────────────

local isWindows = ffi.os == "Windows"
local pathSep = isWindows and "\\" or "/"

local function dirname(path)
  return (path or ""):match("^(.*)[/\\][^/\\]*$") or "."
end

local function isAbsolute(path)
  return path:match("^%a:[/\\]") ~= nil -- C:\...
    or path:match("^[/\\]") ~= nil -- /... or \...
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
testCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
testCmd:option("-r --report-dir", "Directory for per-package CTRF JSON reports"):default("ctrf")
addTargets(testCmd)

local bundleCmd = parser:command("bundle", "Build a dist/ release bundle and zip archive")
bundleCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
bundleCmd:option("-o --out-dir", "Output directory; script files go into its dist/ subfolder"):default(".")
addTargets(bundleCmd)

local deployCmd = parser:command("deploy", "Deploy files directly to an output directory")
deployCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
deployCmd:option("-o --out-dir", "Output directory"):default(".")
deployCmd:flag("--clobber", "Overwrite existing files (default)"):target("clobber")
deployCmd:flag("--no-clobber", "Skip files that already exist at the destination"):target("clobber"):action("store_false")
addTargets(deployCmd)

local validateCmd = parser:command("validate-schema",
  "Validate a config or feed JSON file against its DependencyControl JSON schema")
validateCmd:option("-f --file", "JSON file to validate"):argname("<path>")
validateCmd:option("-t --type", "Schema family to validate against: 'config' or 'feed'"):argname("<type>")
validateCmd:option("--schema-version",
  "Validate against a specific schema version (e.g. 0.7.0) instead of auto-selecting the best match"):argname("<ver>")

local updateFeedCmd = parser:command("update-feed",
  "Refresh SHA-1 hashes, version info, and file presence in a feed channel")
updateFeedCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
updateFeedCmd:option("-c --channel", "Channel to update (default: the channel marked default: true)")
  :argname("<name>")
updateFeedCmd:flag("-n --dry-run", "Print what would change without writing back")
updateFeedCmd:flag("-a --add-files",
  "Discover files on disk that the targeted channel doesn't list and add entries for them")
updateFeedCmd:flag("--mark-released",
  "Stamp the release date on targeted channels still marked unreleased")
updateFeedCmd:option("--release-date",
  "Date to stamp with --mark-released (default: today, UTC)"):argname("<date>")
addTargets(updateFeedCmd)

local bumpCmd = parser:command("bump-version",
  "Bump package version(s) to the feed's lockstep version, then refresh the feed")
bumpCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
bumpCmd:option("-c --channel",
  "Channel whose versions and release state drive the bump (default: the channel marked default: true)")
  :argname("<name>")
bumpCmd:argument("namespace", "Package namespace(s) to bump; omit when using --all-changed"):args("*")
bumpCmd:flag("--all-changed", "Bump every package changed since its last release (release date cleared)")
bumpCmd:flag("--major", "Start a new release cycle by bumping the major component")
bumpCmd:flag("--minor", "Start a new release cycle by bumping the minor component")
bumpCmd:flag("--patch", "Start a new release cycle by bumping the patch component")

local mergeCmd = parser:command("merge-feed",
  "Copy channel(s) from one feed into another (e.g. publishing a dev channel to release/alpha)")
mergeCmd:option("-f --feed", "Source feed JSON path"):default("DependencyControl.json")
mergeCmd:option("--into", "Destination feed JSON path (updated in place)"):argname("<path>")
mergeCmd:option("--from", "Source channel to copy from"):argname("<name>")
mergeCmd:option("--to", "Destination channel(s), space-separated"):argname("<names>")
mergeCmd:option("--default-channel", "Which destination channel becomes default: true"):argname("<name>")
mergeCmd:option("--released", "Release date to stamp on the destination channel(s)"):argname("<date>")
mergeCmd:flag("-n --dry-run", "Print what would change without writing")

local notesCmd = parser:command("release-notes",
  "Render grouped markdown release notes from a feed's changelog for one version")
notesCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
notesCmd:option("-c --channel", "Channel whose version's changelog to render (default: the channel marked default: true)")
  :argname("<name>")
notesCmd:option("--version", "Version whose changelog to render (overrides --channel)"):argname("<ver>")
notesCmd:option("--title", "Optional top-level heading to prepend"):argname("<text>")
notesCmd:option("-o --output", "Write the notes to this file instead of stdout"):argname("<path>")

local typesCmd = parser:command("generate-types",
  "Extract LuaCATS annotations from module sources into LuaLS .d.lua type-definition files")
typesCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
typesCmd:option("-o --out-dir", "Root directory for the generated definition tree"):default("types")
typesCmd:flag("--check",
  "Lint annotations only: report findings and write nothing; exits nonzero on error findings")
addTargets(typesCmd)

local docsCmd = parser:command("generate-docs",
  "Render API documentation from module sources' LuaCATS annotations")
docsCmd:option("-f --feed", "Feed JSON path"):default("DependencyControl.json")
docsCmd:option("-o --out-dir", "Where the docs are written (the embeddable reference dir, or a standalone site's root)"):default("docs/reference")
docsCmd:option("--site", "'none' = embeddable reference section (flat pages + literate-nav SUMMARY.md); 'mkdocs'/'mdbook' = standalone site"):default("none")
docsCmd:option("--site-name", "Site title"):default("DependencyControl API")
docsCmd:flag("--include-private", "Render private members (badged) instead of omitting them")
addTargets(docsCmd)

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
package.path = ("%s/?.lua;%s/?/init.lua;"):format(depCtrlModulesDir, depCtrlModulesDir) .. package.path
package.moonpath = ("%s/?.moon;%s/?/init.moon;"):format(depCtrlModulesDir, depCtrlModulesDir) .. (package.moonpath or "")

if isWindows then
  require("l0.DependencyControl.helpers.ffi-windows").setConsoleOutputUTF8()
end

-- ── Aegisub shims ─────────────────────────────────────────────────────────────

local shims = require "l0.AegisubShims"
local aegisub = shims.aegisub -- pulled into local scope; global is set by the shim for sub-modules

-- ── Shared: workspace + DepCtrl bootstrap ────────────────────────────────────

local function setupDepCtrl(taskName)
  local tempBase = shims.getPathToken("temp")
  local workspace = tempBase .. pathSep .. ("depctrl-" .. taskName .. "-%x"):format(os.time() % 0x100000)
  for _, token in ipairs({ "user", "local", "data", "temp" }) do
    shims.setPathToken(token, workspace .. pathSep .. token)
  end

  local FileOps = require "l0.DependencyControl.file-ops"
  FileOps.mkdir("?temp", false, true)
  FileOps.mkdir("?user/log", false, true)

  -- Disable the self-updater so loading DepCtrl does not trigger a network
  -- fetch of its own feed (slow, flaky, pointless outside Aegisub).
  local constants = require "l0.DependencyControl.Constants"
  local globalConfigPath = aegisub.decode_path("?user/config/" .. constants.DEPCTRL_NAMESPACE .. ".json")
  FileOps.mkdir(globalConfigPath, true, true)
  do
    local json = require "l0.dkjson"
    local h = assert(io.open(globalConfigPath, "w"))
    h:write(json.encode({ config = { updates = { mode = "off" } } }))
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
  for _, ns in ipairs(mods) do filter:include(Common.ScriptType.Module, ns) end
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
      sourceById[id] = sourceById[id] or src -- first channel wins; sources are channel-agnostic
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

-- Collects the selected module packages' non-test .moon sources from a feed, keyed by require
-- id, for annotation extraction. Vendored .lua files have no annotations and are skipped; a
-- warning is printed for any unreadable source.
local function collectModuleSources(feed, filter)
  local Common = require "l0.DependencyControl.Common"
  local FileOps = require "l0.DependencyControl.file-ops"

  local selected = {}
  for pkg, scriptType in feed:walkPackages(filter) do
    if scriptType == Common.ScriptType.Module then selected[pkg.namespace] = true end
  end

  local function leafSuffix(name)
    return (name:gsub("%.moon$", ""):gsub("%.lua$", ""):gsub("/", "."))
  end

  local sources, seen = {}, {}
  for file, _, pkg in feed:walkFiles() do
    local src = file.localFilePath
    if selected[pkg.namespace] and src and file.type ~= "test" and file.name:match("%.moon$") then
      local requireId = pkg.namespace .. leafSuffix(file.name)
      if not seen[requireId] then
        seen[requireId] = true
        local text, readErr = FileOps.readFile(src)
        if text then
          sources[#sources + 1] = { requireId = requireId, source = text }
        else
          io.stderr:write(("! %s: couldn't read source '%s': %s\n"):format(requireId, src, tostring(readErr)))
        end
      end
    end
  end
  return sources, selected
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

  local DepCtrl = setupDepCtrl("tests")
  local FileOps = require "l0.DependencyControl.file-ops"

  local feedPath = resolveAbsPath(args.feed)
  local feed = loadFeed(feedPath)

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
  local allFailures = {} -- accumulated across packages for the end-of-run summary

  for _, pkg in ipairs(selected) do
    local ns = pkg.namespace
    local okRequire, mod = xpcall(require, debug.traceback, ns)
    local record = okRequire and DepCtrl:getRegisteredRecord(ns) or nil

    if not okRequire then
      io.stderr:write(("! %s: failed to load (%s)\n"):format(ns, tostring(mod)))
      failed = failed + 1
    elseif not (record and record.__class and record.__class.__name == "DependencyControl") then
      io.stderr:write(("~ %s: not a DependencyControl-managed package, skipping\n"):format(ns))
      skipped = skipped + 1
    elseif record.haveTestSuite == false then
      if record.testSuiteLoadError then
        io.stderr:write(("! %s: test suite failed to load (%s)\n"):format(ns, tostring(record.testSuiteLoadError)))
        failed = failed + 1
      else
        io.stderr:write(("~ %s: no test suite found, skipping\n"):format(ns))
        skipped = skipped + 1
      end
    elseif not record.testSuiteInitialized then
      io.stderr:write(("! %s: test suite failed to initialize (%s)\n"):format(ns, tostring(record.testSuiteInitializeError)))
      failed = failed + 1
    else
      io.stdout:write(("\n=== Testing %s ===\n"):format(ns))
      local success = record.tests:run()
      ran = ran + 1
      if not success then
        failed = failed + 1
        for _, f in ipairs(record.tests.failures) do
          f.namespace = ns
          allFailures[#allFailures + 1] = f
        end
      end

      local reportPath = FileOps.joinPath(reportDir, ns .. ".json")
      local wrote, writeErr = record.tests:writeResults(reportPath)
      io.stderr:write(wrote and ("Wrote CTRF report to " .. reportPath .. "\n")
        or ("Warning: couldn't write CTRF report for " .. ns .. ": " .. tostring(writeErr) .. "\n"))
    end
  end

  if #allFailures > 0 then
    io.stdout:write("\n—— Failures ——\n")
    for _, f in ipairs(allFailures) do
      io.stdout:write(("\n%s > %s > %s [%s]\n"):format(
        f.namespace, f.classname, f.name, f.isAssertion and "assertion" or "error"))
      local err = tostring(f.error or ""):gsub("%s+$", "")
      io.stdout:write("    " .. err:gsub("\n", "\n    ") .. "\n")
    end
  end

  io.stdout:write(("\n%d package(s) tested, %d skipped, %d failed.\n"):format(ran, skipped, failed))
  os.exit(failed > 0 and 1 or 0)

-- ─── bundle ───────────────────────────────────────────────────────────────────
elseif args.command == "bundle" then
  local feedPath = resolveAbsPath(args.feed)
  local outputDir = resolveAbsPath(args.out_dir)

  setupDepCtrl("bundle")

  local FileOps = require "l0.DependencyControl.file-ops"
  local ZipArchiver = require "l0.DependencyControl.ZipArchiver"
  local GitRepository = require "l0.DependencyControl.GitRepository"

  local feed = loadFeed(feedPath)
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

  local suffix = GitRepository(feed.feedDir):getVersionSuffix()
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
  local feedPath = resolveAbsPath(args.feed)
  local outputDir = resolveAbsPath(args.out_dir)
  local clobber = args.clobber == true

  setupDepCtrl("deploy")

  local feed = loadFeed(feedPath)
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
    channel = args.channel,
    filter = buildFilter(args),
    schemaDir = table.concat({ launcherDir, "schemas", "feed" }, pathSep),
    outPath = not args.dry_run, -- false = dry run; true = write back to the feed's own path
    addFiles = args.add_files,
    -- a date implies stamping; --mark-released alone stamps today (handled inside updateFeed)
    markReleased = args.release_date or (args.mark_released and true) or nil,
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
    for _, added in ipairs(pkg.addedFiles or {}) do
      io.stdout:write(("      + %s%s\n"):format(added.name, added.type and (" [" .. added.type .. "]") or ""))
    end
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

-- ─── bump-version ─────────────────────────────────────────────────────────────
elseif args.command == "bump-version" then
  local levels = {}
  for _, l in ipairs({ "major", "minor", "patch" }) do if args[l] then levels[#levels + 1] = l end end
  if #levels ~= 1 then
    io.stderr:write("Specify exactly one of --major, --minor, --patch.\n"); os.exit(2)
  end
  local haveNamespaces = #(args.namespace or {}) > 0
  if haveNamespaces == args.all_changed then -- both given, or neither
    io.stderr:write("Pass package namespace(s), or --all-changed, but not both.\n"); os.exit(2)
  end

  setupDepCtrl("bump-version")
  local feed = loadFeed(resolveAbsPath(args.feed))

  local stats, err = feed:bumpVersions({
    channel = args.channel,
    level = levels[1],
    namespaces = haveNamespaces and args.namespace or nil,
    allChanged = args.all_changed,
  })
  if not stats then
    io.stderr:write("bump-version: " .. tostring(err) .. "\n"); os.exit(1)
  end
  if #stats.bumped == 0 then
    io.stdout:write("Nothing to bump.\n"); os.exit(0)
  end
  for _, b in ipairs(stats.bumped) do
    io.stdout:write(("  %-40s %s -> %s\n"):format(b.namespace, b.from, b.to))
  end
  io.stdout:write(("\nBumped %d package(s) to %s on channel '%s'.\n"):format(
    #stats.bumped, stats.target, stats.channel))
  os.exit(0)

-- ─── merge-feed ───────────────────────────────────────────────────────────────
elseif args.command == "merge-feed" then
  if not (args.into and args.from and args.to and args.default_channel) then
    io.stderr:write("merge-feed requires --into, --from, --to and --default-channel.\n"); os.exit(2)
  end
  local intoPath = resolveAbsPath(args.into)

  setupDepCtrl("merge-feed")

  local source = loadFeed(resolveAbsPath(args.feed))
  local dest = loadFeed(intoPath)

  local to = {}
  for word in args.to:gmatch("%S+") do to[#to + 1] = word end

  local merged, err = dest:mergeChannels(source, {
    from = args.from,
    to = to,
    defaultChannel = args.default_channel,
    released = args.released,
    outPath = not args.dry_run,
  })
  if not merged then
    io.stderr:write("merge-feed: " .. tostring(err) .. "\n"); os.exit(1)
  end
  io.stdout:write(("Merged '%s' -> [%s] for %d package(s)%s\n"):format(
    args.from, args.to, #merged, args.dry_run and " — dry run, nothing written" or (" into " .. intoPath)))
  os.exit(0)

-- ─── release-notes ──────────────────────────────────────────────────────────────
elseif args.command == "release-notes" then
  setupDepCtrl("release-notes")
  local feed = loadFeed(resolveAbsPath(args.feed))

  local notes, err = feed:formatReleaseNotes({
    version = args.version,
    channel = args.channel,
    title = args.title,
  })
  if not notes then
    io.stderr:write("release-notes: " .. tostring(err) .. "\n"); os.exit(1)
  end
  local body = #notes > 0 and (notes .. "\n") or notes
  if args.output then
    local path = resolveAbsPath(args.output)
    local fh, fileErr = io.open(path, "w")
    if not fh then
      io.stderr:write("release-notes: can't write " .. path .. ": " .. tostring(fileErr) .. "\n"); os.exit(1)
    end
    fh:write(body); fh:close()
    io.stdout:write("Wrote release notes to " .. path .. "\n")
  else
    io.stdout:write(body)
  end
  os.exit(0)

elseif args.command == "validate-schema" then
  if args.type ~= "config" and args.type ~= "feed" then
    io.stderr:write("--type must be 'config' or 'feed'.\n"); os.exit(2)
  end
  if not args.file then
    io.stderr:write("--file <path> is required.\n"); os.exit(2)
  end
  local filePath = resolveAbsPath(args.file)

  -- Loads DependencyControl, which registers its provides searcher so the vendored dkjson resolves as
  -- 'json' — the module JsonSchema (and hence lua-schema) needs to parse schema files.
  setupDepCtrl("validate-schema")

  local FileOps = require "l0.DependencyControl.file-ops"
  local json = require "l0.dkjson"
  local JsonSchema = require "l0.DependencyControl.JsonSchema"

  local raw, readErr = FileOps.readFile(filePath)
  if not raw then
    io.stderr:write(("Couldn't read '%s': %s\n"):format(filePath, tostring(readErr))); os.exit(1)
  end
  local data, _, decErr = json.decode(raw)
  if type(data) ~= "table" then
    io.stderr:write(("Couldn't parse '%s' as JSON: %s\n"):format(filePath, tostring(decErr or "not a JSON object")))
    os.exit(1)
  end

  local schemaDir = table.concat({ launcherDir, "schemas", args.type }, pathSep)
  local schemasByVersion, schemasErr = JsonSchema:getSchemasInDirectory(schemaDir)
  if not schemasByVersion then
    io.stderr:write(tostring(schemasErr) .. "\n"); os.exit(1)
  end

  local valid, version, message
  if args.schema_version then
    local schemaPath = schemasByVersion[args.schema_version]
    if not schemaPath then
      io.stderr:write(("No %s schema for version '%s' in %s\n"):format(args.type, args.schema_version, schemaDir))
      os.exit(1)
    end
    version = args.schema_version
    valid, message = JsonSchema(schemaPath):validate(data)
  else
    -- validateAny selects the schema from the file itself: a config by its root `$schema`; a feed carries no
    -- `$schema`, so it's given a function that reads the feed's legacy `dependencyControlFeedFormatVersion`
    -- field instead. A file with neither falls back through the available schemas, highest version first.
    local hint
    if args.type == "feed" then
      hint = function(feed) return feed.dependencyControlFeedFormatVersion end
    end
    valid, version, message = JsonSchema:validateAny(data, schemasByVersion, hint)
  end

  if valid then
    io.stdout:write(("'%s' is valid against the %s schema v%s.\n"):format(filePath, args.type, tostring(version)))
    os.exit(0)
  else
    io.stderr:write(("'%s' failed %s schema validation%s:\n%s\n"):format(
      filePath, args.type, version and (" (v" .. version .. ")") or "", tostring(message)))
    os.exit(1)
  end

-- ─── generate-types ───────────────────────────────────────────────────────────
elseif args.command == "generate-types" then
  local feedPath = resolveAbsPath(args.feed)
  local outDir = resolveAbsPath(args.out_dir)

  setupDepCtrl("generate-types")

  local FileOps = require "l0.DependencyControl.file-ops"

  local feed = loadFeed(feedPath)
  local filter = buildFilter(args)

  if #(args.target_macro or {}) > 0 then
    io.stderr:write("Note: macros are not require-able and have no type definitions; --target-macro selectors are ignored.\n")
  end

  local sources = collectModuleSources(feed, filter)
  if #sources == 0 then
    io.stderr:write("No module sources matched in feed '" .. feedPath .. "'.\n")
    os.exit(1)
  end

  local MoonCats = require "l0.MoonCats"
  local result = MoonCats():extractPackage(sources)
  local diagnostics = result.diagnostics

  local written, writeErrors = 0, 0
  if not args.check then
    for _, def in ipairs(result.definitions) do
      local outPath = FileOps.getNamespacedPath(outDir, def.requireId, ".d.lua")
      FileOps.mkdir(outPath, true, true)
      local ok, writeErr = FileOps.writeFile(outPath, def.text, true)
      if ok then
        written = written + 1
        io.stdout:write(("  %-52s -> %s\n"):format(def.requireId, outPath))
      else
        writeErrors = writeErrors + 1
        io.stderr:write(("! %s: couldn't write '%s': %s\n"):format(def.requireId, outPath, tostring(writeErr)))
      end
    end
  end

  local report = diagnostics:format()
  if #report > 0 then
    io.stdout:write("\n" .. report .. "\n")
  end

  local counts = diagnostics:getCounts()
  local Severity = MoonCats.Diagnostics.Severity
  io.stdout:write(("\n%d module(s) processed: %d error(s), %d warning(s), %d note(s)%s\n"):format(
    #sources, counts[Severity.Error], counts[Severity.Warning], counts[Severity.Info],
    args.check and " — check mode, nothing written" or (", %d definition(s) written to %s"):format(written, outDir)))

  if args.check then
    os.exit(diagnostics:hasCheckFailures() and 1 or 0)
  end
  -- generation only fails on parse/emit-level breakage or write errors; lint gating is --check's job
  local hardFailure = writeErrors > 0
  for _, finding in ipairs(diagnostics.findings) do
    local FindingCode = MoonCats.Diagnostics.FindingCode
    if finding.code == FindingCode.ParseFailure or finding.code == FindingCode.EmitFailure then
      hardFailure = true
    end
  end
  os.exit(hardFailure and 1 or 0)

-- ─── generate-docs ────────────────────────────────────────────────────────────
elseif args.command == "generate-docs" then
  local feedPath = resolveAbsPath(args.feed)
  local outDir = resolveAbsPath(args.out_dir)

  if args.site ~= "mkdocs" and args.site ~= "mdbook" and args.site ~= "none" then
    io.stderr:write("--site must be 'mkdocs', 'mdbook', or 'none'.\n"); os.exit(2)
  end

  setupDepCtrl("generate-docs")

  local Common = require "l0.DependencyControl.Common"
  local FileOps = require "l0.DependencyControl.file-ops"

  local feed = loadFeed(feedPath)
  local filter = buildFilter(args)

  if #(args.target_macro or {}) > 0 then
    io.stderr:write("Note: macros are not require-able and have no API docs; --target-macro selectors are ignored.\n")
  end

  local sources, selected = collectModuleSources(feed, filter)
  if #sources == 0 then
    io.stderr:write("No module sources matched in feed '" .. feedPath .. "'.\n")
    os.exit(1)
  end

  -- Feed package info groups the index page: name/version/description per namespace,
  -- plus the require ids of the modules each package owns.
  local packages = {}
  for pkg, scriptType in feed:walkPackages(filter) do
    if scriptType == Common.ScriptType.Module and selected[pkg.namespace] then
      packages[pkg.namespace] = {
        name = pkg.name,
        description = pkg.description,
        version = feed:getModuleVersion(pkg.namespace),
        modules = {},
      }
    end
  end
  for _, source in ipairs(sources) do
    for namespace, info in pairs(packages) do
      if source.requireId == namespace or source.requireId:sub(1, #namespace + 1) == namespace .. "." then
        info.modules[#info.modules + 1] = source.requireId
      end
    end
  end

  local MoonCats = require "l0.MoonCats"
  local result, diagnostics = MoonCats():renderDocs(sources, {
    includePrivate = args.include_private,
    siteName = args.site_name,
    site = args.site,
    packages = packages,
  })

  local written, writeErrors = 0, 0
  local function writePage(page)
    local outPath = outDir .. pathSep .. page.path
    FileOps.mkdir(outPath, true, true)
    local ok, writeErr = FileOps.writeFile(outPath, page.text, true)
    if ok then
      written = written + 1
    else
      writeErrors = writeErrors + 1
      io.stderr:write(("! couldn't write '%s': %s\n"):format(outPath, tostring(writeErr)))
    end
  end
  writePage(result.indexPage)
  for _, page in ipairs(result.pages) do writePage(page) end
  for _, file in ipairs(result.scaffold) do writePage(file) end

  local report = diagnostics:format()
  if #report > 0 then
    io.stdout:write(report .. "\n")
  end

  local counts = diagnostics:getCounts()
  local Severity = MoonCats.Diagnostics.Severity
  io.stdout:write(("\n%d module(s) documented: %d page(s) written to %s (%d error(s), %d warning(s))\n"):format(
    #sources, written, outDir, counts[Severity.Error], counts[Severity.Warning]))

  local hardFailure = writeErrors > 0
  for _, finding in ipairs(diagnostics.findings) do
    if finding.code == MoonCats.Diagnostics.FindingCode.ParseFailure then hardFailure = true end
  end
  os.exit(hardFailure and 1 or 0)
end
