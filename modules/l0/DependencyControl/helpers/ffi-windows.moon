ffi = require "ffi"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"

kernel32Binding = ffiBinding.bind {
  library: "kernel32"
  functions: {"CloseHandle", "MultiByteToWideChar", "WideCharToMultiByte", "SetConsoleOutputCP",
    "GetLastError", "FormatMessageW", "LoadLibraryW"}
  declarations: [[
    int CloseHandle(void* hObject);
    int MultiByteToWideChar(unsigned int cp, unsigned long flags, const char* str, int cbMulti, wchar_t* wide, int cchWide);
    int WideCharToMultiByte(unsigned int cp, unsigned long flags, const wchar_t* wide, int cchWide, char* str, int cbMulti, const char* defaultChar, int* usedDefault);
    int SetConsoleOutputCP(unsigned int wCodePageID);
    unsigned long GetLastError();
    unsigned long FormatMessageW(unsigned long flags, const void* source, unsigned long messageId, unsigned long langId, wchar_t* buffer, unsigned long size, void* args);
    void* LoadLibraryW(const wchar_t* name);
  ]]
}

msgs = {
  toWide: {
    noKernel32: "Wide-character conversion needs kernel32, which could not be loaded."
    invalidUtf8: "%s: invalid character sequence."
  }
  describeLastError: {
    described: "%s (error %d)"
    codeOnly: "error %d"
    unavailable: "no Win32 error information available"
  }
}

-- FormatMessageW
FORMAT_MESSAGE_FROM_HMODULE = 0x800 -- also search the given module's message table
FORMAT_MESSAGE_FROM_SYSTEM = 0x1000 -- search the system message table
FORMAT_MESSAGE_IGNORE_INSERTS = 0x200 -- emit %1-style placeholders verbatim instead of consuming varargs

-- module handles keyed by the DLL name whose message table they hold
moduleHandles = {}

CP_UTF8 = 65001 -- code page identifier for UTF-8, passed to the *CP() conversion APIs
MB_ERR_INVALID_CHARS = 8 -- fail on a malformed sequence instead of substituting U+FFFD for it
MESSAGE_BUFFER_LENGTH = 512 -- comfortably above the longest system error text

isAvailable, kernel32 = kernel32Binding.isAvailable, kernel32Binding.functions

---Thin wrappers over the Win32 calls DependencyControl reaches through the FFI. Loads on every
---platform and reports `isAvailable` false where the API doesn't exist, so a caller can branch once
---rather than guarding each call.
---@class FfiWindows
---@field kernel32 table<string, ffi.cdata*> The bound kernel32 calls keyed by their Win32 names, with unknown keys resolving through the library so a caller's own declarations work too. Nil where it couldn't be loaded.
---@field isAvailable boolean Whether kernel32 loaded; gate any use of `kernel32` on it.
local Windows
Windows = {
  ---@type table<string, ffi.cdata*>
  kernel32: isAvailable and kernel32 or nil

  ---Whether the Win32 API is available on this platform, as indicated by presence of kernel32.dll.
  ---@type boolean
  isAvailable: isAvailable

  ---Converts a UTF-8 string to a NUL-terminated wide-char (UTF-16) buffer for the *W Win32 APIs.
  ---A malformed sequence is rejected rather than converted, so a path or URL that survives this names
  ---what the caller meant.
  ---@param s string A UTF-8 encoded string.
  ---@return ffi.cdata*? buffer A wchar_t[] buffer holding the converted, NUL-terminated string.
  ---@return string? err Set when the string is not valid UTF-8, or kernel32 is unavailable.
  toWide: (s) ->
    return nil, msgs.toWide.noKernel32 unless isAvailable

    -- a length of -1 takes the string as NUL-terminated and counts the terminator, so the buffer
    -- comes back terminated and an empty string needs no special case
    size = kernel32.MultiByteToWideChar CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, nil, 0
    return nil, msgs.toWide.invalidUtf8\format s if size == 0

    buffer = ffi.new "wchar_t[?]", size
    written = kernel32.MultiByteToWideChar CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, buffer, size
    return nil, msgs.toWide.invalidUtf8\format s if written == 0

    return buffer

  ---Converts a wide-char (UTF-16) buffer returned by a *W Win32 API back to a UTF-8 string.
  ---@param buffer ffi.cdata* The wchar_t[] to read.
  ---@param length number How many UTF-16 units to read, terminator excluded.
  ---@return string text Empty when the buffer holds nothing or kernel32 is unavailable.
  fromWide: (buffer, length) ->
    return "" unless isAvailable and length > 0

    size = kernel32.WideCharToMultiByte CP_UTF8, 0, buffer, length, nil, 0, nil, nil
    return "" if size == 0

    out = ffi.new "char[?]", size
    written = kernel32.WideCharToMultiByte CP_UTF8, 0, buffer, length, out, size, nil, nil
    return ffi.string out, written

  ---Returns a human-readable description of the last Win32 error, or the numeric code alone if the
  ---text can't be retrieved.
  ---**Must** be called before any further Win32 call, which would replace the error it reads.
  ---@param moduleName? string DLL holding the message text, for an API with its own error range such
  --- as `"wininet.dll"`; the system table alone covers the common codes.
  ---@return string described The system's wording plus the numeric code, or the code alone when the
  --- text can't be retrieved.
  ---@return number? code The raw error code, for a caller that branches on specific ones.
  describeLastError: (moduleName) ->
    return msgs.describeLastError.unavailable unless isAvailable
    code = tonumber kernel32.GetLastError!

    handle = nil
    if moduleName
      if moduleHandles[moduleName] == nil
        wideName = Windows.toWide moduleName
        moduleHandles[moduleName] = wideName and kernel32.LoadLibraryW(wideName) or false
      handle = moduleHandles[moduleName] or nil

    flags = bit.bor FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS
    flags = bit.bor flags, FORMAT_MESSAGE_FROM_HMODULE if handle

    buffer = ffi.new "wchar_t[?]", MESSAGE_BUFFER_LENGTH
    length = kernel32.FormatMessageW flags, handle, code, 0, buffer, MESSAGE_BUFFER_LENGTH, nil
    return msgs.describeLastError.codeOnly\format(code), code if length == 0

    -- the system appends a trailing CRLF to its messages, which reads badly mid-sentence
    text = Windows.fromWide(buffer, length)\gsub "%s+$", ""
    return msgs.describeLastError.described\format(text, code), code

  ---Switches the attached console's output code page to UTF-8.
  ---Returns false if the Win32 API is unavailable or no console is attached (output is redirected).
  ---@return boolean ok Whether the output code page was switched to UTF-8.
  setConsoleOutputUtf8: -> isAvailable and kernel32.SetConsoleOutputCP(CP_UTF8) != 0 or false
}

return Windows
