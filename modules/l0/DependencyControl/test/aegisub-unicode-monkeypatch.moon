-- cspell:ignore mlaut
-- Pins the port of Aegisub's unicode-monkeypatch, which makes the Lua io and os functions take UTF-8
-- paths on Windows. Aegisub installs its own copy into every Lua state it creates there, so inside
-- Aegisub these tests exercise that copy and headlessly they exercise ours; either way a non-ASCII path
-- has to work.
-- Called from test.moon as: (controls\requireTest "aegisub-unicode-monkeypatch")!
->
  ffi = require "ffi"
  fileOps = require "l0.DependencyControl.file-ops"
  pathOps = require "l0.DependencyControl.path-ops"

  -- ü and 日本語 in UTF-8, one representable in a Western code page and one not, so a run on either
  -- kind of machine still has a name the unpatched functions would get wrong
  NAME_LATIN = "\195\188mlaut.txt"
  NAME_CJK = "\230\151\165\230\156\172\232\170\158.txt"

  isWindows = ffi.os == "Windows"

  {
    _description: "UTF-8 paths through the Lua io and os functions, which Windows needs patched."

    ---@param ut UnitTest
    _setup: (ut) ->
      dir, err = fileOps.createTempDir!
      ut\assertNotNil dir, err
      {:dir}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      fileOps.remove ctx.dir, true if ctx and ctx.dir

    -- a machine whose code page is already UTF-8 needs no patch, so the port stands down there; what
    -- has to hold either way is the round trips below
    patch_reportsWhatItDidOnThisPlatform: (ut) ->
      status = require "l0.AegisubShims.unicode-monkeypatch"
      ut\assertBoolean status.applied
      ut\assertFalse status.applied unless isWindows
      ut\assertNotNil status.reason unless status.applied

    ioOpen_roundTripsANonAsciiPath: (ut, ctx) ->
      for name in *{NAME_LATIN, NAME_CJK}
        path = pathOps.joinPath ctx.dir, name
        written = assert io.open path, "w"
        written\write "round trip"
        written\close!

        read = io.open path, "r"
        ut\assertNotNil read, "could not reopen #{name}"
        ut\assertEquals read\read("*a"), "round trip"
        read\close!

    ioOpen_missingNonAsciiPathReportsFailure: (ut, ctx) ->
      file, err = io.open pathOps.joinPath(ctx.dir, "\195\188-absent.txt"), "r"
      ut\assertNil file
      ut\assertString err

    -- widening rejects a path that isn't valid UTF-8, which has to surface the way any other bad path
    -- does; 0xFF never appears in a well-formed sequence
    ioOpen_malformedUtf8PathFailsWithoutRaising: (ut, ctx) ->
      ut\skip "only the patched functions widen a path" unless isWindows
      file, err = io.open pathOps.joinPath(ctx.dir, "\255\254bad.txt"), "r"
      ut\assertNil file
      ut\assertString err

    osRename_movesANonAsciiPath: (ut, ctx) ->
      source = pathOps.joinPath ctx.dir, NAME_LATIN
      target = pathOps.joinPath ctx.dir, NAME_CJK
      assert(io.open source, "w")\close!

      ut\assertTrue os.rename source, target
      ut\assertNil io.open source, "r"
      reopened = io.open target, "r"
      ut\assertNotNil reopened
      reopened\close!

    osRemove_deletesANonAsciiPathAndReportsAMissingOne: (ut, ctx) ->
      path = pathOps.joinPath ctx.dir, NAME_CJK
      assert(io.open path, "w")\close!

      ut\assertTrue os.remove path
      ut\assertNil io.open path, "r"

      removed, err = os.remove path
      ut\assertNil removed
      ut\assertString err
  }
