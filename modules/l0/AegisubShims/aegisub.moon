-- Headless shim for the Aegisub automation Lua API.
-- Installs `aegisub` as a global before any module that requires Aegisub-specific APIs.
--
-- Configurable via environment variables:
--   DEPCTRL_USER_DIR  — base for ?user / ?local  (default: %APPDATA%\Aegisub / ~/.aegisub)
--   DEPCTRL_DATA_DIR  — base for ?data            (default: same as ?user; real Aegisub uses exe dir)
--   DEPCTRL_STATE_DIR — base for ?state           (default: same as ?user)
--   DEPCTRL_TEMP_DIR  — base for ?temp            (default: %TEMP% / /tmp)

ffi = require "ffi"
AegisubSubtitles = require "l0.AssParser.AegisubSubtitles"
ass = require "l0.AssParser.ass"
karaoke = require "l0.AssParser.karaoke"
Scanner = require "l0.AssParser.Scanner"
{:DialectName} = require "l0.AssParser.dialects"
utils = require "l0.DependencyControl.utils"

msgs = {
  parse_karaoke_data: {
    noExtradata: "A dialogue line has to include an `extra`data table, since Aegisub before 3.5.0 crashes on one without it."
  }
  text_extents: {
    noBackend: "aegisub.text_extents needs font metrics, which nothing here can measure until a backend is installed through AegisubShims.setTextExtentsBackend."
  }
  set_undo_point: {
    outsideMacro: "Attempt to set an undo point in a context where it makes no sense to do so."
  }
  setScript: {
    notAScript: "Expected an AssScript, got a %s."
  }
  runMacro: {
    noScript: "No script has been set; set one through AegisubShims.setScript first."
    unknown: "No macro named '%s' is registered."
    refused: "The macro's validation function refused to run it on this file."
  }
}

karaokeReader = karaoke.Reader DialectName.Aegisub
karaokeScanner = Scanner DialectName.Aegisub

---Measures a run of text set in a style, returning what `aegisub.text_extents` returns.
---@alias AegisubTextExtentsBackend fun(style: AegisubStyleLine, text: string): number, number, number, number

-- declared ahead of the table below, whose text_extents closes over it
local textExtentsBackend

-- Every macro passed to `register_macro`, in registration order.
registeredMacros = {}
-- Set only while a macro's processing function runs, so `set_undo_point` throws at any other time, as
-- it does in Aegisub.
local undoPointSetter

---Returns the selection Aegisub passes to a macro when nothing is selected: the first dialogue line.
---@param object AegisubSubtitles The subtitles object the macro receives.
---@return integer[] selectedLines The index of the first dialogue line, empty if there is none.
defaultSelection = (object) ->
  for index = 1, #object
    return {index} if object[index].class == ass.LineClass.Dialogue
  {}

isWindows = ffi.os == "Windows"
pathSep = isWindows and "\\" or "/"

tempDir = os.getenv("DEPCTRL_TEMP_DIR") or (isWindows and (os.getenv("TEMP")) or "/tmp")
userDir = os.getenv("DEPCTRL_USER_DIR") or
  (isWindows and "#{os.getenv 'APPDATA'}\\Aegisub" or "#{os.getenv 'HOME'}/.aegisub")
dataDir = os.getenv("DEPCTRL_DATA_DIR") or userDir
stateDir = os.getenv("DEPCTRL_STATE_DIR") or userDir

userPathsAddedToPackagePathLua = {}
userPathsAddedToPackagePathMoon = {}

makePackagePaths = (dir, ext) -> {"#{dir}/?.#{ext}", "#{dir}/?/init.#{ext}"}

-- Canonical token table matching libaegisub/path.cpp.
-- Empty string means "unset" — decode_path returns the path unchanged (same as real Aegisub).
-- ?audio, ?script, ?video are empty because no file is loaded headlessly.
pathTokens = {
  "?audio": ""
  "?data": dataDir
  "?dictionary": dataDir .. pathSep .. "dictionaries"
  "?local": userDir
  "?script": ""
  "?state": stateDir
  "?temp": tempDir
  "?user": userDir
  "?video": ""
}

-- Sorted longest-first so ?dictionary matches before ?data. Rebuilt whenever a token
-- changes; decodePath closes over the `sortedTokens` upvalue, so reassigning it here is
-- enough to update the resolver.
local sortedTokens
rebuildSortedTokens = ->
  sortedTokens = [{spec, dir} for spec, dir in pairs pathTokens]
  table.sort sortedTokens, (a, b) -> #a[1] > #b[1]
rebuildSortedTokens!

-- Normalize a token name to its canonical "?name" form so callers may pass either
-- "user" or "?user".
normalizeToken = (spec) ->
  "string" == type(spec) and (spec\sub(1, 1) == "?" and spec or "?#{spec}") or spec

---Points an Aegisub path token (e.g. "?user", "?temp") at a different directory.
---Lets headless callers relocate where DepCtrl reads/writes without environment variables.
---@param spec string The token to set, with or without the leading "?" ("user" or "?user").
---@param dir? string The directory to resolve the token to; nil/"" marks it unset.
---@return string? dir The value the token now resolves to.
setPathToken = (spec, dir) ->
  normalizedToken = normalizeToken spec
  previousDir = pathTokens[normalizedToken]
  return dir if previousDir == dir

  pathTokens[normalizedToken] = dir or ""
  rebuildSortedTokens!

  if normalizedToken == "?user"
    -- Re-point the module search paths at the new ?user dir, dropping our prior additions so they
    -- don't pile up. Order of the surviving entries is preserved, so module shadowing (first match
    -- wins) holds.
    modulesDir = "#{dir}/automation/modules"
    package.path, userPathsAddedToPackagePathLua = utils.mergeSearchPath(
      package.path, makePackagePaths(modulesDir, "lua"), userPathsAddedToPackagePathLua)
    package.moonpath, userPathsAddedToPackagePathMoon = utils.mergeSearchPath(
      package.moonpath, makePackagePaths(modulesDir, "moon"), userPathsAddedToPackagePathMoon)
  return dir

---Returns the directory an Aegisub path token currently resolves to.
---@param spec string The token to query, with or without the leading "?".
---@return string? dir The configured directory, or nil if the token is unknown.
getPathToken = (spec) ->
  dir = pathTokens[normalizeToken spec]
  return dir if dir and dir != ""

decodePath = (path) ->
  for {spec, dir} in *sortedTokens
    if path\sub(1, #spec) == spec
      -- Empty dir means token is unset — return path as-is (Aegisub behavior).
      return path if dir == ""
      suffix = path\sub #spec + 1
      -- Consume the separator that follows the token, if any.
      suffix = suffix\sub 2 if suffix\sub(1, 1) == "/" or suffix\sub(1, 1) == "\\"
      return suffix == "" and dir or dir .. pathSep .. suffix
  return path -- no token: return as-is

---Writes a log message to stderr, interpolating printf-style arguments like real Aegisub. Accepts both
---call forms: `(msg, ...)` and `(level, msg, ...)` with a numeric level, which is ignored here.
---The message is written verbatim with no trailing newline: callers append their own, so adding one
---would break same-line output.
---@param level number|string The numeric log level, or the message when the level is omitted.
---@param msg? any The message (or its first format argument in the level-less form).
---@param ... any Arguments interpolated into the message with string.format.
writeLog = (level, msg, ...) ->
  local text
  if type(level) == "string"
    text = if msg != nil then level\format msg, ... else level
  else
    text = if select("#", ...) > 0 then msg\format ... else msg
  io.stderr\write tostring text or ""

aegisub = {
  lua_automation_version: 4

  decode_path: decodePath

  -- Always-nil stubs for context-dependent queries.
  frame_from_ms: -> nil -- nil when no video loaded
  ms_from_frame: -> nil
  video_size: -> nil
  keyframes: -> nil
  get_audio_selection: -> nil
  project_properties: -> nil
  file_name: -> nil

  ---Registers a macro for `runMacro` to run by name. Aegisub adds the macro to its Automation menu.
  ---@param name string The macro's menu path.
  ---@param description string The macro's description, shown in the menu.
  ---@param processor fun(subtitles: AegisubSubtitles, selectedLines: integer[], activeLine: integer): integer[]?, integer?
  ---  The function that runs the macro.
  ---@param validator? fun(subtitles: AegisubSubtitles, selectedLines: integer[], activeLine: integer): boolean
  ---  Decides whether the macro can run on the current selection.
  ---@param isActive? fun(subtitles: AegisubSubtitles, selectedLines: integer[], activeLine: integer): boolean
  ---  Decides whether the menu shows the macro as checked. `runMacro` never calls it.
  register_macro: (name, description, processor, validator, isActive) ->
    registeredMacros[#registeredMacros + 1] = {:name, :description, :processor, :validator, :isActive}
    nil

  register_filter: -> nil

  ---Records an undo point. Throws unless called from a macro's processing function, as in Aegisub.
  ---@param description string The undo entry's label.
  set_undo_point: (description) ->
    error msgs.set_undo_point.outsideMacro, 2 unless undoPointSetter
    undoPointSetter description
    nil

  set_status_text: -> nil

  ---Measures a run of text set in a style.
  ---@param style AegisubStyleLine The style to set the text in.
  ---@param text string The text to measure.
  ---@return number width
  ---@return number height
  ---@return number descent
  ---@return number extlead
  text_extents: (style, text) ->
    error msgs.text_extents.noBackend, 2 unless textExtentsBackend
    valid, styleErr = ass.validateLine style, ass.LineClass.Style
    error styleErr, 2 unless valid
    return textExtentsBackend style, text

  ---Splits a dialogue line into the karaoke syllables it is sung in.
  ---
  ---Syllable timings are milliseconds from the line's own start and may run past its end time. A line
  ---holding no karaoke tag still yields one syllable, and index zero holds an empty filler.
  ---@param line AegisubDialogueLine The line to read. Throws, as Aegisub does, where the table is not a
  ---  complete dialogue line, and where it states no extradata, which Aegisub reads without requiring.
  ---@return AegisubKaraokeData syllables Keyed from zero, the filler first.
  parse_karaoke_data: (line) ->
    valid, lineErr = ass.validateLine line, ass.LineClass.Dialogue, ass.FieldTyping.Coerced
    error lineErr, 2 unless valid
    error msgs.parse_karaoke_data.noExtradata, 2 if line.extra == nil
    karaokeReader\toAegisubKaraokeData karaokeScanner\scan tostring line.text

  gettext: (s) -> s

  cancel: -> error "aegisub.cancel", 2

  -- These are normally injected by LuaProgressSink during macro execution.
  -- We provide static stubs so scripts that call them at module load time don't crash.
  log: writeLog

  debug: {
    out: writeLog
  }

  progress: {
    set: -> nil
    task: -> nil
    title: -> nil
    is_cancelled: -> false
  }

  dialog: {
    -- every headless dialog reports a cancel: button false, plus an empty result-values table
    display: -> false, {}
    open: -> nil
    save: -> nil
  }
}

local loadedScript
-- the undo points set while running macros on the loaded script, oldest first
undoPoints = {}

-- Shim-only configuration hooks, namespaced so they can't collide with the real
-- Aegisub API surface. Surfaced through l0.AegisubShims for callers to use.
aegisub.__depCtrl = {
  :setPathToken
  :getPathToken

  ---Installs the source of font metrics `aegisub.text_extents` measures with.
  ---@param replacement? AegisubTextExtentsBackend Backend to install, nil leaving text_extents raising.
  ---@return AegisubTextExtentsBackend? previous The backend installed until now, to restore later.
  setTextExtentsBackend: (replacement) ->
    utils.assertArgType replacement, 1, "function" if replacement != nil

    previous = textExtentsBackend
    textExtentsBackend = replacement
    return previous

  ---Returns the source of font metrics currently in place.
  ---@return AegisubTextExtentsBackend? backend Nil while none is installed, which leaves text_extents raising.
  getTextExtentsBackend: -> textExtentsBackend

  ---Sets the script macros run on, like opening a file in Aegisub. Macros edit the script directly, so
  ---save their changes with the script's `writeFile`. Clears the undo points of the previous script.
  ---@param script AssScript The script to run macros on, from `AssScript.fromFile` or `AssScript.parse`.
  setScript: (script) ->
    error msgs.setScript.notAScript\format(type script), 2 unless "table" == type(script) and script.lines
    loadedScript = script
    undoPoints = {}

  ---Returns the script macros run on.
  ---@return AssScript? script Nil if no script has been set.
  getScript: -> loadedScript

  ---Returns the undo points macros have set on the current script.
  ---@return string[] descriptions The undo points' labels, oldest first.
  getUndoPoints: -> [description for description in *undoPoints]

  ---Returns every macro registered so far.
  ---@return {name: string, description: string}[] macros The macros in registration order.
  getMacros: -> [{name: macro.name, description: macro.description} for macro in *registeredMacros]

  ---Runs a registered macro on the current script, like choosing it from Aegisub's Automation menu. A
  ---validation function, if the macro has one, is called first with a read-only subtitles object, and a
  ---false result throws. Also throws if no script has been set.
  ---@param name string The macro's registered name.
  ---@param selectedLines? integer[] The indices of the selected lines, the first dialogue line by default.
  ---@param activeLine? integer The index of the active line, the first selected line by default.
  ---@return integer[] selectedLines The selection the macro returned, or the one passed in if it returned none.
  ---@return integer activeLine The active line the macro returned, or the one passed in if it returned none.
  runMacro: (name, selectedLines, activeLine) ->
    error msgs.runMacro.noScript, 2 unless loadedScript
    macro = nil
    macro = held for held in *registeredMacros when held.name == name
    error msgs.runMacro.unknown\format(tostring name), 2 unless macro

    object = loadedScript.subtitles
    selectedLines or= defaultSelection object
    activeLine or= selectedLines[1] or 1

    if macro.validator
      readOnly = AegisubSubtitles loadedScript, readOnly: true
      allowed = macro.validator readOnly, selectedLines, activeLine
      error msgs.runMacro.refused, 2 unless allowed

    undoPointSetter = (description) -> undoPoints[#undoPoints + 1] = description
    ok, newSelection, newActive = pcall macro.processor, object, selectedLines, activeLine
    undoPointSetter = nil
    error newSelection, 0 unless ok

    return newSelection or selectedLines, newActive or activeLine
}

return aegisub
