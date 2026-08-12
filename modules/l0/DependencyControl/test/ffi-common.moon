-- Pins the C API values every supported platform shares, and the extension the platform helpers build
-- their own tables with. The values themselves are transcribed from errno.h, so what is worth checking
-- is that the shared table stays free of anything a platform disagrees on, and that extending it never
-- reaches back into the shared copy.
-- Called from test.moon as: (controls\requireTest "ffi-common")!
->
  ffi = require "ffi"
  ffiCommon = require "l0.DependencyControl.helpers.ffi-common"
  ffiPosix = require "l0.DependencyControl.helpers.ffi-posix"
  ffiWindows = require "l0.DependencyControl.helpers.ffi-windows"

  isWindows = ffi.os == "Windows"
  isOSX = ffi.os == "OSX"

  {
    _description: "The shared C error codes and the per-platform tables built from them."

    -- 11 and everything above 34 are where the three platforms part company, so a code from either
    -- belongs to a platform's own table rather than the shared one
    errno_sharedTableHoldsOnlyPortableCodes: (ut) ->
      for name, value in pairs ffiCommon.Errno
        ut\assertInRange value, 1, 34
        ut\assertNotEquals value, 11, "#{name} is 11, which the platforms disagree on"

    errno_sharedTableCarriesTheCommonCodes: (ut) ->
      ut\assertEquals ffiCommon.Errno.ENOENT, 2
      ut\assertEquals ffiCommon.Errno.EACCES, 13
      ut\assertEquals ffiCommon.Errno.EEXIST, 17
      ut\assertEquals ffiCommon.Errno.ENOTDIR, 20
      ut\assertEquals ffiCommon.Errno.EINVAL, 22

    extendErrno_addsToACopyAndLeavesTheSharedTableAlone: (ut) ->
      -- ENOSYS is a real code the shared table leaves out, which is what an addition looks like
      extended = ffiCommon.extendErrno {ENOSYS: 40}
      ut\assertEquals extended.ENOSYS, 40
      ut\assertEquals extended.ENOENT, ffiCommon.Errno.ENOENT
      ut\assertNil ffiCommon.Errno.ENOSYS
      ut\assertIsNot extended, ffiCommon.Errno

    extendErrno_anAdditionOverridesASharedCode: (ut) ->
      extended = ffiCommon.extendErrno {ENOENT: 998}
      ut\assertEquals extended.ENOENT, 998
      ut\assertEquals ffiCommon.Errno.ENOENT, 2

    -- the pair swap places between the two kernels, which is why neither is shared
    errno_posixTableNumbersItsOwnPairForThisPlatform: (ut) ->
      ut\assertEquals ffiPosix.Errno.EAGAIN, isOSX and 35 or 11
      ut\assertEquals ffiPosix.Errno.EDEADLK, isOSX and 11 or 35
      ut\assertEquals ffiPosix.Errno.ENOENT, ffiCommon.Errno.ENOENT

    errno_windowsTableNumbersTheRuntimesOwnCodes: (ut) ->
      ut\assertEquals ffiWindows.Errno.EAGAIN, 11
      ut\assertEquals ffiWindows.Errno.ENOTEMPTY, 41
      ut\assertEquals ffiWindows.Errno.ENOENT, ffiCommon.Errno.ENOENT

    -- EDEADLOCK is a second name for the same code, which is what keeps this a table and not an Enum
    errno_windowsTableCarriesTheRuntimesAlias: (ut) ->
      ut\assertEquals ffiWindows.Errno.EDEADLOCK, ffiWindows.Errno.EDEADLK

    errno_platformTablesAreIndependent: (ut) ->
      ut\assertIsNot ffiPosix.Errno, ffiWindows.Errno

    -- a failed Win32 call has to report the errno the C runtime would have set, since the lfs contract
    -- the patch stands in for is stated in those
    describeLastError_reportsTheRuntimesErrno: (ut) ->
      ut\skip "Win32 errors only exist on Windows" unless isWindows

      -- GetFileAttributesExW is not bound here, so provoke the error through a call that is
      ut\assertNil ffiWindows.toWide "\255\254"
      description, code, errno = ffiWindows.describeLastError!
      ut\assertString description
      ut\assertNumber code
      ut\assertNumber errno
  }
