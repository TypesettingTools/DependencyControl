ffi = require "ffi"
lfs = require "lfs"
bit = require "bit"
constants = require "l0.DependencyControl.Constants"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"
ffiWindows = require "l0.DependencyControl.helpers.ffi-windows"

-- State lives in a global table so the layer survives DependencyControl self-update reloads.
GLOBAL_KEY = "#{constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX}LfsUnicodePatch"

state = _G[GLOBAL_KEY]
unless state
  state = {installed: false, original: {}}
  _G[GLOBAL_KEY] = state

msgs = {
  install: {
    notWindows: "Only Windows reads a path in a code page; elsewhere lfs takes UTF-8 unaided."
    unavailable: "The wide-character Win32 file calls could not be bound."
  }
  wideAttributes: {
    invalidField: "invalid attribute name '%s'"
  }
  -- the wording each call's host reports, so a message that reaches a user reads as it did before
  attributes: {
    failed: "cannot obtain information from file '%s': %s"
  }
  chdir: {
    failed: "Unable to change working directory to '%s'\n%s\n"
  }
  dir: {
    cannotOpen: "cannot open %s: %s"
  }
}

kernel32Binding = ffiBinding.bind {
  library: "kernel32"
  structs: {"FILETIME", "WIN32_FILE_ATTRIBUTE_DATA", "WIN32_FIND_DATAW"}
  functions: {"GetFileAttributesExW", "FindFirstFileW", "FindNextFileW", "FindClose",
    "CreateDirectoryW", "RemoveDirectoryW", "SetCurrentDirectoryW", "GetCurrentDirectoryW",
    "CreateFileW", "SetFileTime", "DeleteFileW", "CreateHardLinkW", "CreateSymbolicLinkW",
    "GetFinalPathNameByHandleW"}
  declarations: [[
    typedef struct { unsigned long dwLowDateTime; unsigned long dwHighDateTime; } FILETIME;
    typedef struct {
      unsigned long dwFileAttributes;
      FILETIME ftCreationTime;
      FILETIME ftLastAccessTime;
      FILETIME ftLastWriteTime;
      unsigned long nFileSizeHigh;
      unsigned long nFileSizeLow;
    } WIN32_FILE_ATTRIBUTE_DATA;
    typedef struct {
      unsigned long dwFileAttributes;
      FILETIME ftCreationTime;
      FILETIME ftLastAccessTime;
      FILETIME ftLastWriteTime;
      unsigned long nFileSizeHigh;
      unsigned long nFileSizeLow;
      unsigned long dwReserved0;
      unsigned long dwReserved1;
      wchar_t cFileName[260];
      wchar_t cAlternateFileName[14];
    } WIN32_FIND_DATAW;
    int GetFileAttributesExW(const wchar_t* name, int infoLevelId, void* info);
    void* FindFirstFileW(const wchar_t* name, WIN32_FIND_DATAW* data);
    int FindNextFileW(void* handle, WIN32_FIND_DATAW* data);
    int FindClose(void* handle);
    int CreateDirectoryW(const wchar_t* name, void* securityAttributes);
    int RemoveDirectoryW(const wchar_t* name);
    int SetCurrentDirectoryW(const wchar_t* name);
    unsigned long GetCurrentDirectoryW(unsigned long size, wchar_t* buffer);
    void* CreateFileW(const wchar_t* name, unsigned long access, unsigned long share,
      void* security, unsigned long creation, unsigned long flags, void* template);
    int SetFileTime(void* handle, const FILETIME* creation, const FILETIME* access,
      const FILETIME* write);
    int DeleteFileW(const wchar_t* name);
    int CreateHardLinkW(const wchar_t* name, const wchar_t* existing, void* security);
    unsigned char CreateSymbolicLinkW(const wchar_t* name, const wchar_t* target, unsigned long flags);
    unsigned long GetFinalPathNameByHandleW(void* handle, wchar_t* path, unsigned long size,
      unsigned long flags);
  ]]
}

kernel32, types = kernel32Binding.functions, kernel32Binding.types

GET_FILE_EX_INFO_STANDARD = 0 -- the only info level GetFileAttributesExW defines
FILE_ATTRIBUTE_READONLY = 0x1
FILE_ATTRIBUTE_DIRECTORY = 0x10
FILE_ATTRIBUTE_NORMAL = 0x80
FILE_ATTRIBUTE_REPARSE_POINT = 0x400 -- a symlink, junction or mount point rather than the thing itself

-- CreateFileW
FILE_WRITE_ATTRIBUTES = 0x100
GENERIC_WRITE = 0x40000000
FILE_SHARE_ALL = 0x7 -- read, write and delete, so opening a file never blocks another handle
OPEN_EXISTING = 3
CREATE_NEW = 1
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000 -- required to open a directory at all
VOLUME_NAME_DOS = 0 -- GetFinalPathNameByHandleW: a drive-letter path rather than a volume GUID

-- CreateSymbolicLinkW
SYMBOLIC_LINK_FLAG_DIRECTORY = 0x1
SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE = 0x2 -- honored in Developer Mode, ignored before it

LOCK_FILE_NAME = "lockfile.lfs" -- the name lfs marks a locked directory with
INVALID_HANDLE = ffi.cast "void*", -1 -- what CreateFileW and FindFirstFileW return instead of a handle
-- the declared capacity of the file name a WIN32_FIND_DATAW holds, read off the declaration itself
FIND_DATA_NAME_CAPACITY = ffi.sizeof(types.WIN32_FIND_DATAW!.cFileName) / ffiWindows.WCHAR_SIZE

-- FILETIME counts 100-nanosecond ticks from 1601-01-01, where a Unix time counts seconds from 1970.
-- The offset between the two epochs exceeds what a double holds exactly in ticks, so the division
-- happens first, in int64 arithmetic.
TICKS_PER_SECOND = 10000000
SECONDS_FROM_1601_TO_1970 = 11644473600
HIGH_WORD_SCALE = 4294967296 -- 2^32, to rejoin a value the API splits into a high and a low word

-- the extensions the C runtime treats as executable when it derives a file's permission bits
executableExtensions = {exe: true, cmd: true, bat: true, com: true}

---Whether a path holds a byte the process code page would read as something else.
---@param path string
---@return boolean
holdsNonAscii = (path) -> nil != path\find "[\128-\255]"

---Converts a FILETIME to a Unix timestamp.
---@param fileTime ffi.cdata* A FILETIME struct.
---@return integer seconds
toUnixTime = (fileTime) ->
  ticks = ffi.cast("int64_t", fileTime.dwHighDateTime) * HIGH_WORD_SCALE + fileTime.dwLowDateTime
  return tonumber ticks / TICKS_PER_SECOND - SECONDS_FROM_1601_TO_1970

---Fills a FILETIME from a Unix timestamp, the reverse of `toUnixTime`.
---@param fileTime ffi.cdata* A FILETIME struct to write into.
---@param seconds integer Seconds since 1970.
toFileTime = (fileTime, seconds) ->
  ticks = (ffi.cast("int64_t", seconds) + SECONDS_FROM_1601_TO_1970) * TICKS_PER_SECOND
  low = ticks % HIGH_WORD_SCALE
  fileTime.dwLowDateTime = tonumber low
  fileTime.dwHighDateTime = tonumber (ticks - low) / HIGH_WORD_SCALE

---Opens a path for a call that needs a handle rather than a name, following a reparse point.
---@param wide ffi.cdata* The path, widened.
---@param access integer The desired access rights, zero to only query metadata.
---@param creation integer The creation disposition, `OPEN_EXISTING` to require the path to be there.
---@return ffi.cdata*? handle Nil when the path could not be opened, the Win32 error still current.
openPath = (wide, access, creation) ->
  handle = kernel32.CreateFileW wide, access, FILE_SHARE_ALL, nil, creation,
    bit.bor(FILE_FLAG_BACKUP_SEMANTICS, FILE_ATTRIBUTE_NORMAL), nil
  return nil if handle == INVALID_HANDLE
  return handle

---The path a reparse point ultimately names, which for anything else is the path itself.
---@param wide ffi.cdata* The path, widened.
---@return string? resolved Nil when the path could not be opened.
resolveFinalPath = (wide) ->
  handle = openPath wide, 0, OPEN_EXISTING
  return nil unless handle

  needed = tonumber kernel32.GetFinalPathNameByHandleW handle, nil, 0, VOLUME_NAME_DOS
  unless needed > 0
    ffiWindows.kernel32.CloseHandle handle
    return nil

  buffer = ffi.new "wchar_t[?]", needed
  written = tonumber kernel32.GetFinalPathNameByHandleW handle, buffer, needed, VOLUME_NAME_DOS
  ffiWindows.kernel32.CloseHandle handle
  return nil unless written > 0

  -- the call always answers in the \\?\ form, which no other lfs return carries
  return (ffiWindows.fromWide(buffer, written)\gsub "^\\\\%?\\", "")

---Deletes a file through the UTF-16 Windows API, for the lock file `lockDir` leaves behind.
---@param path string
---@return boolean removed
removeFile = (path) ->
  wide = ffiWindows.toWide path
  return false unless wide
  return 0 != kernel32.DeleteFileW wide

---Length of a NUL-terminated wide string in a fixed-capacity buffer.
---@param buffer ffi.cdata* A wchar_t array.
---@param capacity integer How many units the buffer holds.
---@return integer length The units before the terminator, the whole capacity when there is none.
wideStringLength = (buffer, capacity) ->
  for index = 0, capacity - 1
    return index if buffer[index] == 0
  return capacity

---Renders the permission string from a file's attributes, as the C runtime derives it: readable
---always, writable unless the read-only attribute is set, executable for a directory or one of the
---four executable extensions, with the owner's bits repeated for group and other.
---@param attributes integer The Win32 file attribute bits.
---@param path string The path, whose extension decides the execute bit.
---@return string permissions Nine characters, as `lfs` formats them.
toPermissions = (attributes, path) ->
  isDirectory = 0 != bit.band attributes, FILE_ATTRIBUTE_DIRECTORY
  writable = 0 == bit.band attributes, FILE_ATTRIBUTE_READONLY
  extension = path\match "%.([^.\\/]+)$"
  executable = isDirectory or (extension and executableExtensions[extension\lower!] or false)
  return "r#{writable and 'w' or '-'}#{executable and 'x' or '-'}"\rep 3

---The drive a path names, as the C runtime numbers them for `dev`, with A as zero.
---@param path string
---@return integer drive Zero for a path naming no drive, which is what the runtime reports for one on the current drive.
toDriveIndex = (path) ->
  letter = path\match "^(%a):"
  return 0 unless letter
  return letter\lower!\byte! - ("a")\byte!

---Builds the attribute table from what GetFileAttributesExW reported.
---@param data ffi.cdata* A filled WIN32_FILE_ATTRIBUTE_DATA.
---@param path string The path it describes, for the fields derived from the name.
---@param asLink? boolean Report a reparse point as `"link"` rather than as what it points at.
---@return table attributes Keyed as the rock keys them, minus the POSIX-only `blocks` and `blksize`.
buildAttributes = (data, path, asLink) ->
  attributes = tonumber data.dwFileAttributes
  size = ffi.cast("int64_t", data.nFileSizeHigh) * HIGH_WORD_SCALE + data.nFileSizeLow
  drive = toDriveIndex path

  mode = if asLink and 0 != bit.band attributes, FILE_ATTRIBUTE_REPARSE_POINT
    "link"
  elseif 0 != bit.band attributes, FILE_ATTRIBUTE_DIRECTORY
    "directory"
  else "file"

  return {
    dev: drive
    ino: 0
    :mode
    nlink: 1
    uid: 0
    gid: 0
    rdev: drive
    access: toUnixTime data.ftLastAccessTime
    modification: toUnixTime data.ftLastWriteTime
    change: toUnixTime data.ftCreationTime
    size: tonumber size
    permissions: toPermissions attributes, path
  }

---Picks one field out of an attribute table, fills a caller's table, or hands the whole thing back.
---@param attributes table The built attribute table.
---@param request? string|table A field name, a table to fill, or nil.
---@return table|string|integer result
selectAttributes = (attributes, request) ->
  if type(request) == "string"
    value = attributes[request]
    error msgs.wideAttributes.invalidField\format(request), 3 if value == nil
    return value
  if type(request) == "table"
    request[key] = value for key, value in pairs attributes
    return request
  return attributes

---Reads a path's attributes through the UTF-16 Windows API, reporting what a reparse point points at
---rather than the reparse point, as `stat` does and `lstat` does not.
---@param path string
---@param request? string|table A field name to return on its own, a table to fill, or nil for a fresh one.
---@param asLink? boolean Report the reparse point itself, which is what `symlinkattributes` wants.
---@return table|string|integer|nil result Nil when the path could not be read, which includes it not being there.
---@return string? err
---@return integer? errno The POSIX code the rock reports, which tells absent from failed.
wideAttributes = (path, request, asLink) ->
  wide, err = ffiWindows.toWide path
  return nil, err, ffiWindows.Errno.EINVAL unless wide

  data = types.WIN32_FILE_ATTRIBUTE_DATA!
  if 0 == kernel32.GetFileAttributesExW wide, GET_FILE_EX_INFO_STANDARD, data
    description, _, errno = ffiWindows.describeLastError!
    return nil, msgs.attributes.failed\format(path, description), errno

  -- GetFileAttributesExW answers about the reparse point, where the C runtime's stat answers about
  -- its target, so resolving and asking again is what keeps the two agreeing
  unless asLink
    if 0 != bit.band tonumber(data.dwFileAttributes), FILE_ATTRIBUTE_REPARSE_POINT
      resolved = resolveFinalPath wide
      return wideAttributes resolved, request if resolved and resolved != path

  attributes = buildAttributes data, path, asLink
  attributes.target = resolveFinalPath(wide) or path if asLink
  return selectAttributes attributes, request

---Reads a path's attributes without following a reparse point, as `lfs.symlinkattributes` does,
---adding the `target` field it reports alongside them.
---@param path string
---@param request? string|table A field name, a table to fill, or nil for a fresh one.
---@return table|string|integer|nil result
---@return string? err
---@return integer? errno
wideSymlinkAttributes = (path, request) -> wideAttributes path, request, true

---Reads a path's attributes, delegating to the host's implementation first and widening only where
---that came up empty for a path holding a non-ASCII byte. An ASCII path therefore keeps the host's
---own answer, richer field set included, and so does a host that resolves such a path unaided.
---@param path string
---@param request? string|table A field name, a table to fill, or nil.
---@return table|string|integer|nil result
---@return string? err
---@return integer? errno
attributes = (path, request) ->
  value, err, errno = state.original.attributes path, request
  return value, err, errno if value != nil
  return value, err, errno unless type(path) == "string" and holdsNonAscii path
  return wideAttributes path, request

---Iterates a directory's entries through the UTF-16 Windows API, dot entries included, as `lfs.dir` does.
---@param path string
---@return fun(): string? iterator
---@return table directory An object with `next` and `close`, as the rock hands back.
wideDir = (path) ->
  -- a trailing separator would double up against the wildcard, and stripping one would turn a drive
  -- root into the drive's current directory
  pattern = path .. (path\match("[\\/]$") and "*" or "\\*")
  wide, err = ffiWindows.toWide pattern
  error msgs.dir.cannotOpen\format(path, err), 2 unless wide

  data = types.WIN32_FIND_DATAW!
  handle = kernel32.FindFirstFileW wide, data
  if handle == INVALID_HANDLE
    description = ffiWindows.describeLastError!
    error msgs.dir.cannotOpen\format(path, description), 2

  -- the search handle is a process resource, so an abandoned iterator has to release it too
  handle = ffi.gc handle, kernel32.FindClose
  -- FindFirstFileW has already filled in the first entry
  pending = true

  directory = {
    close: =>
      return unless handle
      ffi.gc handle, nil
      kernel32.FindClose handle
      handle = nil

    next: =>
      return nil unless handle
      if pending
        pending = false
      elseif 0 == kernel32.FindNextFileW handle, data
        @close!
        return nil
      return ffiWindows.fromWide data.cFileName, wideStringLength data.cFileName, FIND_DATA_NAME_CAPACITY
  }

  return (-> directory\next!), directory

---Creates a directory through the UTF-16 Windows API.
---@param path string
---@return boolean? created True on success, nil with a message otherwise.
---@return string? err
wideMkdir = (path) ->
  wide, err = ffiWindows.toWide path
  return nil, err unless wide
  return true if 0 != kernel32.CreateDirectoryW wide, nil
  return nil, (ffiWindows.describeLastError!)

---Removes an empty directory through the UTF-16 Windows API.
---@param path string
---@return boolean? removed True on success, nil with a message otherwise.
---@return string? err
wideRmdir = (path) ->
  wide, err = ffiWindows.toWide path
  return nil, err unless wide
  return true if 0 != kernel32.RemoveDirectoryW wide
  return nil, (ffiWindows.describeLastError!)

---Changes the process working directory through the UTF-16 Windows API.
---@param path string
---@return boolean? changed True on success, nil with a message otherwise.
---@return string? err
wideChdir = (path) ->
  wide, err = ffiWindows.toWide path
  return nil, msgs.chdir.failed\format(path, err) unless wide
  return true if 0 != kernel32.SetCurrentDirectoryW wide
  return nil, msgs.chdir.failed\format path, (ffiWindows.describeLastError!)

---Reads the process working directory through the UTF-16 Windows API.
---@return string? path The current directory as UTF-8, nil with a message on failure.
---@return string? err
wideCurrentdir = ->
  needed = tonumber kernel32.GetCurrentDirectoryW 0, nil
  return nil, (ffiWindows.describeLastError!) if needed == 0

  buffer = ffi.new "wchar_t[?]", needed
  written = tonumber kernel32.GetCurrentDirectoryW needed, buffer
  return nil, (ffiWindows.describeLastError!) if written == 0
  return ffiWindows.fromWide buffer, written

---Sets a path's access and modification times through the UTF-16 Windows API.
---@param path string
---@param accessTime? integer Seconds since 1970, the current time when absent.
---@param modificationTime? integer Seconds since 1970, matching the access time when absent.
---@return boolean? touched True on success, nil with a message otherwise.
---@return string? err
---@return integer? errno
wideTouch = (path, accessTime, modificationTime) ->
  wide, err = ffiWindows.toWide path
  return nil, err, ffiWindows.Errno.EINVAL unless wide

  accessTime or= os.time!
  modificationTime or= accessTime

  handle = openPath wide, FILE_WRITE_ATTRIBUTES, OPEN_EXISTING
  unless handle
    description, _, errno = ffiWindows.describeLastError!
    return nil, description, errno

  access, modification = types.FILETIME!, types.FILETIME!
  toFileTime access, accessTime
  toFileTime modification, modificationTime

  written = kernel32.SetFileTime handle, nil, access, modification
  description, errno = nil, nil
  description, _, errno = ffiWindows.describeLastError! if written == 0
  ffiWindows.kernel32.CloseHandle handle

  return nil, description, errno if written == 0
  return true

---Creates a hard or symbolic link through the UTF-16 Windows API.
---@param old string The path the link points at.
---@param new string The link to create.
---@param symbolic? boolean Create a symbolic link rather than a hard one.
---@return boolean? linked True on success, nil with a message otherwise.
---@return string? err
---@return integer? errno
wideLink = (old, new, symbolic) ->
  wideOld, oldErr = ffiWindows.toWide old
  return nil, oldErr, ffiWindows.Errno.EINVAL unless wideOld
  wideNew, newErr = ffiWindows.toWide new
  return nil, newErr, ffiWindows.Errno.EINVAL unless wideNew

  created = if symbolic
    -- a symbolic link states at creation whether it names a directory, since it may be made before
    -- the thing it points at exists
    directory = "directory" == wideAttributes(old, "mode")
    flags = bit.bor SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE,
      directory and SYMBOLIC_LINK_FLAG_DIRECTORY or 0
    kernel32.CreateSymbolicLinkW wideNew, wideOld, flags
  else kernel32.CreateHardLinkW wideNew, wideOld, nil

  return true if created != 0
  description, _, errno = ffiWindows.describeLastError!
  return nil, description, errno

---Locks a directory by creating the marker file `lfs` locks with, through the UTF-16 Windows API.
---@param path string The directory to lock.
---@param staleSeconds? number Age past which an existing lock is taken as abandoned and removed.
---@return userdata? lock An object whose `free` method releases the lock, released on collection too. Nil when the directory is already locked.
---@return string? err
wideLockDir = (path, staleSeconds) ->
  lockPath = "#{path}\\#{LOCK_FILE_NAME}"

  if staleSeconds
    existing = wideAttributes lockPath
    removeFile lockPath if "table" == type(existing) and
      os.time! - existing.modification > staleSeconds

  wide, err = ffiWindows.toWide lockPath
  return nil, err unless wide

  handle = openPath wide, GENERIC_WRITE, CREATE_NEW
  return nil, (ffiWindows.describeLastError!) unless handle
  ffiWindows.kernel32.CloseHandle handle

  -- userdata rather than a table, so an abandoned lock is released on collection as the rock's is
  lock = newproxy true
  released = false
  release = ->
    return if released
    released = true
    removeFile lockPath

  meta = getmetatable lock
  meta.__index = {free: release}
  meta.__gc = release
  return lock

rockOnlyReplacements = {dir: wideDir, mkdir: wideMkdir, rmdir: wideRmdir, chdir: wideChdir,
  currentdir: wideCurrentdir, touch: wideTouch, link: wideLink, lock_dir: wideLockDir,
  symlinkattributes: wideSymlinkAttributes}

---Gives `lfs` UTF-8 path handling on Windows, where it otherwise reads a path in the system code page
---and reports anything holding a non-ASCII character as non-existent, unless the machine is set to
---the UTF-8 code page (65001). Linux and macOS are unaffected. Which calls are wrong depends on the
---host:
---
--- * The luafilesystem rock calls the ANSI runtime throughout, so every call taking a path misses.
--- * Aegisub's own `lfs` goes through `agi::fs::path` everywhere but `get_mode`, which hands its bytes
---   to `std::filesystem` directly; both `attributes(path, "mode")` and `attributes(path)` fail with
---   it, the latter because it returns early on a nil mode. Fixed upstream by
---   https://github.com/TypesettingTools/Aegisub/pull/666.
---
---Covers every call that takes a path and is provided by the host lfs implementation.
---
---@class LfsUnicodePatch
LfsUnicodePatch = {
  ---Replaces the affected `lfs` calls on Windows, in the module table itself so a caller that
  ---already required it sees the layer too. Idempotent across self-update reloads.
  ---@return boolean installed Whether the layer is in place, true as well when an earlier call put it there.
  ---@return string? reason Why it is not, absent when it is.
  install: ->
    return false, msgs.install.notWindows unless ffi.os == "Windows"
    return true if state.installed
    return false, msgs.install.unavailable unless kernel32Binding.isAvailable and
      kernel32Binding.hasSymbol "GetFileAttributesExW"

    -- `attributes` is wrong in both implementations, so it is layered whichever one this is
    state.original.attributes = lfs.attributes
    lfs.attributes = attributes

    -- The rock declares its version where Aegisub's built-in module does not, and it is the one
    -- whose every call reads the path in the code page. Aegisub's rest already take UTF-8, so
    -- replacing them would trade a working implementation for another.
    if type(lfs._VERSION) == "string"
      for name, replacement in pairs rockOnlyReplacements
        -- only ever replace, so a script cannot come to rely on a call the host never offered
        continue unless lfs[name]
        state.original[name] = lfs[name]
        lfs[name] = replacement

    state.installed = true
    return true
}

return LfsUnicodePatch
