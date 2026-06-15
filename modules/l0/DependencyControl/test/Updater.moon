-- Updater tests: extracted from the main test suite.
-- Called from test.moon as: (controls\requireTest "Updater")!
() ->
  ffi     = require "ffi"
  Common  = require "l0.DependencyControl.Common"
  FileOps = require "l0.DependencyControl.FileOps"
  Record  = require "l0.DependencyControl.Record"

  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"

  -- Drive prefix so stubbed paths are recognized as absolute on Windows too.
  DRIVE = ffi.os == "Windows" and "C:" or ""

  -- Map the ?user / ?data tokens to distinct absolute roots so the two automation
  -- directories differ (the non-portable case getEntryPointPath guards against).
  stubDistinctRoots = (ut) ->
    (ut\stub aegisub, "decode_path")\calls (path) ->
      ((path\gsub "^%?user", "#{DRIVE}/user")\gsub "^%?data", "#{DRIVE}/data")

  -- fileOps.attributes stub that reports a "file" mode for exactly the given full paths.
  stubFilesPresent = (ut, present) ->
    set = {p, true for p in *present}
    (ut\stub FILEOPS_MODULE_NAME, "attributes")\calls (path, key) ->
      return "file", path if set[path]
      return false, path

  -- Normalize a sub-path under a base dir the same way getPossibleEntryPointPaths does,
  -- so expected paths in tests always match what the production code produces.
  entryPath = (baseDir, subPath) -> FileOps.validateFullPath subPath, false, baseDir

  moduleRecord = {
    scriptType: Common.ScriptType.Module, namespace: "l0.Foo",
    getPossibleEntryPointPaths: Record.getPossibleEntryPointPaths,
    getEntryPointPath: Record.getEntryPointPath
  }
  macroRecord = {
    scriptType: Common.ScriptType.Automation, namespace: "l0.Foo.Bar",
    getPossibleEntryPointPaths: Record.getPossibleEntryPointPaths,
    getEntryPointPath: Record.getEntryPointPath
  }

  {
    _description: "Tests for Record.getEntryPointPath: locates a record's entry point and reports whether it is under the ?user or ?data automation directory."

    -- a module present only under ?data: found there, isUserPath = false
    module_dataOnly: (ut) ->
      stubDistinctRoots ut
      dataDir = aegisub.decode_path "?data/automation/include"
      expected = entryPath dataDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertFalse isUserPath

    -- modules may also be deployed as <namespace>/init.ext
    module_initLayout: (ut) ->
      stubDistinctRoots ut
      dataDir = aegisub.decode_path "?data/automation/include"
      expected = entryPath dataDir, "l0/Foo/init.lua"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertFalse isUserPath

    -- ?user copy takes precedence: found there, isUserPath = true
    module_alsoUnderUser: (ut) ->
      stubDistinctRoots ut
      userDir = aegisub.decode_path "?user/automation/include"
      dataDir = aegisub.decode_path "?data/automation/include"
      expected = entryPath userDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected, entryPath(dataDir, "l0/Foo.moon")}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertTrue isUserPath

    module_userOnly: (ut) ->
      stubDistinctRoots ut
      userDir = aegisub.decode_path "?user/automation/include"
      expected = entryPath userDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertTrue isUserPath

    -- not installed anywhere yet → both return values are nil
    notInstalled: (ut) ->
      stubDistinctRoots ut
      stubFilesPresent ut, {}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertNil path
      ut\assertNil isUserPath

    -- portable / "Local Config": ?user and ?data resolve to the same directory, so the file
    -- is found under ?user first and isUserPath is always true
    portable: (ut) ->
      (ut\stub aegisub, "decode_path")\calls (path) ->
        ((path\gsub "^%?user", "#{DRIVE}/same")\gsub "^%?data", "#{DRIVE}/same")
      sameDir = aegisub.decode_path "?user/automation/include"
      expected = entryPath sameDir, "l0/Foo.moon"
      stubFilesPresent ut, {expected}
      path, isUserPath = moduleRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertTrue isUserPath

    -- automation scripts live as a single file in the autoload directory
    macro_dataOnly: (ut) ->
      stubDistinctRoots ut
      dataDir = aegisub.decode_path "?data/automation/autoload"
      expected = entryPath dataDir, "l0.Foo.Bar.lua"
      stubFilesPresent ut, {expected}
      path, isUserPath = macroRecord\getEntryPointPath!
      ut\assertEquals path, expected
      ut\assertFalse isUserPath

    _order: {
      "module_dataOnly", "module_initLayout",
      "module_alsoUnderUser", "module_userOnly",
      "notInstalled", "portable",
      "macro_dataOnly"
    }
  }
