-- Windows-only tests for helpers/ffi-windows: pins the UTF-8 to UTF-16 conversion the *W Win32 APIs
-- are fed, including its rejection of malformed input, which is what keeps a mangled path or URL from
-- reaching CreateFileW or InternetOpenUrlW. Skipped elsewhere (see _condition), where kernel32 and the
-- wide APIs do not exist.
-- Called from test.moon as: (controls\requireTest "ffi-windows")!
() ->
  ffi = require "ffi"
  ffiWindows = require "l0.DependencyControl.helpers.ffi-windows"

  isWindows = ffi.os == "Windows"

  ---Reads a wide buffer back as a list of UTF-16 code units, terminator excluded.
  ---@param buffer ffi.cdata* The wchar_t[] to read.
  ---@param count number How many units to read.
  ---@return number[] units
  readUnits = (buffer, count) ->
    return [buffer[i] for i = 0, count - 1]

  {
    _description: "Tests for the ffi-windows helper's wide-character conversion."
    _condition: -> isWindows and ffiWindows.isAvailable, "needs Windows with kernel32 loaded"

    toWide_convertsAscii: (ut) ->
      buffer, err = ffiWindows.toWide "ab"
      ut\assertNotNil buffer, err
      ut\assertEquals readUnits(buffer, 2), {0x61, 0x62}

    toWide_terminatesTheBuffer: (ut) ->
      buffer = ffiWindows.toWide "ab"
      ut\assertEquals buffer[2], 0

    -- ü is one UTF-16 unit from two UTF-8 bytes, 日 is one from three: the counts have to come from
    -- the conversion rather than the byte length
    toWide_convertsMultiByteSequences: (ut) ->
      ut\assertEquals readUnits(ffiWindows.toWide("\195\188"), 1), {0x00FC}
      ut\assertEquals readUnits(ffiWindows.toWide("\230\151\165"), 1), {0x65E5}

    -- a code point above the BMP becomes a surrogate pair, so one character is two units
    toWide_convertsAstralCodePointToSurrogatePair: (ut) ->
      buffer = ffiWindows.toWide "\240\159\152\128" -- U+1F600
      ut\assertEquals readUnits(buffer, 2), {0xD83D, 0xDE00}
      ut\assertEquals buffer[2], 0

    toWide_emptyStringYieldsATerminatorOnly: (ut) ->
      buffer, err = ffiWindows.toWide ""
      ut\assertNotNil buffer, err
      ut\assertEquals buffer[0], 0

    -- 0xFF never appears in well-formed UTF-8, and a truncated sequence is the likelier real-world
    -- case; both have to be refused rather than silently substituted with U+FFFD
    toWide_rejectsMalformedUtf8: (ut) ->
      for malformed in *{"\255", "bad\255name", "\230\151"}
        buffer, err = ffiWindows.toWide malformed
        ut\assertNil buffer
        ut\assertString err

    toWide_errorNamesTheOffendingString: (ut) ->
      _, err = ffiWindows.toWide "\255marker"
      ut\assertNotNil string.find err, "marker", 1, true

    -- each pair is the UTF-8 text and how many UTF-16 units it occupies, the terminator excluded
    fromWide_roundTripsThroughToWide: (ut) ->
      for {text, units} in *{{"ab", 2}, {"\195\188", 1}, {"\230\151\165", 1}, {"\240\159\152\128", 2}}
        ut\assertEquals ffiWindows.fromWide(ffiWindows.toWide(text), units), text

    fromWide_zeroLengthYieldsEmptyString: (ut) ->
      ut\assertEquals ffiWindows.fromWide(ffiWindows.toWide("ab"), 0), ""

    -- CreateFileW on an unreachable drive fails with a code the system can describe, which is what a
    -- user-submitted log has to carry instead of a bare "could not open"
    describeLastError_rendersASystemCode: (ut) ->
      kernel32 = ffiWindows.kernel32
      pcall ffi.cdef, "void* CreateFileW(const wchar_t*, unsigned long, unsigned long, void*, unsigned long, unsigned long, void*);"
      kernel32.CreateFileW ffiWindows.toWide("Z:\\no\\such\\dir\\x.tmp"), 0x40000000, 3, nil, 4, 0x80, nil
      described = ffiWindows.describeLastError!

      ut\assertString described
      ut\assertNotNil described\match "%(error %d+%)"
      ut\assertGreaterThan #described, #"(error 0)"

    -- WinINet's codes are absent from the system table, so its own module has to be searched too
    describeLastError_rendersAModuleSpecificCode: (ut) ->
      kernel32 = ffiWindows.kernel32
      pcall ffi.cdef, "void __stdcall SetLastError(unsigned long);"
      kernel32.SetLastError 12007 -- ERROR_INTERNET_NAME_NOT_RESOLVED
      ut\assertNotNil ffiWindows.describeLastError("wininet.dll")\match "resolved"

      kernel32.SetLastError 12007
      ut\assertEquals ffiWindows.describeLastError!, "error 12007"
  }
