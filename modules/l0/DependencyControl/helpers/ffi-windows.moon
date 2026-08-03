ffi = require "ffi"

pcall ffi.cdef, [[
  int CloseHandle(void* hObject);
  int MultiByteToWideChar(unsigned int cp, unsigned long flags, const char* str, int cbMulti, wchar_t* wide, int cchWide);
  int SetConsoleOutputCP(unsigned int wCodePageID);
]]

msgs = {
  toWide: {
    noKernel32: "Wide-character conversion needs kernel32, which could not be loaded."
    invalidUtf8: "%s: invalid character sequence."
  }
}

CP_UTF8 = 65001 -- code page identifier for UTF-8, passed to the *CP() conversion APIs
MB_ERR_INVALID_CHARS = 8 -- fail on a malformed sequence instead of substituting U+FFFD for it

haveKernel32, kernel32 = pcall ffi.load, "kernel32"

{
  -- the loaded kernel32 library namespace, or nil if it couldn't be loaded
  kernel32: haveKernel32 and kernel32 or nil

  -- whether kernel32 loaded successfully; gate any use of `kernel32`/`toWide` on this
  ---@type boolean
  haveKernel32: haveKernel32

  ---Converts a UTF-8 string to a NUL-terminated wide-char (UTF-16) buffer for the *W Win32 APIs.
  ---A malformed sequence is rejected rather than converted, so a path or URL that survives this names
  ---what the caller meant.
  ---@param s string A UTF-8 encoded string.
  ---@return ffi.cdata*? buffer A wchar_t[] buffer holding the converted, NUL-terminated string.
  ---@return string? err Set when the string is not valid UTF-8, or kernel32 is unavailable.
  toWide: (s) ->
    return nil, msgs.toWide.noKernel32 unless haveKernel32

    -- a length of -1 takes the string as NUL-terminated and counts the terminator, so the buffer
    -- comes back terminated and an empty string needs no special case
    size = kernel32.MultiByteToWideChar CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, nil, 0
    return nil, msgs.toWide.invalidUtf8\format s if size == 0

    buffer = ffi.new "wchar_t[?]", size
    written = kernel32.MultiByteToWideChar CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, buffer, size
    return nil, msgs.toWide.invalidUtf8\format s if written == 0

    return buffer

  ---Switches the attached console's output code page to UTF-8.
  ---Returns false if kernel32 is unavailable or no console is attached (output is redirected).
  ---@return boolean ok Whether the output code page was switched to UTF-8.
  setConsoleOutputUTF8: -> haveKernel32 and kernel32.SetConsoleOutputCP(CP_UTF8) != 0 or false
}
