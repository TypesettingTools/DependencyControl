-- cspell:ignore mlaut
-- Pins the wide-character layer over lfs, which makes its calls take UTF-8 paths on Windows. Both
-- implementations need it there — the luafilesystem rock throughout, Aegisub's built-in module in
-- `attributes` alone — while off Windows the stock calls already take UTF-8. The round trips below
-- therefore have to hold on every platform, whether or not the layer is what carries them.
-- Called from test.moon as: (controls\requireTest "lfs-unicode-patch") isWindows
(isWindows) ->
  fileOps = require "l0.DependencyControl.file-ops"
  lfs = require "lfs"
  pathOps = require "l0.DependencyControl.path-ops"
  lfsUnicodePatch = require "l0.DependencyControl.lfs-unicode-patch"

  -- ü and 日本語 in UTF-8, one representable in a Western code page and one not, so a run on either
  -- kind of machine still has a name the calls would get wrong without the layer
  NAME_LATIN = "\195\188mlaut"
  NAME_CJK = "\230\151\165\230\156\172\232\170\158"

  FILE_BODY = "round trip"

  ---Bytes of a string spelled out, so a mismatch names the encoding rather than showing two
  ---identical-looking values.
  toByteList = (text) -> table.concat [tostring text\byte index for index = 1, #text], " "

  {
    _description: "UTF-8 paths through the lfs calls, which Windows needs widened."

    ---@param ut UnitTest
    _setup: (ut) ->
      base, err = fileOps.createTempDir!
      ut\assertNotNil base, err

      directories = {}
      for name in *{NAME_LATIN, NAME_CJK}
        directory = pathOps.joinPath base, name
        ut\assertTrue (nil != lfs.mkdir directory), "could not create #{name}"
        written = assert io.open pathOps.joinPath(directory, "probe.txt"), "w"
        written\write FILE_BODY
        written\close!
        directories[#directories + 1] = directory

      {:base, :directories}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      fileOps.remove ctx.base, true if ctx and ctx.base

    attributes_readsANonAsciiPath: (ut, ctx) ->
      for directory in *ctx.directories
        ut\assertEquals lfs.attributes(directory, "mode"), "directory"

        info = lfs.attributes pathOps.joinPath directory, "probe.txt"
        ut\assertTable info
        ut\assertEquals info.mode, "file"
        ut\assertEquals info.size, #FILE_BODY
        ut\assertNumber info.modification

    -- FileOps tells a missing file from a failed call by the third return, so the layer has to keep
    -- reporting one rather than collapsing both into a bare nil
    attributes_missingNonAsciiPathReportsNotFound: (ut, ctx) ->
      ENOENT = 2
      for directory in *ctx.directories
        value, err, code = lfs.attributes pathOps.joinPath(directory, "absent.txt"), "mode"
        ut\assertNil value
        ut\assertTrue err == nil or code == ENOENT, "expected a not-found report, got #{tostring err}"

    -- a name that comes back in the code page breaks every path built from it, so the listing has to
    -- return the bytes the directory was created with
    dir_listsANonAsciiNameVerbatim: (ut, ctx) ->
      listed = {}
      listed[entry] = true for entry in lfs.dir ctx.base

      for name in *{NAME_LATIN, NAME_CJK}
        ut\assertTrue listed[name],
          "#{name} came back as #{toByteList table.concat [entry for entry in pairs listed], ''}"

    dir_listsTheEntriesOfANonAsciiDirectory: (ut, ctx) ->
      for directory in *ctx.directories
        entries = [entry for entry in lfs.dir directory when entry != "." and entry != ".."]
        ut\assertItemsEqual entries, {"probe.txt"}

    dir_raisesForAMissingDirectory: (ut, ctx) ->
      ut\assertError -> lfs.dir pathOps.joinPath ctx.base, "no-such-directory"

    mkdir_andRmdirRoundTripANonAsciiPath: (ut, ctx) ->
      for directory in *ctx.directories
        nested = pathOps.joinPath directory, NAME_LATIN
        ut\assertTrue (nil != lfs.mkdir nested)
        ut\assertEquals lfs.attributes(nested, "mode"), "directory"
        ut\assertTrue (nil != lfs.rmdir nested)
        ut\assertNil lfs.attributes nested, "mode"

    chdir_andCurrentdirRoundTripANonAsciiPath: (ut, ctx) ->
      previous = lfs.currentdir!
      ut\assertString previous

      for directory in *ctx.directories
        ut\assertTrue (nil != lfs.chdir directory)
        current = lfs.currentdir!
        lfs.chdir previous
        ut\assertEquals toByteList(current), toByteList directory

    touch_setsTheTimesOfANonAsciiPath: (ut, ctx) ->
      for directory in *ctx.directories
        path = pathOps.joinPath directory, "probe.txt"
        ut\assertTrue lfs.touch path, 1000000000, 1000000001
        ut\assertEquals lfs.attributes(path, "access"), 1000000000
        ut\assertEquals lfs.attributes(path, "modification"), 1000000001

    touch_missingNonAsciiPathReportsFailure: (ut, ctx) ->
      touched, err = lfs.touch pathOps.joinPath ctx.directories[1], "absent.txt"
      ut\assertNil touched
      ut\assertString err

    link_hardLinksANonAsciiPath: (ut, ctx) ->
      for directory in *ctx.directories
        source = pathOps.joinPath directory, "probe.txt"
        target = pathOps.joinPath directory, "hard.txt"
        linked, err = lfs.link source, target
        ut\assertNotNil linked, "could not hard link: #{tostring err}"
        ut\assertEquals lfs.attributes(target, "size"), #FILE_BODY
        os.remove target

    -- the lock is userdata with a free method on every platform, and taking it twice has to fail
    lockDir_locksAndReleasesANonAsciiPath: (ut, ctx) ->
      for directory in *ctx.directories
        lock, err = lfs.lock_dir directory
        ut\assertNotNil lock, "could not lock: #{tostring err}"
        ut\assertFunction lock.free

        again, againErr = lfs.lock_dir directory
        ut\assertNil again
        ut\assertString againErr

        lock\free!
        ut\assertNotNil lfs.lock_dir directory

    symlinkAttributes_readsANonAsciiPathWithoutFollowing: (ut, ctx) ->
      for directory in *ctx.directories
        info = lfs.symlinkattributes pathOps.joinPath directory, "probe.txt"
        ut\assertTable info
        ut\assertEquals info.mode, "file"
        ut\assertEquals info.size, #FILE_BODY

    -- the rock raises here rather than reporting the directory, which the layer answers instead
    symlinkAttributes_readsANonAsciiDirectory: (ut, ctx) ->
      ut\skip "only the layer answers a directory here" unless isWindows

      for directory in *ctx.directories
        info = lfs.symlinkattributes directory
        ut\assertTable info
        ut\assertEquals info.mode, "directory"
        ut\assertEquals info.target, directory

    install_reportsInstalledOnWindowsOnly: (ut) ->
      installed, reason = lfsUnicodePatch.install!
      if isWindows
        ut\assertTrue installed
        ut\assertNil reason
      else
        ut\assertFalse installed
        ut\assertString reason

    -- on Windows a non-ASCII path is answered by the layer's own reconstruction, which stands in for
    -- the rock's table and so has to carry the same fields
    attributes_reportsTheFieldSetTheRockDoes: (ut, ctx) ->
      ut\skip "only Windows answers a non-ASCII path from the layer" unless isWindows

      info = lfs.attributes pathOps.joinPath ctx.directories[1], "probe.txt"
      ut\assertTable info
      for field in *{"dev", "ino", "mode", "nlink", "uid", "gid", "rdev", "access", "modification",
        "change", "size", "permissions"}
        ut\assertNotNil info[field], "missing field '#{field}'"
      ut\assertMatches info.permissions, "^[r%-][w%-][x%-][r%-][w%-][x%-][r%-][w%-][x%-]$"

    attributes_readsOneFieldAndFillsAGivenTable: (ut, ctx) ->
      path = pathOps.joinPath ctx.directories[1], "probe.txt"
      ut\assertEquals lfs.attributes(path, "size"), #FILE_BODY

      target = {}
      ut\assertIs lfs.attributes(path, target), target
      ut\assertEquals target.mode, "file"

    attributes_raisesForAnUnknownField: (ut, ctx) ->
      path = pathOps.joinPath ctx.directories[1], "probe.txt"
      ut\assertErrorMsgMatches lfs.attributes, {path, "nonesuch"}, "invalid attribute name"
  }
