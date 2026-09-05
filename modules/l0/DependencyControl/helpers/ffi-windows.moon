ffi = require "ffi"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"
ffiCommon = require "l0.DependencyControl.helpers.ffi-common"

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
    invalidUtf8: "Could not convert '%s' to UTF-16 because it is not valid UTF-8."
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

-- The shared codes plus the ones the Windows C runtime numbers for itself, from its own errno.h.
-- EDEADLOCK is the runtime's second name for EDEADLK rather than a code of its own, which is why this
-- table cannot be an `Enum`.
Errno = ffiCommon.extendErrno {
  EAGAIN: 11 -- resource temporarily unavailable
  EDEADLK: 36 -- resource deadlock avoided
  EDEADLOCK: 36 -- the runtime's own alias for EDEADLK
  ENAMETOOLONG: 38 -- file name too long
  ENOSYS: 40 -- function not implemented
  ENOTEMPTY: 41 -- directory not empty
  EILSEQ: 42 -- illegal byte sequence
}

-- The Win32 error codes the file and directory calls report, from winerror.h. A plain table for the
-- same reason `Errno` is one: the codes a caller compares against are a subset transcribed as needed,
-- and winerror.h names several of them more than once.
---The Win32 error codes a file or directory call reports, for a caller branching on a specific one.
---@class FfiWin32Error
Win32Error = {
  InvalidFunction: 1 -- ERROR_INVALID_FUNCTION
  FileNotFound: 2 -- ERROR_FILE_NOT_FOUND
  PathNotFound: 3 -- ERROR_PATH_NOT_FOUND
  TooManyOpenFiles: 4 -- ERROR_TOO_MANY_OPEN_FILES
  AccessDenied: 5 -- ERROR_ACCESS_DENIED
  InvalidHandle: 6 -- ERROR_INVALID_HANDLE
  NotEnoughMemory: 8 -- ERROR_NOT_ENOUGH_MEMORY
  InvalidDrive: 15 -- ERROR_INVALID_DRIVE
  CurrentDirectory: 16 -- ERROR_CURRENT_DIRECTORY
  NotSameDevice: 17 -- ERROR_NOT_SAME_DEVICE
  SharingViolation: 32 -- ERROR_SHARING_VIOLATION
  LockViolation: 33 -- ERROR_LOCK_VIOLATION
  BadNetPath: 53 -- ERROR_BAD_NETPATH
  NetworkAccessDenied: 65 -- ERROR_NETWORK_ACCESS_DENIED
  BadNetName: 67 -- ERROR_BAD_NET_NAME
  FileExists: 80 -- ERROR_FILE_EXISTS
  CannotMake: 82 -- ERROR_CANNOT_MAKE
  InvalidParameter: 87 -- ERROR_INVALID_PARAMETER
  DiskFull: 112 -- ERROR_DISK_FULL
  DirNotEmpty: 145 -- ERROR_DIR_NOT_EMPTY
  BadPathName: 161 -- ERROR_BAD_PATHNAME
  AlreadyExists: 183 -- ERROR_ALREADY_EXISTS
  FileNameTooLong: 206 -- ERROR_FILENAME_EXCED_RANGE
}

-- What the C runtime sets errno to for a Win32 error, transcribed from its own `_dosmaperr` table, so
-- a call made through the Win32 API reports a failure the way the same call through the runtime does.
-- An error the runtime does not map falls through to EINVAL, as it does there.
errnoByWin32Error = {
  [Win32Error.InvalidFunction]: Errno.EINVAL
  [Win32Error.FileNotFound]: Errno.ENOENT
  [Win32Error.PathNotFound]: Errno.ENOENT
  [Win32Error.TooManyOpenFiles]: Errno.EMFILE
  [Win32Error.AccessDenied]: Errno.EACCES
  [Win32Error.InvalidHandle]: Errno.EBADF
  [Win32Error.NotEnoughMemory]: Errno.ENOMEM
  [Win32Error.InvalidDrive]: Errno.ENOENT
  [Win32Error.CurrentDirectory]: Errno.EACCES
  [Win32Error.NotSameDevice]: Errno.EXDEV
  [Win32Error.SharingViolation]: Errno.EACCES
  [Win32Error.LockViolation]: Errno.EACCES
  [Win32Error.BadNetPath]: Errno.ENOENT
  [Win32Error.NetworkAccessDenied]: Errno.EACCES
  [Win32Error.BadNetName]: Errno.ENOENT
  [Win32Error.FileExists]: Errno.EEXIST
  [Win32Error.CannotMake]: Errno.EACCES
  [Win32Error.InvalidParameter]: Errno.EINVAL
  [Win32Error.DiskFull]: Errno.ENOSPC
  [Win32Error.DirNotEmpty]: Errno.ENOTEMPTY
  [Win32Error.BadPathName]: Errno.ENOENT
  [Win32Error.AlreadyExists]: Errno.EEXIST
  [Win32Error.FileNameTooLong]: Errno.ENOENT
}

CP_UTF8 = 65001 -- code page identifier for UTF-8, passed to the *CP() conversion APIs
MB_ERR_INVALID_CHARS = 8 -- fail on a malformed sequence instead of substituting U+FFFD for it
MESSAGE_BUFFER_LENGTH = 512 -- comfortably above the longest system error text
WCHAR_SIZE = ffi.sizeof "wchar_t" -- 2 on Windows, where a wchar_t is one UTF-16 code unit

isAvailable, kernel32 = kernel32Binding.isAvailable, kernel32Binding.functions

---Thin wrappers over the Win32 calls DependencyControl reaches through the FFI. Loads on every
---platform and reports `isAvailable` false where the API doesn't exist, so a caller can branch once
---rather than guarding each call.
---@class FfiWindows
---@field kernel32 table<string, ffi.cdata*> The bound kernel32 calls keyed by their Win32 names, with unknown keys resolving through the library so a caller's own declarations work too. Nil where it couldn't be loaded.
---@field isAvailable boolean Whether kernel32 loaded; gate any use of `kernel32` on it.
---@field CP_UTF8 integer Code page identifier for UTF-8, which the *CP() conversion APIs take.
---@field WCHAR_SIZE integer Bytes one wchar_t occupies, for sizing and walking a wide buffer.
---@field Errno FfiErrno The error codes by their C names, the shared ones plus the Windows runtime's own.
local Windows
Windows = {
  ---@type table<string, ffi.cdata*>
  kernel32: isAvailable and kernel32 or nil

  ---@type integer
  CP_UTF8: CP_UTF8

  ---@type integer
  WCHAR_SIZE: WCHAR_SIZE

  ---@type FfiErrno
  Errno: Errno

  ---@type FfiWin32Error
  Win32Error: Win32Error

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

  ---Counts the UTF-16 code units a buffer from `toWide` holds, its terminator excluded.
  ---Not the same as a character count, as the surrogate pairs for astral characters
  -- like emoji occupy two code units.
  ---@param wide ffi.cdata* A wchar_t[] from toWide.
  ---@return integer length
  getWideLength: (wide) -> ffi.sizeof(wide) / WCHAR_SIZE - 1

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
  ---@return number? errno The errno the C runtime reports the same failure as, for a caller standing
  --- in for one that goes through the runtime. EINVAL for an error the runtime does not map.
  describeLastError: (moduleName) ->
    return msgs.describeLastError.unavailable unless isAvailable
    code = tonumber kernel32.GetLastError!
    errno = errnoByWin32Error[code] or Errno.EINVAL

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
    return msgs.describeLastError.codeOnly\format(code), code, errno if length == 0

    -- the system appends a trailing CRLF to its messages, which reads badly mid-sentence
    text = Windows.fromWide(buffer, length)\gsub "%s+$", ""
    return msgs.describeLastError.described\format(text, code), code, errno

  ---Switches the attached console's output code page to UTF-8.
  ---Returns false if the Win32 API is unavailable or no console is attached (output is redirected).
  ---@return boolean ok Whether the output code page was switched to UTF-8.
  setConsoleOutputUtf8: -> isAvailable and kernel32.SetConsoleOutputCP(CP_UTF8) != 0 or false
}

return Windows
