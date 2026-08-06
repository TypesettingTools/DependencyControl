-- cspell:ignore
-- Headless stand-in for Aegisub's `aegisub.unicode` module. Four of its seven functions are byte
-- arithmetic over UTF-8 and are reproduced here directly; the three case conversions are ICU calls in
-- Aegisub (`UnicodeString::toUpper/toLower/foldCase`) and reach the system ICU through the FFI, which
-- is the same library Aegisub itself links against wherever a distro provides one. ICU is lazy-loaded on
-- first use, so the shims don't fail to initialize when the library can't be found.
-- The library name and its exported symbols vary by platform: Windows and macOS export unversioned names,
-- while Linux distributions build with ICU's default renaming, so every symbol carries the major version
-- (e.g. `u_strToUpper_74`). The version can't be derived from the file name when an unversioned `libicuuc.so`
-- symlink is what loads, so we resort to probing for versioned sonames in a wide range, instead.

ffi = require "ffi"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"
unicode = require "l0.DependencyControl.unicode"
utils = require "l0.DependencyControl.utils"

-- Aegisub's own functions take each character's width from its lead byte and decode whatever follows,
-- so the stand-in does too, and answers as Aegisub does for the malformed input karaskel is known to
-- hand it. A caller wanting those bytes reported instead switches this to Strict.
decodeMode = unicode.DecodeMode.AegisubCompatibility

msgs = {
  requireIcu: {
    unavailable: "The headless stand-in for aegisub.unicode needs a system ICU for case conversion, and none could be loaded."
  }
  convert: {
    failed: "ICU reported error %d while converting a string."
  }
}

-- Bounds for the versioned soname probe. ICU sees major releases about twice a year and stood at 78 in early 2026.
ICU_VERSION_NEWEST = 120 -- plenty of headroom for the next 20 years if the release cadence continues
ICU_VERSION_OLDEST = 60 -- shipped in 2017 and predates every distribution release still supported

-- ICU's default fold-case option. The alternative, U_FOLD_CASE_EXCLUDE_SPECIAL_I, folds the Turkic
-- dotted and dotless i to each other's plain counterparts.
U_FOLD_CASE_DEFAULT = 0

Utf16Buffer = ffi.typeof "uint16_t[?]" -- matches ICU's UChar*
Utf8Buffer = ffi.typeof "char[?]"
Int32Out = ffi.typeof "int32_t[1]" -- matches ICU's UErrorCode* and its int32_t* length out-parameters

---One ICU entry point this module binds, with the necessary information to find and declare it
-- to the FFI with whatever version suffix the loaded library ends up using.
---@class IcuFunctionSpec
---@field field string Key the bound function takes in the table `requireIcu` returns.
---@field symbol string The ICU C symbol, without the version suffix a Linux build appends to it.
---@field signature string A cdef declaration with `%s` standing in for the suffixed symbol name.

---@type IcuFunctionSpec[]
icuFunctions = {
  -- Converts a UTF-8 string to UTF-16, substituting a replacement character for invalid sequences.
  {field: "fromUtf8", symbol: "u_strFromUTF8WithSub",
    signature: "int32_t %s(uint16_t*, int32_t, int32_t*, const char*, int32_t, int32_t, int32_t*, int32_t*);"}
  -- Converts a UTF-16 string to UTF-8, substituting a replacement character for invalid sequences.
  {field: "toUtf8", symbol: "u_strToUTF8WithSub",
    signature: "char* %s(char*, int32_t, int32_t*, const uint16_t*, int32_t, int32_t, int32_t*, int32_t*);"}
  -- Transforms the characters in a string into lowercase. Results are locale-dependent (host locale in our case since
  -- we are not passing any) and context-dependent (e.g. Greek capital letter Σ lowercased to σ in the middle of a word,
  -- but to ς at the end of a word).
  {field: "toLower", symbol: "u_strToLower",
    signature: "int32_t %s(uint16_t*, int32_t, const uint16_t*, int32_t, const char*, int32_t*);"}
    -- Transforms the characters in a string into uppercase. Casing is locale-dependent and context-sensitive.
  {field: "toUpper", symbol: "u_strToUpper",
    signature: "int32_t %s(uint16_t*, int32_t, const uint16_t*, int32_t, const char*, int32_t*);"}
  -- Transforms the characters in a string into a representation for case-insensitive comparison and string matching.
  -- Distinct from lowercase conversion in that it also normalizes characters that are not case variants of each other,
  -- such as the German sharp s (ß → ss) and the position-dependent Greek lowercase sigma variants (ς/σ → σ).
  {field: "foldCase", symbol: "u_strFoldCase",
    signature: "int32_t %s(uint16_t*, int32_t, const uint16_t*, int32_t, uint32_t, int32_t*);"}
}

-- The handle ffi.load returns owns the loaded library and unloads it when collected, leaving every
-- function pointer bound from it dangling. Holding it here keeps the library mapped for the process.
local icu, icuLibrary, icuUnavailable

---An ICU library to try loading, carrying the version its name encodes so the symbol search can start
---from it rather than recovering it from the name afterwards.
---@class IcuLibraryCandidate
---@field name string The name to hand to `ffi.load`.
---@field version? number The ICU major version the name pins, absent for an unversioned name.

---Libraries to try, most likely first. Linux encodes the major version in the file name, so the
---unversioned symlink (present only with the development package) is tried before the versioned ones.
---@return IcuLibraryCandidate[] candidates
getLibraryCandidates = ->
  switch ffi.os
    when "Windows" then return {{name: "icuuc"}, {name: "icu"}}
    when "OSX" then return {{name: "libicucore.dylib"}, {name: "libicucore.A.dylib"}, {name: "libicuuc.dylib"}}

  candidates = {{name: "libicuuc.so"}}
  for version = ICU_VERSION_NEWEST, ICU_VERSION_OLDEST, -1
    candidates[#candidates + 1] = {name: "libicuuc.so.#{version}", :version}
  return candidates

---Binds one ICU function under a given symbol suffix.
---@param library userdata The loaded ICU library.
---@param entry IcuFunctionSpec The entry point to bind.
---@param suffix string The version suffix to append, empty for an unsuffixed build.
---@return function? bound Nil when the symbol isn't exported under that name.
bindSymbol = (library, entry, suffix) ->
  name = entry.symbol .. suffix
  _, prefixedNames = ffiBinding.declare entry.signature\format(name), nil, {name}

  ok, bound = pcall -> library[prefixedNames[name]]
  return ok and bound or nil

---Finds the symbol suffix this build of ICU uses, which may be either the version pinned in the file name
---or none at all if the build was configured with `--disable-renaming`.
---@param library userdata The loaded ICU library.
---@param pinnedVersion? number The version the loaded name pinned, tried before anything else.
---@return string? suffix Empty for an unsuffixed build, `_74` and the like otherwise; nil when none match.
-- A distribution that ships the unversioned symlink in its main package, Arch among them, pins no
-- version, so the search below is the path most Linux boxes take.
findSymbolSuffix = (library, pinnedVersion) ->
  probe = icuFunctions[1] -- all five entries share the suffix, so any will do
  if pinnedVersion
    suffix = "_#{pinnedVersion}"
    return suffix if bindSymbol library, probe, suffix

  return "" if bindSymbol library, probe, ""
  for version = ICU_VERSION_NEWEST, ICU_VERSION_OLDEST, -1
    suffix = "_#{version}"
    return suffix if bindSymbol library, probe, suffix

---Loads ICU and binds the functions the conversions need, raising when no build can be reached.
---@param errorLevel number Stack level to blame when ICU is unavailable.
---@return table<string, function> icu The bound ICU functions, keyed by each spec's `field`.
requireIcu = (errorLevel = 2) ->
  return icu if icu
  error msgs.requireIcu.unavailable, errorLevel + 1 if icuUnavailable

  for candidate in *getLibraryCandidates!
    loaded, library = pcall ffi.load, candidate.name
    continue unless loaded

    suffix = findSymbolSuffix library, candidate.version
    continue unless suffix

    bound = {}
    bound[entry.field] = bindSymbol library, entry, suffix for entry in *icuFunctions
    -- a library exporting only some of them is not one we can use; keep looking
    continue unless bound.fromUtf8 and bound.toUtf8 and bound.toUpper and bound.toLower and bound.foldCase

    icu, icuLibrary = bound, library
    return icu

  icuUnavailable = true
  error msgs.requireIcu.unavailable, errorLevel + 1

---Raises when ICU reported a failure. Codes at or below zero are success or a warning.
---@param status ffi.cdata* The int32_t UErrorCode out-parameter ICU wrote to.
assertIcuOk = (status) ->
  error msgs.convert.failed\format(status[0]), 4 if status[0] > 0

---Applies one ICU case operation to a UTF-8 string, converting in and out of UTF-16 around it.
---@param str string The subject, in UTF-8.
---@param apply fun(dest: ffi.cdata*, capacity: number, source: ffi.cdata*, sourceLength: number, status: ffi.cdata*): number The case operation, with its locale or options argument already bound.
---@return string converted The result, in UTF-8.
---Runs one of ICU's case operations over a UTF-8 string, converting to UTF-16 around it and back.
---@param str string The string to convert.
---@param operation function The bound ICU case operation to run.
---@param extra? string|number The operation's fifth argument: the locale for a case conversion, nil
--- selecting the default one, and the fold-case options for a fold.
---@return string converted
convert = (str, operation, extra) ->
  status = Int32Out 0
  written = Int32Out 0

  -- Each ICU call is preflighted with a null destination to learn the length it needs, which reports
  -- a buffer overflow by design, so the status is cleared before the call that does the work.
  icu.fromUtf8 nil, 0, written, str, #str, unicode.REPLACEMENT_CODE_POINT, nil, status
  sourceLength = written[0]
  source = Utf16Buffer sourceLength + 1
  status[0] = 0
  icu.fromUtf8 source, sourceLength + 1, written, str, #str, unicode.REPLACEMENT_CODE_POINT, nil, status
  assertIcuOk status

  status[0] = 0
  convertedLength = operation nil, 0, source, sourceLength, extra, status
  converted = Utf16Buffer convertedLength + 1
  status[0] = 0
  operation converted, convertedLength + 1, source, sourceLength, extra, status
  assertIcuOk status

  status[0] = 0
  icu.toUtf8 nil, 0, written, converted, convertedLength, unicode.REPLACEMENT_CODE_POINT, nil, status
  resultLength = written[0]
  result = Utf8Buffer resultLength + 1
  status[0] = 0
  icu.toUtf8 result, resultLength + 1, written, converted, convertedLength, unicode.REPLACEMENT_CODE_POINT, nil, status
  assertIcuOk status

  return ffi.string result, written[0]

---Headless stand-in for Aegisub's `aegisub.unicode` module, reached under that require id once
---l0.AegisubShims has claimed it, so a script requiring it loads and can be tested outside Aegisub.
---
---`charwidth`, `chars`, `len` and `codepoint` are pure UTF-8 arithmetic and always work. The three case
---conversions call the system ICU, the same engine Aegisub uses, and raise where none is reachable.
---@class AegisubUnicode
local Unicode
Unicode = {
  ---Returns the number of bytes the character starting at a byte offset occupies.
  ---@param str string The string to read.
  ---@param byteOffset? number Byte offset of the character's first byte (default 1).
  ---@return number width Byte width, 1 through 4; 1 for an offset past the end.
  charwidth: (str, byteOffset) ->
    return assert unicode.getCharWidth str, byteOffset, decodeMode

  ---Iterates the characters of a string.
  ---@param str string The string to walk.
  ---@return fun(): string?, number? iterator Yields each character with its 1-based character index.
  chars: (str) ->
    return assert unicode.iterateChars str, decodeMode

  ---Counts the characters in a string, in time proportional to its byte length.
  ---@param str string The string to measure.
  ---@return number length Character count, not byte count.
  len: (str) ->
    return assert unicode.getLength str, decodeMode

  ---Returns the code point of the first character of a string.
  ---@param str string The string to decode.
  ---@return number codepoint
  codepoint: (str) ->
    return assert unicode.getCodePoint str, 1, decodeMode

  ---Converts a string to upper case, following the conventions of the default locale.
  ---@param str string The string to convert.
  ---@return string converted
  to_upper_case: (str) ->
    utils.assertArgType str, 1, "string"
    requireIcu!
    return convert str, icu.toUpper

  ---Converts a string to lower case, following the conventions of the default locale.
  ---@param str string The string to convert.
  ---@return string converted
  to_lower_case: (str) ->
    utils.assertArgType str, 1, "string"
    requireIcu!
    return convert str, icu.toLower

  ---Folds a string's case, for locale-independent case-insensitive comparison.
  ---@param str string The string to fold.
  ---@return string folded
  to_fold_case: (str) ->
    utils.assertArgType str, 1, "string"
    requireIcu!
    return convert str, icu.foldCase, U_FOLD_CASE_DEFAULT
}

---Shim-only configuration, namespaced so it cannot collide with Aegisub's own module surface.
---@class AegisubUnicodeControls
Unicode.__depCtrl = {
  ---Sets how the four UTF-8 functions treat malformed input. Under `Strict` they raise on bytes
  ---`AegisubCompatibility` would have walked past, which is what a caller inspecting its own text wants.
  ---@param mode UnicodeDecodeMode The mode to measure by.
  ---@return UnicodeDecodeMode previous The mode in force until now, to restore later.
  setDecodeMode: (mode) ->
    valid, modeErr = unicode.DecodeMode\validate mode, "mode"
    assert valid, modeErr

    previous = decodeMode
    decodeMode = mode
    return previous

  ---Returns the mode the four UTF-8 functions currently decode by.
  ---@return UnicodeDecodeMode mode
  getDecodeMode: -> decodeMode
}

return Unicode
