-- POSIX open(2) flag/mode constants for FFI callers, with the per-OS numeric values
-- folded in. Linux values are the asm-generic ones used by x86/x86_64/arm/arm64 (the
-- platforms Aegisub ships on); a few historical arches (alpha, mips, parisc, sparc) differ
-- but are not supported. macOS (Darwin) values are taken from <sys/fcntl.h>.

ffi = require "ffi"

isOSX = ffi.os == "OSX"

filePermissionBits = {r: 4, w: 2, x: 1}

-- open(2) is variadic (int open(const char*, int, ...)); the open wrapper below passes the mode as
-- typed cdata so the Apple-Silicon vararg ABI (stack-passed) receives it intact.
pcall ffi.cdef, [[
  int open(const char* path, int flags, ...);
  int close(int fd);
]]

---@type boolean
isAvailable = ffi.os != "Windows" and pcall(-> ffi.C.open)

---The access mode an open(2) call takes in the low two bits of its flags. Same on Linux and macOS.
---@class PosixFileAccessMode
---@field Read integer O_RDONLY, opening for reading only.
---@field Write integer O_WRONLY, opening for writing only.
---@field ReadWrite integer O_RDWR, opening for both.

---Flags OR'd into an open(2) call alongside its access mode. The numeric values differ by OS.
---@class PosixFileCreationFlags
---@field Create integer O_CREAT, creating the file if it doesn't exist.
---@field Exclusive integer O_EXCL, failing alongside Create if the file already exists.
---@field Truncate integer O_TRUNC, truncating the file to zero length.
---@field NoControllingTerminal integer O_NOCTTY, keeping an opened terminal from becoming the process's controlling terminal.
---@field Directory integer O_DIRECTORY, failing if the path isn't a directory.
---@field NoFollow integer O_NOFOLLOW, failing if the final component is a symlink.
---@field CloseOnExec integer O_CLOEXEC, setting close-on-exec so child processes don't inherit the descriptor.
---@field TmpFile integer O_TMPFILE, creating an unnamed temporary file. Zero on macOS, which has no equivalent, so a caller wanting one there needs another mechanism.

---POSIX open(2) flags, modes and thin call wrappers, for code reaching libc through the FFI. Loads on
---every platform and reports `isAvailable` false where the calls don't resolve, so a caller can branch
---once rather than guarding each call.
---@class FfiPosix
---@field isAvailable boolean Whether this platform is likely POSIX. Gate any use of `open`/`close` on it.
---@field FileAccessMode PosixFileAccessMode
---@field FileCreationFlags PosixFileCreationFlags
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type PosixFileAccessMode
  FileAccessMode: {
    Read: 0
    Write: 1
    ReadWrite: 2
  }

  ---@type PosixFileCreationFlags
  FileCreationFlags: {
    Create: isOSX and 0x200 or 0x40
    Exclusive: isOSX and 0x800 or 0x80
    Truncate: isOSX and 0x400 or 0x200
    NoControllingTerminal: isOSX and 0x20000 or 0x100
    Directory: isOSX and 0x100000 or 0x10000
    NoFollow: isOSX and 0x100 or 0x20000
    CloseOnExec: isOSX and 0x1000000 or 0x80000
    -- the Linux value already includes O_DIRECTORY, as the kernel requires
    TmpFile: isOSX and 0 or 0x410000
  }

  ---Builds the numeric file mode for the given symbolic permissions.
  ---@param user? string Any combination of "r", "w" and "x" for the owner, or "" for none.
  ---@param group? string Same, for the owner's group.
  ---@param other? string Same, for all other users.
  ---@return number mode The file mode, e.g. getFileMode("rwx", "r", "r") -> 0o744 (484).
  getFileMode: (user = "", group = "", other = "") ->
    mode = 0
    for perm in user\gmatch "."
      mode += (filePermissionBits[perm] or 0) * 64
    for perm in group\gmatch "."
      mode += (filePermissionBits[perm] or 0) * 8
    for perm in other\gmatch "."
      mode += filePermissionBits[perm] or 0
    return mode

  ---Opens a file, creating it when the flags include Create (O_CREAT), and returns the raw descriptor.
  ---@param path string Path to open, as a byte string the platform accepts.
  ---@param flags integer open(2) flags, e.g. FileAccessMode.ReadWrite | FileCreationFlags.Create.
  ---@param mode integer Permission bits for a newly created file (from getFileMode).
  ---@return integer fd The open descriptor, or a negative value on failure.
  open: (path, flags, mode) -> ffi.C.open path, flags, ffi.new "int", mode

  ---Closes an open file descriptor.
  ---@param fd integer A descriptor returned by open.
  ---@return integer status Zero on success, or a negative value on failure.
  close: (fd) -> ffi.C.close fd
}
