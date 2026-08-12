-- POSIX open(2) flag/mode constants for FFI callers, with the per-OS numeric values
-- folded in. Linux values are the asm-generic ones used by x86/x86_64/arm/arm64 (the
-- platforms Aegisub ships on); a few historical arches (alpha, mips, parisc, sparc) differ
-- but are not supported. macOS (Darwin) values are taken from <sys/fcntl.h>.

ffi = require "ffi"
Flags = require "l0.DependencyControl.Flags"
ffiBinding = require "l0.DependencyControl.helpers.ffi-binding"
ffiCommon = require "l0.DependencyControl.helpers.ffi-common"

isOSX = ffi.os == "OSX"

filePermissionBits = {r: 4, w: 2, x: 1}

-- open(2) is variadic (int open(const char*, int, ...)); the open wrapper below passes the mode as
-- typed cdata so the Apple-Silicon vararg ABI (stack-passed) receives it intact.
libcBinding = ffiBinding.bind {
  namespace: ffi.C
  functions: {"open", "close"}
  declarations: [[
    int open(const char* path, int flags, ...);
    int close(int fd);
  ]]
}
libc = libcBinding.functions

---@type boolean
isAvailable = ffi.os != "Windows" and libcBinding.hasSymbol "open"

-- The one word open(2) takes, holding an access mode in its low two bits and the creation flags
-- above them. Only the access mode is the same on Linux and macOS; every other value differs.
--
-- O_RDONLY is zero, so a value asking for it cannot be told from one asking for no access mode at
-- all, and the group catches only Write and ReadWrite set together.
---@alias PosixOpenFlags integer A combination of OpenFlags members.
OpenFlags = Flags "PosixOpenFlags", {
  {
    Read: 0 -- O_RDONLY, opening for reading only
    Write: 1 -- O_WRONLY, opening for writing only
    ReadWrite: 2 -- O_RDWR, opening for both
  }
  Create: isOSX and 0x200 or 0x40 -- O_CREAT, creating the file if it doesn't exist
  Exclusive: isOSX and 0x800 or 0x80 -- O_EXCL, failing alongside Create if the file already exists
  Truncate: isOSX and 0x400 or 0x200 -- O_TRUNC, truncating the file to zero length
  -- O_NOCTTY, keeping an opened terminal from becoming the process's controlling terminal
  NoControllingTerminal: isOSX and 0x20000 or 0x100
  Directory: isOSX and 0x100000 or 0x10000 -- O_DIRECTORY, failing if the path isn't a directory
  NoFollow: isOSX and 0x100 or 0x20000 -- O_NOFOLLOW, failing if the final component is a symlink
  -- O_CLOEXEC, so child processes do not inherit the descriptor
  CloseOnExec: isOSX and 0x1000000 or 0x80000
  -- O_TMPFILE, an unnamed temporary file, whose Linux value already includes O_DIRECTORY as the
  -- kernel requires. macOS has no equivalent, so the member is absent there and reading it throws
  -- rather than handing back a zero that would quietly open an ordinary file instead.
  TmpFile: not isOSX and 0x410000 or nil
}

-- The shared codes plus the two the kernels number differently from each other. Linux takes them from
-- asm-generic/errno.h, macOS from sys/errno.h; the pair swap places between the two, and each is the
-- other's value on the platform it isn't.
Errno = ffiCommon.extendErrno {
  EAGAIN: isOSX and 35 or 11 -- resource temporarily unavailable
  EDEADLK: isOSX and 11 or 35 -- resource deadlock avoided
}

---POSIX open(2) flags, modes and thin call wrappers, for code reaching libc through the FFI. Loads on
---every platform and reports `isAvailable` false where the calls don't resolve, so a caller can branch
---once rather than guarding each call.
---@class FfiPosix
---@field isAvailable boolean Whether this platform is likely POSIX. Gate any use of `open`/`close` on it.
---@field OpenFlags Flags The access modes and creation bits open(2) takes, as a PosixOpenFlags flag set.
---@field Errno FfiErrno The error codes by their C names, the shared ones plus this kernel's own.
return {
  ---@type boolean
  isAvailable: isAvailable

  ---@type Flags
  OpenFlags: OpenFlags

  ---@type FfiErrno
  Errno: Errno

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
  ---@param flags PosixOpenFlags open(2) flags, as `OpenFlags` combines its members into.
  ---@param mode integer Permission bits for a newly created file (from getFileMode).
  ---@return integer fd The open descriptor, or a negative value on failure.
  open: (path, flags, mode) -> libc.open path, flags, ffi.new "int", mode

  ---Closes an open file descriptor.
  ---@param fd integer A descriptor returned by open.
  ---@return integer status Zero on success, or a negative value on failure.
  close: (fd) -> libc.close fd
}
