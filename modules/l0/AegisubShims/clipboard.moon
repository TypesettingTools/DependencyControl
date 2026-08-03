utils = require "l0.DependencyControl.utils"

---The implementation behind the module's get and set, replaceable through the setBackend hook. Both are
---called as plain functions, so a backend carrying state must close over it.
---@class AegisubClipboardBackend
---@field get fun(): string? Text on the clipboard, nil or an empty string while it holds nothing.
---@field set fun(str: string): boolean Stores text, reporting whether it could be written.

local contents

---@type AegisubClipboardBackend
inProcessBackend = {
  get: -> contents
  set: (str) ->
    contents = str
    return true
}

backend = inProcessBackend

---Headless stand-in for Aegisub's `aegisub.clipboard` module, reached under that require id once
---l0.AegisubShims has claimed it, so a script requiring it loads and can be tested outside Aegisub.
---
---Instead of interacting with the actual system clipboard, the default backend keeps the contents in
---this process. A value another application put on the real clipboard is never visible here, and one
---set through this module never leaves it, which is what a headless run almost always wants. A harness
---that does want the real thing, or wants to watch what a script copies, puts its own implementation in
---through `setBackend`.
---@class AegisubClipboard
Clipboard = {
  ---Returns the text on the clipboard.
  ---@return string? contents Nil while the clipboard is empty, which an empty string counts as.
  get: ->
    text = backend.get!
    return text if text != ""

  ---Puts text on the clipboard, replacing what was there.
  ---@param str string The text to store.
  ---@return boolean succeeded Whether the backend could write it, which the default one always can.
  set: (str) ->
    utils.assertArgType str, 1, "string"
    return backend.set str
}

-- Shim-only configuration hooks, namespaced so they can't collide with the real Aegisub API surface.
-- Surfaced through l0.AegisubShims for callers to use.
Clipboard.__depCtrl = {
  ---Installs a clipboard implementation for get and set to work through.
  ---@param replacement? AegisubClipboardBackend Backend to install, nil restoring the in-process one.
  ---@return AegisubClipboardBackend previous The backend that was installed until now, to restore later.
  setBackend: (replacement) ->
    if replacement != nil
      utils.assertArgType replacement, 1, "table"
      utils.assertArgType replacement.get, "backend.get", "function"
      utils.assertArgType replacement.set, "backend.set", "function"

    previous = backend
    backend = replacement or inProcessBackend
    return previous

  ---Returns the clipboard implementation currently in place.
  ---@return AegisubClipboardBackend backend The in-process default until setBackend replaces it.
  getBackend: -> backend
}

return Clipboard
