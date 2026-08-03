-- Port of Aegisub's automation/include/unicode-monkeypatch.lua, which Aegisub runs for every Lua state
-- it creates on Windows. The CLI builds its environment from plain LuaJIT, where the patch is absent,
-- so DepCtrl's own file operations reach paths through a different encoding than they do in Aegisub.
--
-- Lua's io and os functions call the ANSI C runtime, which reads a path in the process code page, while
-- every path DepCtrl handles is UTF-8. Any byte outside ASCII therefore names a different file than
-- intended, or none at all, an accented letter arriving as the two separate characters its two UTF-8
-- bytes stand for. The replacements below widen the path to UTF-16 and call the wide-character runtime.

ffi = require "ffi"
ffiWindows = require "l0.DependencyControl.helpers.ffi-windows"

msgs = {
  applyPatch: {
    notWindows: "Only Windows reads paths in a code page; elsewhere the stock functions take UTF-8."
    alreadyPatched: "The io and os functions have already been replaced, and must not be replaced twice."
    unavailable: "The wide-character runtime functions could not be bound."
  }
}

---What the patch did on load, for a caller that wants to know which encoding its paths take.
---@class AegisubUnicodePatchStatus
---@field applied boolean Whether the wide-character replacements were installed.
---@field reason? string Why they were not, absent when they were.

---Reports whether the stock io and os functions are still in place. Lua's own are C functions, which
---`string.dump` refuses, so one it accepts is a replacement somebody else installed.
---@return boolean untouched
isUnpatched = ->
  return not pcall string.dump, io.open

---Binds the Win32 and CRT entry points the replacements need.
---@return boolean available False when a declaration or symbol lookup failed.
bindWideRuntime = ->
  pcall ffi.cdef, [[
    void *_wfreopen(wchar_t*, wchar_t*, void*);
    int32_t _wrename(wchar_t*, wchar_t*);
    int32_t _wremove(wchar_t*);
    int32_t _wsystem(wchar_t*);
    char *strerror(int);
  ]]
  return pcall -> ffi.C._wfreopen

---Shapes a C status into the `true` or `nil, msg, errno` triple Lua's file functions return.
---@param status number Zero on success, as the CRT reports it.
---@param fileName? string Path to name in the message.
---@return boolean|nil ok True on success, nil with a message and errno otherwise.
fileResult = (status, fileName) ->
  return true if status == 0

  errno = ffi.errno!
  message = ffi.string ffi.C.strerror errno
  return nil, (fileName and "#{fileName}: #{message}" or message), errno

---Shapes a `_wsystem` status into the triple `os.execute` returns.
---@param status number The command's exit status, -1 when it could not be run.
---@return boolean|nil ok True when the command exited zero.
execResult = (status) ->
  return fileResult 0, nil if status == -1
  return true, "exit", status if status == 0
  return nil, "exit", status

---Replaces the io and os functions that take a path with wide-character equivalents.
---@return AegisubUnicodePatchStatus status
applyPatch = ->
  return {applied: false, reason: msgs.applyPatch.notWindows} unless ffi.os == "Windows"

  -- The process code page is not consulted. `GetACP` can report 65001 while the C runtime still
  -- converts paths in the legacy code page, as it does under a locale emulator, and standing down on
  -- that report loses every non-ASCII path. Widening is correct on a genuine UTF-8 code page too,
  -- where the stock functions would have taken the path unaided.
  return {applied: false, reason: msgs.applyPatch.alreadyPatched} unless isUnpatched!
  return {applied: false, reason: msgs.applyPatch.unavailable} unless bindWideRuntime!

  origOpen = io.open

  -- LuaJIT offers no way to build a file object around a FILE*, so a throwaway handle on the null
  -- device supplies one and the wide reopen points it at the real path.
  io.open = (fileName, mode = "r") ->
    wideName, nameErr = ffiWindows.toWide fileName
    return nil, nameErr unless wideName
    wideMode, modeErr = ffiWindows.toWide mode
    return nil, modeErr unless wideMode

    file = assert origOpen "nul", "rb"
    if ffi.C._wfreopen(wideName, wideMode, file) == nil
      message, errno = select 2, file\close!
      return nil, "#{fileName}: #{tostring message}", errno

    return file

  os.rename = (oldName, newName) ->
    wideOld, oldErr = ffiWindows.toWide oldName
    return nil, oldErr unless wideOld
    wideNew, newErr = ffiWindows.toWide newName
    return nil, newErr unless wideNew

    return fileResult ffi.C._wrename(wideOld, wideNew), oldName

  os.remove = (fileName) ->
    wideName, err = ffiWindows.toWide fileName
    return nil, err unless wideName
    return fileResult ffi.C._wremove(wideName), fileName

  os.execute = (command) ->
    return true unless command
    wideCommand, err = ffiWindows.toWide command
    return nil, err unless wideCommand
    return execResult ffi.C._wsystem wideCommand

  return {applied: true}

return applyPatch!
