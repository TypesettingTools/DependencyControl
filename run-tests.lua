#!/usr/bin/env luajit
-- Headless DependencyControl test runner.
--
-- Runs the DepCtrl unit test suite from the command line (locally or in CI) without
-- an Aegisub process. Requires LuaJIT (built with LUA52COMPAT=1) plus the LuaRocks
-- modules `moonscript` and `luafilesystem`. JSON is vendored (dkjson), and the FFI
-- timer/mutex/downloader are bundled, so no other external modules are needed.
--
--   luajit run-tests.lua [ctrf-report-path]
--
-- An optional first argument sets where the CTRF test report is written; it
-- defaults to ctrf/DependencyControl.json next to this script.
-- Exit code is 0 when every test passes, 1 otherwise.

local ffi = require "ffi"
local lfs = require "lfs"
require "moonscript"
local moonbase = require "moonscript.base"

-- normally provided by the hosting macro in Aegisub environments
script_namespace = "DepCtrl.Tests"

local isWindows = ffi.os == "Windows"
local pathSep = isWindows and "\\" or "/"

-- Utility functions

local function dirname(path)
  return (path or ""):match("^(.*)[/\\][^/\\]*$") or "."
end

local function isAbsolute(path)
  return path:match("^%a:[/\\]") ~= nil -- "C:\..."
      or path:match("^[/\\]") ~= nil    -- "/..." or "\..."
end

local function fileExists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end


-- Resolve the repo root from this script's own location so the runner works regardless
-- of the current working directory. The path is made absolute up front so module
-- resolution can't be thrown off by anything that changes the process CWD mid-run.

local testLauncherScriptDir = dirname(arg and arg[0])
if testLauncherScriptDir == "." then
  testLauncherScriptDir = lfs.currentdir() -- avoid a trailing "\." segment
elseif not isAbsolute(testLauncherScriptDir) then
  testLauncherScriptDir = lfs.currentdir() .. pathSep .. testLauncherScriptDir
end
local modulesDir = testLauncherScriptDir .. pathSep .. "modules"

-- Custom searcher mapping the `l0.` namespace onto the repo's `modules/` directory,
-- loading either MoonScript sources or plain Lua files. Appended last so it only fires
-- for our own modules; everything else (lfs, ffi, moonscript) resolves through the stock
-- searchers. The bare aliases "json", "BM.BadMutex" and "DM.DownloadManager" are routed
-- to their `l0.` providers by DepCtrl's own ModuleProvider searcher, which in turn lands
-- back here.
local function l0ModuleSearcher(name)
  local moduleNameWithoutNamespace = name:match("^l0%.(.+)$")
  if not moduleNameWithoutNamespace then return nil end

  local moduleRelativePath = moduleNameWithoutNamespace:gsub("%.", pathSep)
  local basePath = modulesDir .. pathSep .. moduleRelativePath
  local candidates = {
    { path = basePath .. ".moon",                moon = true },
    { path = basePath .. ".lua",                 moon = false },
    { path = basePath .. pathSep .. "init.moon", moon = true },
    { path = basePath .. pathSep .. "init.lua",  moon = false },
  }
  for _, c in ipairs(candidates) do
    if fileExists(c.path) then
      local chunk, err = (c.moon and moonbase.loadfile or loadfile)(c.path)
      if not chunk then error(err) end
      return chunk
    end
  end
  return "\n\tno l0 module file for '" .. name .. "' under " .. modulesDir
end
table.insert(package.loaders or package.searchers, l0ModuleSearcher)

-- Install the Aegisub global shim. It exposes a small configuration API which we use to
-- point the path tokens at a throwaway workspace, so the suite's log files and feed caches
-- land somewhere writable instead of the user's real Aegisub config directory.
local shims = require "l0.AegisubShims"

local workspace = shims.getPathToken("temp") .. pathSep .. ("depctrl-tests-%x"):format(os.time() % 0x100000)
for _, token in ipairs({ "user", "local", "data", "temp" }) do
  shims.setPathToken(token, workspace .. pathSep .. token)
end

-- Make sure the directories the shim now resolves actually exist. FileOps.mkdir with the
-- recurse flag creates any missing parents (validateFullPath expands the path tokens).
local FileOps = require "l0.DependencyControl.FileOps"
FileOps.mkdir("?temp", false, true)
FileOps.mkdir("?user/log", false, true)

-- Load DepCtrl (triggers the ModuleProvider bootstrap for json/BadMutex/DownloadManager)
-- and its test suite, then run it.
local DepCtrl = require "l0.DependencyControl"
local suite   = require "l0.DependencyControl.Tests"

suite:import(DepCtrl)
local success = suite:run()

-- Write CTRF test report
local reportPath = arg[1] or (testLauncherScriptDir .. pathSep .. "ctrf" .. pathSep .. "DependencyControl.json")
local wrote, writeErr = suite:writeResults(reportPath)

io.stderr:write(wrote and ("\nWrote CTRF report to " .. reportPath .. "\n")
  or ("\nWarning: couldn't write CTRF report: " .. tostring(writeErr) .. "\n"))

io.stderr:write(success and "\nAll DependencyControl tests passed.\n"
  or "\nDependencyControl tests FAILED.\n")
os.exit(success and 0 or 1)
