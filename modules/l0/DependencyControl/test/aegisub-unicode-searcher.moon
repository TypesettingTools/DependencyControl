-- cspell:ignore mlaut
-- Pins the port of the module loader Aegisub installs in place of Lua's own path searcher. The stock
-- searcher opens the file it resolved in C, where the path arrives in the process code page, so on
-- Windows a module whose path holds a non-ASCII byte loads only through this one. Inside Aegisub
-- these tests exercise the searcher beside its own loader, which resolves such a path already.
-- Called from test.moon as: (controls\requireTest "aegisub-unicode-searcher")!
->
  ffi = require "ffi"
  fileOps = require "l0.DependencyControl.file-ops"
  lfs = require "lfs"
  pathOps = require "l0.DependencyControl.path-ops"
  unicodeSearcher = require "l0.AegisubShims.unicode-searcher"

  {__search: search} = unicodeSearcher

  -- ü and 日本語 in UTF-8, one representable in a Western code page and one not, so a run on either
  -- kind of machine still has a name the stock searcher would get wrong
  NAME_LATIN = "\195\188mlaut"
  NAME_CJK = "\230\151\165\230\156\172\232\170\158"

  isWindows = ffi.os == "Windows"

  ---Writes a module the searcher can find, and gives back the path it wrote.
  writeModule = (dir, name, body) ->
    path = pathOps.joinPath dir, "#{name}.lua"
    handle = assert io.open path, "w"
    handle\write body
    handle\close!
    path

  {
    _description: "The .lua package searcher that resolves package.path through io.open."

    ---@param ut UnitTest
    _setup: (ut) ->
      dir, err = fileOps.createTempDir!
      ut\assertNotNil dir, err
      previousPath = package.path
      package.path = "#{pathOps.joinPath dir, '?'}.lua;#{package.path}"
      {:dir, :previousPath}

    ---@param ut UnitTest
    _teardown: (ut, ctx) ->
      return unless ctx
      package.path = ctx.previousPath if ctx.previousPath
      fileOps.remove ctx.dir, true if ctx.dir

    search_loadsANonAsciiPath: (ut, ctx) ->
      for name in *{NAME_LATIN, NAME_CJK}
        writeModule ctx.dir, name, "return {which = [[#{name}]]}"
        chunk = search name
        ut\assertFunction chunk
        ut\assertEquals chunk(name).which, name

    -- the chunk has to be named after the file, or every traceback through the module reports it as
    -- a string chunk and the location is lost
    search_namesTheChunkAfterTheFile: (ut, ctx) ->
      path = writeModule ctx.dir, NAME_LATIN, "return {}"
      ut\assertEquals debug.getinfo(search(NAME_LATIN), "S").source, "@#{path}"

    search_resolvesDotsToDirectories: (ut, ctx) ->
      lfs.mkdir pathOps.joinPath ctx.dir, "nested"
      writeModule pathOps.joinPath(ctx.dir, "nested"), "probe", "return {which = 'nested'}"
      chunk = search "nested.probe"
      ut\assertFunction chunk
      ut\assertEquals chunk("nested.probe").which, "nested"

    -- returning nothing keeps require's "module not found" message free of a second path list
    search_unresolvedNameYieldsNoLoader: (ut) ->
      ut\assertZero select "#", search "no.such.module.anywhere"

    -- a file that opens but doesn't compile has to raise, the way the stock searcher does, or
    -- require falls through to "module not found" and buries the syntax error
    search_raisesForAFileItCannotCompile: (ut, ctx) ->
      writeModule ctx.dir, "brokenProbe", "return {which = "
      ut\assertErrorMsgMatches search, {"brokenProbe"}, "^error loading module 'brokenProbe' from file"

    -- reading through io.open is the whole point: it is the one the host replaces on Windows
    search_readsThroughIoOpen: (ut) ->
      (ut\stub io, "open")\calls (path) ->
        return nil unless path\match "stubbedProbe%.lua$"
        {
          read: => "return {which = 'stubbed'}"
          close: => true
        }

      chunk = search "stubbedProbe"
      ut\assertFunction chunk
      ut\assertEquals chunk("stubbedProbe").which, "stubbed"

    install_reportsInstalledOnWindowsOnly: (ut) ->
      installed, reason = unicodeSearcher.install!
      if isWindows
        ut\assertTrue installed
        ut\assertNil reason
      else
        ut\assertFalse installed
        ut\assertString reason

    install_doesNotAppendTwice: (ut) ->
      loaders = package.loaders or package.searchers
      before = #loaders
      unicodeSearcher.install!
      unicodeSearcher.install!
      ut\assertEquals #loaders, before
  }
