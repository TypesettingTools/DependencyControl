--- The error codes defined by the C <errno.h> header that are common to all supported platforms.
---@class FfiErrno
Errno = {
  EPERM: 1 -- operation not permitted
  ENOENT: 2 -- no such file or directory
  ESRCH: 3 -- no such process
  EINTR: 4 -- interrupted system call
  EIO: 5 -- input/output error
  ENXIO: 6 -- no such device or address
  E2BIG: 7 -- argument list too long
  ENOEXEC: 8 -- exec format error
  EBADF: 9 -- bad file descriptor
  ECHILD: 10 -- no child processes
  -- 11 is EAGAIN on Linux and Windows but EDEADLK on macOS, so it is absent from the shared table
  ENOMEM: 12 -- cannot allocate memory
  EACCES: 13 -- permission denied
  EFAULT: 14 -- bad address
  ENOTBLK: 15 -- block device required
  EBUSY: 16 -- device or resource busy
  EEXIST: 17 -- file exists
  EXDEV: 18 -- invalid cross-device link
  ENODEV: 19 -- no such device
  ENOTDIR: 20 -- not a directory
  EISDIR: 21 -- is a directory
  EINVAL: 22 -- invalid argument
  ENFILE: 23 -- too many open files in system
  EMFILE: 24 -- too many open files
  ENOTTY: 25 -- inappropriate ioctl for device
  ETXTBSY: 26 -- text file busy
  EFBIG: 27 -- file too large
  ENOSPC: 28 -- no space left on device
  ESPIPE: 29 -- illegal seek
  EROFS: 30 -- read-only file system
  EMLINK: 31 -- too many links
  EPIPE: 32 -- broken pipe
  EDOM: 33 -- numerical argument out of domain
  ERANGE: 34 -- numerical result out of range
  -- 35 and above diverge between the three platforms, so each platform's helper adds those itself
}

---C API values that are the same on every supported platform, for the platform helpers to extend.
---@class FfiCommon
Common = {
  ---@type FfiErrno
  Errno: Errno

  ---Builds a platform's error-code table from the shared codes plus the ones only it defines.
  ---@param additions table<string, integer> Codes to add, by their C names. A name already shared is overwritten, which is how a platform that numbers one differently states so.
  ---@return FfiErrno errno A fresh table, so one platform's additions never reach another's.
  extendErrno: (additions) ->
    extended = {name, value for name, value in pairs Errno}
    extended[name] = value for name, value in pairs additions
    return extended
}

return Common
