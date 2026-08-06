-- Pins the backend auto-selection on the umbrella: the default install goes through it, each
-- contract prefers its native implementation, and availability comes from the backends' own FFI
-- probes rather than the platform name.
-- Called from test.moon as: (controls\requireTest "aegisub-text-extents-selection")!
->
  haveShims, shims = pcall require, "l0.AegisubShims"
  haveGdi, gdi = pcall require, "l0.AegisubShims.text-extents-backends.gdi"
  haveCoreText, coretext = pcall require, "l0.AegisubShims.text-extents-backends.coretext"
  haveFreeType, freetype = pcall require, "l0.AegisubShims.text-extents-backends.freetype"
  havePango, pangoBackend = pcall require, "l0.AegisubShims.text-extents-backends.pango"

  {
    _description: "The text-extents backend selection, against the per-contract preference order."
    _condition: ->
      return haveShims and haveGdi and haveCoreText and haveFreeType and havePango, "needs the backend modules to load"

    selectTextExtentsBackend_defaultIsTheInstalledBackend: (ut) ->
      measure = shims.selectTextExtentsBackend!
      ut\skip "no Windows-contract backend is available here" unless measure
      ut\assertIs shims.getTextExtentsBackend!, measure

    selectTextExtentsBackend_prefersTheNativeWindowsImplementation: (ut) ->
      measure, name = shims.selectTextExtentsBackend shims.TextExtentsMetricMode.AegisubWindows
      if gdi.isAvailable
        ut\assertIs measure, gdi.measure
        ut\assertEquals name, "GDI"
      elseif coretext.isAvailable
        ut\assertIs measure, coretext.measure
        ut\assertEquals name, "CoreText"
      elseif freetype.isAvailable
        ut\assertIs measure, freetype.measure
        ut\assertEquals name, "FreeType/AegisubWindows"
      else
        ut\assertNil measure

    selectTextExtentsBackend_prefersPangoForTheLinuxContract: (ut) ->
      measure, name = shims.selectTextExtentsBackend shims.TextExtentsMetricMode.AegisubLinux
      if pangoBackend.isAvailable
        ut\assertIs measure, pangoBackend.measure
        ut\assertEquals name, "Pango"
      elseif freetype.isAvailable
        ut\assertEquals name, "FreeType/AegisubLinux"
        ut\assertType measure, "function"
      else
        ut\assertNil measure

    -- the FreeType Linux-mode backend is built on first selection, then handed back unchanged
    selectTextExtentsBackend_memoizesABuiltBackend: (ut) ->
      first = shims.selectTextExtentsBackend shims.TextExtentsMetricMode.AegisubLinux
      second = shims.selectTextExtentsBackend shims.TextExtentsMetricMode.AegisubLinux
      ut\skip "no Linux-contract backend is available here" unless first
      ut\assertIs second, first

    selectTextExtentsBackend_reportsWhyNothingCouldBePicked: (ut) ->
      measure, nameOrErr = shims.selectTextExtentsBackend shims.TextExtentsMetricMode.AegisubLinux
      return ut\skip "a Linux-contract backend is available here" if measure
      ut\assertMatches nameOrErr, "could load"

    selectTextExtentsBackend_rejectsAnUnknownMode: (ut) ->
      ut\assertErrorMsgMatches (-> shims.selectTextExtentsBackend 99), {}, "Invalid value"
  }
