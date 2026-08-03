-- Pins the behavior of the headless stand-in for Aegisub's `include` script global, and of the short
-- require ids it shares its routing table with.
-- Called from test.moon as: (controls\requireTest "aegisub-include")!
--
-- The routing table under test exists only headlessly. Inside Aegisub `include` reads the real include
-- directory, where the unsupported-name cases would load karaskel into the running session.
->
  haveShims, shims = pcall require, "l0.AegisubShims"

  {
    _description: "The headless stand-in for Aegisub's include(), and the require ids it also serves."
    _condition: -> haveShims, "l0.AegisubShims isn't loaded (#{tostring shims})"

    include_isInstalledAsAGlobal: (ut) ->
      ut\assertFunction _G.include
      ut\assertIs _G.include, shims.include

    include_publishesGlobalAndReturnsModule: (ut) ->
      returned = shims.include "clipboard.lua"
      ut\assertIs returned, require "l0.AegisubShims.clipboard"
      ut\assertIs _G.clipboard, returned

    -- utils.lua and utils-auto4.lua publish `util` without handing it back, so a caller has to read
    -- the global
    include_utilsPublishesGlobalWithoutReturning: (ut) ->
      ut\assertNil shims.include "utils-auto4.lua"
      ut\assertIs _G.util, require "l0.AegisubShims.util"

      _G.util = nil
      ut\assertNil shims.include "utils.lua"
      ut\assertIs _G.util, require "l0.AegisubShims.util"

    include_unsupportedFileRaises: (ut) ->
      -- full implementations with no module behind them to route to
      ut\assertError shims.include, "karaskel.lua"
      ut\assertError shims.include, "cleantags.lua"
      ut\assertError shims.include, "unicode-monkeypatch.lua"
      -- no disk is touched, so a path resolves to nothing whether or not it exists
      ut\assertError shims.include, "some/other/file.lua"
      ut\assertError shims.include, "clipboard"

    include_rejectsNonStrings: (ut) ->
      ut\assertError shims.include, 42
      ut\assertError shims.include, nil

    preload_shortIdsMatchTheIncludeTable: (ut) ->
      ut\assertIs require("re"), require "l0.AegisubShims.re"
      ut\assertIs _G.re, require "l0.AegisubShims.re"
      ut\assertIs require("unicode"), require "l0.AegisubShims.unicode"
      ut\assertIs _G.unicode, require "l0.AegisubShims.unicode"

    -- lfs resolves to the rock under its own name, so claiming that require id would leave the
    -- loader recursing into itself
    preload_lfsKeepsItsOwnRequireId: (ut) ->
      ut\assertNil package.preload.lfs
      ut\assertIs shims.include("lfs.lua"), require "lfs"
      ut\assertIs _G.lfs, require "lfs"
  }
