-- State lives in a global table so the installed searcher survives DependencyControl self-update
-- reloads.

ffi = require "ffi"
constants = require "l0.DependencyControl.Constants"
utils = require "l0.DependencyControl.utils"

GLOBAL_KEY = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}UnicodeSearcher"

state = _G[GLOBAL_KEY]
unless state
  state = {installed: false}
  _G[GLOBAL_KEY] = state

msgs = {
  install: {
    notWindows: "Only Windows resolves a module path in a code page; the stock searcher takes UTF-8 elsewhere."
  }
  search: {
    loadError: "error loading module '%s' from file '%s':\n\t%s"
  }
}

DIRECTORY_SEPARATOR, PATH_SEPARATOR, TEMPLATE_MARK = package.config\match "^(.-)\n(.-)\n(.-)\n"
TEMPLATE_PATTERN = utils.escapePattern TEMPLATE_MARK
ENTRY_PATTERN = "[^#{utils.escapePattern PATH_SEPARATOR}]+"

---Resolves a require id against package.path, opening each candidate through Lua's io.open.
---@param name string The require id, its dots standing for directory separators.
---@return string? path The first candidate that opened, nil when none did.
---@return string? contents That file's bytes, read in binary so a precompiled chunk survives.
findModule = (name) ->
  relativePath = (name\gsub "%.", DIRECTORY_SEPARATOR)
  for template in package.path\gmatch ENTRY_PATTERN
    -- a function replacement keeps a per cent sign in the resolved name from reading as a capture
    path = (template\gsub TEMPLATE_PATTERN, -> relativePath)
    handle = io.open path, "rb"
    continue unless handle
    contents = handle\read "*a"
    handle\close!
    return path, contents
  return nil

---Loads `.lua` modules Lua's own path searcher cannot open. That one hands the file it resolved from
---`package.path` to C, which reads the path in the system code page, so on Windows any path holding a
---non-ASCII character misses unless the machine is set to the UTF-8 code page (65001). This one
---resolves `package.path` by hand and reads through `io.open`, inheriting whatever encoding the patch
---on it gives, and is appended last so a require the stock searchers already satisfy never reaches it.
---Only the headless environment needs it, as Aegisub replaces its own searcher, and MoonScript's loader
---already reads through `io.open`.
---@class AegisubUnicodeSearcher
local UnicodeSearcher
UnicodeSearcher = {
  ---Appends the searcher to `package.loaders` on Windows. Idempotent across self-update reloads.
  ---@return boolean installed Whether the searcher is in `package.loaders`, true as well when an earlier call put it there.
  ---@return string? reason Why it is not, absent when it is.
  install: ->
    return false, msgs.install.notWindows unless ffi.os == "Windows"
    return true if state.installed

    loaders = package.loaders or package.searchers
    loaders[#loaders + 1] = UnicodeSearcher.__search
    state.installed = true
    return true

  ---Loads a module the stock path searcher could not open, as a `package.loaders` entry. The chunk
  ---is named after the file it came from, so a traceback reads as it does for any other module.
  ---@private
  ---@param name string The require id.
  ---@return function? loader The compiled chunk, nil when no package.path candidate opened.
  __search: (name) ->
    path, contents = findModule name
    return unless path

    chunk, err = loadstring contents, "@#{path}"
    -- the host raises for a file it opened but could not compile, and so must a searcher standing in
    -- for it, or require would fall through to "module not found" and bury the syntax error
    error msgs.search.loadError\format(name, path, err), 0 unless chunk
    return chunk
}

return UnicodeSearcher
