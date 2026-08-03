-- cspell:ignore grüße münchen
-- Pins the behavior of `aegisub.clipboard`. The same corpus runs in both environments: inside Aegisub it
-- checks the live module, while under the CLI the preload in l0.AegisubShims swaps in the process-local
-- stand-in, so the run doubles as the stand-in's conformance test.
-- Called from test.moon as: (controls\requireTest "aegisub-clipboard")!
--
-- Inside Aegisub these tests write the real clipboard, so setup snapshots it and teardown restores it.
->
  -- Requiring l0.AegisubShims.clipboard directly would resolve only under the CLI: inside Aegisub the
  -- shim package isn't deployed at all, so the require fails and takes the whole suite's setup down.
  haveClipboard, clipboard = pcall require, "aegisub.clipboard"

  -- The preload only fires outside Aegisub, so this distinguishes the stand-in from the real module
  -- without either of them having to advertise which it is.
  isStandIn = package.loaded["l0.AegisubShims.clipboard"] == clipboard
  shims = isStandIn and require "l0.AegisubShims"

  STRING_SAMPLE_UTF8 = "grüße aus münchen — 日本語もあります"

  {
    _description: "Conformance of aegisub.clipboard, and of the headless stand-in that replaces it."
    _condition: -> haveClipboard, "aegisub.clipboard unavailable (#{tostring clipboard})"

    ---@param ut UnitTest
    _setup: (ut) ->
      {restore: clipboard.get!}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      clipboard.set ctx.restore if ctx and ctx.restore

    -- the require-id mapping only exists once l0.AegisubShims has installed it, which never happens
    -- inside Aegisub; gate on it so this file stays runnable in both environments
    preload_claimsBothRequireIds: (ut) ->
      ut\skip "l0.AegisubShims isn't loaded" unless isStandIn
      ut\assertFunction package.preload["aegisub.clipboard"]
      ut\assertIs package.preload["aegisub.clipboard"](), clipboard

    preload_shortIdAlsoPublishesTheGlobal: (ut) ->
      ut\skip "l0.AegisubShims isn't loaded" unless isStandIn
      ut\assertIs require("clipboard"), clipboard
      ut\assertIs _G.clipboard, clipboard

    set_roundTripsThroughGet: (ut) ->
      ut\assertTrue clipboard.set "round trip"
      ut\assertEquals clipboard.get!, "round trip"

    set_preservesUtf8: (ut) ->
      clipboard.set STRING_SAMPLE_UTF8
      ut\assertEquals clipboard.get!, STRING_SAMPLE_UTF8

    set_replacesPreviousContents: (ut) ->
      clipboard.set "first"
      clipboard.set "second"
      ut\assertEquals clipboard.get!, "second"

    -- an empty clipboard reads as nil rather than an empty string, and storing "" leaves it empty
    get_emptyStringReadsAsNil: (ut) ->
      clipboard.set ""
      ut\assertNil clipboard.get!

    shims_reExportTracksTheSameClipboard: (ut) ->
      ut\skip "l0.AegisubShims isn't loaded" unless isStandIn
      ut\assertIs shims.clipboard, clipboard

      clipboard.set "written through the module"
      ut\assertEquals shims.clipboard.get!, "written through the module"

    set_rejectsNonStrings: (ut) ->
      ut\assertError clipboard.set, 42
      ut\assertError clipboard.set, nil
      ut\assertError clipboard.set, {}

    setBackend_routesGetAndSetThroughTheReplacement: (ut) ->
      ut\skip "the real module has no shim hooks" unless isStandIn
      written = {}
      previous = shims.setClipboardBackend {
        get: -> "from the backend"
        set: (str) ->
          written[#written + 1] = str
          return true
      }

      ut\assertTrue clipboard.set "handed over"
      ut\assertEquals written[1], "handed over"
      ut\assertEquals clipboard.get!, "from the backend"

      shims.setClipboardBackend previous
      ut\assertIs shims.getClipboardBackend!, previous

    setBackend_nilRestoresTheInProcessBackend: (ut) ->
      ut\skip "the real module has no shim hooks" unless isStandIn
      original = shims.getClipboardBackend!
      shims.setClipboardBackend {
        get: -> "elsewhere"
        set: -> false
      }
      shims.setClipboardBackend nil

      ut\assertIs shims.getClipboardBackend!, original
      clipboard.set "back home"
      ut\assertEquals clipboard.get!, "back home"

    -- the nil-when-empty contract is the module's, so a backend handing back "" can't leak it
    setBackend_emptyStringFromBackendStillReadsAsNil: (ut) ->
      ut\skip "the real module has no shim hooks" unless isStandIn
      previous = shims.setClipboardBackend {
        get: -> ""
        set: -> true
      }
      ut\assertNil clipboard.get!
      shims.setClipboardBackend previous

    setBackend_rejectsBackendWithoutBothMethods: (ut) ->
      ut\skip "the real module has no shim hooks" unless isStandIn
      ut\assertError shims.setClipboardBackend, 42
      ut\assertError shims.setClipboardBackend, {}
      ut\assertError shims.setClipboardBackend, {get: -> nil}
      ut\assertError shims.setClipboardBackend, {set: -> true}
  }
