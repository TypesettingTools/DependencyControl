#!/usr/bin/env luajit
-- DependencyControl CLI launcher.
--
-- Usage: luajit depctrl.lua <command> [args...]
--
--   luajit depctrl.lua test [ctrf-report-path]
--     Run the unit test suite. The optional argument overrides the CTRF report
--     output path (default: ctrf/DependencyControl.json next to this script).
--     Exit code 0 = all tests pass, 1 = failures.
--
--   luajit depctrl.lua bundle
--     Build a dist/ release bundle by copying every file listed in
--     DependencyControl.json to the path derived from its expanded download URL.
--     dist/ is cleaned first. Exit code 0 = success, 1 = one or more warnings.

local ffi = require "ffi"
local lfs = require "lfs"
require "moonscript"  -- installs moonscript's package.moonpath loader for .moon files

-- ── Path utilities ────────────────────────────────────────────────────────────

local isWindows = ffi.os == "Windows"
local pathSep = isWindows and "\\" or "/"

local function dirname(path)
    return (path or ""):match("^(.*)[/\\][^/\\]*$") or "."
end

local function isAbsolute(path)
    return path:match("^%a:[/\\]") ~= nil  -- C:\...
        or path:match("^[/\\]") ~= nil      -- /... or \...
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- ── Resolve the launcher directory ───────────────────────────────────────────
-- Made absolute up-front so nothing downstream can be confused by CWD changes.

local launcherDir = dirname(arg and arg[0])
if launcherDir == "." then
    launcherDir = lfs.currentdir()
elseif not isAbsolute(launcherDir) then
    launcherDir = lfs.currentdir() .. pathSep .. launcherDir
end
-- ── Module resolution ──────────────────────────────────────────────────────────
-- The repo's modules/ tree is namespaced (modules/l0/…), so l0.* require paths map
-- straight onto it: moonscript's loader resolves .moon via package.moonpath, the
-- stock searcher the vendored .lua via package.path. No custom searcher needed.
local modulesDir = launcherDir .. pathSep .. "modules"
package.path     = ("%s/?.lua;%s/?/init.lua;"):format(modulesDir, modulesDir) .. package.path
package.moonpath = ("%s/?.moon;%s/?/init.moon;"):format(modulesDir, modulesDir) .. (package.moonpath or "")

-- ── Aegisub shims ─────────────────────────────────────────────────────────────

local shims = require "l0.AegisubShims"
local aegisub = shims.aegisub  -- pulled into local scope; global is set by the shim for sub-modules

-- ── Shared: workspace + DepCtrl bootstrap ────────────────────────────────────

local function setupDepCtrl(workspacePrefix)
    local tempBase = shims.getPathToken("temp")
    local workspace = tempBase .. pathSep .. (workspacePrefix .. "-%x"):format(os.time() % 0x100000)
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

-- ── Command dispatch ──────────────────────────────────────────────────────────

local cmd = arg[1]

-- ─── test ─────────────────────────────────────────────────────────────────────
if cmd == "test" then
    local DepCtrl = setupDepCtrl("depctrl-tests")
    local suite   = require "l0.DependencyControl.Tests"

    suite:import(DepCtrl)
    local success = suite:run()

    local reportPath = arg[2] or (launcherDir .. pathSep .. "ctrf" .. pathSep .. "DependencyControl.json")
    if not isAbsolute(reportPath) then
        reportPath = lfs.currentdir() .. pathSep .. reportPath:gsub("^%.[/\\]", "")
    end
    local wrote, writeErr = suite:writeResults(reportPath)

    io.stderr:write(wrote and ("\nWrote CTRF report to " .. reportPath .. "\n")
        or ("\nWarning: couldn't write CTRF report: " .. tostring(writeErr) .. "\n"))
    io.stderr:write(success and "\nAll DependencyControl tests passed.\n"
        or "\nDependencyControl tests FAILED.\n")
    os.exit(success and 0 or 1)

-- ─── bundle ───────────────────────────────────────────────────────────────────
elseif cmd == "bundle" then
    setupDepCtrl("depctrl-bundle")

    local Common      = require "l0.DependencyControl.Common"
    local FileOps     = require "l0.DependencyControl.FileOps"
    local UpdateFeed  = require "l0.DependencyControl.UpdateFeed"
    local ZipArchiver = require "l0.DependencyControl.ZipArchiver"
    local feedPath = launcherDir .. pathSep .. "DependencyControl.json"

    -- Load and expand the feed without touching the network.
    local feed = UpdateFeed(feedPath, false)
    local ok, err = feed:loadFile(feedPath)
    if not ok then
        io.stderr:write("Error loading feed: " .. tostring(err) .. "\n")
        os.exit(1)
    end

    local feedFileBaseUrl = feed.data.fileBaseUrl or ""
    if feedFileBaseUrl == "" then
        io.stderr:write("Error: feed has no fileBaseUrl — cannot determine source paths\n")
        os.exit(1)
    end

    -- ── Clean and recreate dist/ ──────────────────────────────────────────────
    -- All managed file operations go through DependencyControl's own FileOps so
    -- the launcher stays a thin wrapper around the library it ships.

    local distDir = launcherDir .. pathSep .. "dist"
    FileOps.remove(distDir, true)
    FileOps.mkdir(distDir, false, true)

    -- ── Copy files ────────────────────────────────────────────────────────────
    -- Source path: the file's expanded URL has the feed-level fileBaseUrl prefix
    -- stripped to a versioned path (e.g. "v0.7.0-alpha/modules/Foo.moon"); dropping
    -- the leading version/channel segment yields the repo-relative source path.
    -- Destination: the file's install layout, derived from its namespace via
    -- Common.getFileDeployPath (autoload/ for macros, include/ for modules, tests/DepUnit/…
    -- for test files), so dist/ mirrors an Aegisub automation directory and the
    -- bundle is a drop-in extract.

    local function escapePat(s)
        return (s:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1"))
    end
    local baseUrlPat = "^" .. escapePat(feedFileBaseUrl) .. "(.+)$"
    -- Install paths from Common.getFileDeployPath are absolute under ?user/automation; strip
    -- that root to get the path relative to dist/. Normalize separators to '/'.
    local autoRoot = aegisub.decode_path("?user/automation"):gsub("\\", "/")

    local fileCount, warnCount = 0, 0

    for _, section in ipairs({ "macros", "modules" }) do
        local pkgs = feed.data[section]
        if not pkgs then goto nextSection end
        local scriptType = section == "macros" and Common.ScriptType.Automation
            or Common.ScriptType.Module

        for namespace, pkg in pairs(pkgs) do
            for channelName, channel in pairs(pkg.channels or {}) do
                for _, file in ipairs(channel.files or {}) do
                    local url = file.url
                    if not url then
                        io.stderr:write(("  warn: %s/%s/%s has no url\n")
                            :format(namespace, channelName, tostring(file.name)))
                        warnCount = warnCount + 1
                        goto nextFile
                    end

                    -- Source: strip the feed base URL, then the leading version/channel segment.
                    local afterBase = url:match(baseUrlPat)
                    if not afterBase then
                        io.stderr:write(("  warn: URL not under feedFileBaseUrl, skipping:\n    %s\n"):format(url))
                        warnCount = warnCount + 1
                        goto nextFile
                    end

                    local relPath = afterBase:match("^[^/]+/(.+)$")
                    if not relPath then
                        io.stderr:write(("  warn: cannot strip version prefix from: %s\n"):format(afterBase))
                        warnCount = warnCount + 1
                        goto nextFile
                    end

                    local srcPath = launcherDir .. pathSep .. relPath:gsub("/", pathSep)
                    if not fileExists(srcPath) then
                        io.stderr:write(("  warn: source not found: %s\n"):format(srcPath))
                        warnCount = warnCount + 1
                        goto nextFile
                    end

                    -- Destination: install layout relative to dist/.
                    local installRel = Common:getFileDeployPath(namespace, scriptType, file.name, file.type or "script")
                        :gsub("\\", "/"):sub(#autoRoot + 2)
                    local dstPath = distDir .. pathSep .. installRel:gsub("/", pathSep)

                    FileOps.mkdir(dstPath, true, true)  -- ensure the target's parent dir exists
                    local copied, copyErr = FileOps.copy(srcPath, dstPath)
                    if copied then
                        io.stdout:write(("  %s  →  dist/%s\n"):format(relPath, installRel))
                        fileCount = fileCount + 1
                    else
                        io.stderr:write(("  error copying %s: %s\n"):format(relPath, tostring(copyErr)))
                        warnCount = warnCount + 1
                    end

                    ::nextFile::
                end
            end
        end
        ::nextSection::
    end

    -- ── Create the zip archive ─────────────────────────────────────────────────
    -- Named DependencyControl-v<mainModuleVersion>; when HEAD is not on a tag, a
    -- -<branch>-g<shortHash> suffix is appended (git-describe style).

    local function defaultChannelVersion(pkg)
        local fallback
        for _, ch in pairs(pkg.channels or {}) do
            fallback = fallback or ch.version
            if ch.default then return ch.version end
        end
        return fallback
    end

    local mainPkg = feed.data.modules and feed.data.modules["l0.DependencyControl"]
    local mainVersion = mainPkg and defaultChannelVersion(mainPkg)
    if not mainVersion then
        io.stderr:write("Error: couldn't determine l0.DependencyControl version from feed\n")
        os.exit(1)
    end

    local function git(args)
        local h = io.popen(('git -C "%s" %s 2>&1'):format(launcherDir, args))
        if not h then return nil end
        local out = (h:read("*a") or ""):gsub("%s+$", "")
        local success = h:close()
        return success and out ~= "" and out or nil
    end

    local suffix = ""
    if not git("describe --exact-match --tags HEAD") then  -- HEAD is not on a tag
        local branch = git("rev-parse --abbrev-ref HEAD") or "unknown"
        local hash   = git("rev-parse --short=7 HEAD")    or "0000000"
        suffix = ("-%s-g%s"):format(branch, hash)
    end

    local zipName = ("DependencyControl-v%s%s.zip"):format(mainVersion, suffix)
    local zipPath = launcherDir .. pathSep .. zipName

    -- Archive the whole dist/ tree via DependencyControl's own ZipArchiver, which
    -- uses each platform's stock tooling and emits spec-compliant forward-slash
    -- entries (per-platform details live in the module).
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
    io.stdout:write(("\n%s: %d file(s) copied, %d warning(s)  →  %s\n")
        :format(status, fileCount, warnCount, distDir))
    if zipOk then
        io.stdout:write(("Archive: %s\n"):format(zipPath))
    end
    os.exit(warnCount > 0 and 1 or 0)

-- ─── usage ────────────────────────────────────────────────────────────────────
else
    io.stderr:write(("Usage: luajit %s <command> [args...]\n"):format(arg[0] or "depctrl.lua"))
    io.stderr:write("Commands:\n")
    io.stderr:write("  test [ctrf-report-path]   Run the unit test suite\n")
    io.stderr:write("  bundle                    Build the dist/ release bundle\n")
    os.exit(1)
end
