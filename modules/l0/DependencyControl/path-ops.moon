ffi = require "ffi"
constants = require "l0.DependencyControl.Constants"
utils = require "l0.DependencyControl.utils"

-- Filesystem path length limits.
WINDOWS_MAX_PATH = 260 -- Windows with long path support disabled
WINDOWS_LONG_PATH_MAX = 32767 -- Windows with long path support enabled
MAX_PATH_COMPONENT = 255 -- per-segment limit on NTFS and common POSIX filesystems
POSIX_PATH_MAX = 4096 -- typical full-path limit on modern POSIX systems

---Stand-in token for each token only newer Aegisub builds resolve, keyed by the newer token.
fallbacks = {
  "?state": "?user"
}

msgs = {
  joinPath: {
    invalidSegment: "Invalid path segment type: expected a string or pure array table, got '%s'."
  }
  resolveFullPath: {
    badType: "Argument #%s (%s) had the wrong type. Expected 'string', got '%s'."
    tooLong: "The specified path exceeded the maximum length limit (%d > %d)."
    tooLongRegistryDisabled: "The specified path exceeded the Windows MAX_PATH limit (%d > %d characters) and long path support is disabled on this system.\nEnable it by setting the registry value 'HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\\LongPathsEnabled' (DWORD) to 1 and restarting, e.g. by running this in an elevated PowerShell:\n  Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem' -Name 'LongPathsEnabled' -Value 1 -Type DWord"
    tooLongProcessUnaware: "The specified path exceeded the Windows MAX_PATH limit (%d > %d characters). Long path support is enabled system-wide, but the host application is not long-path-aware (its executable manifest lacks the 'longPathAware' setting), so paths remain capped at %d characters in this process."
    segmentTooLong: "A path component exceeded the maximum length limit (%d > %d): '%s'."
    invalidChars: "The specified path contains one or more invalid characters: '%s'."
    reservedNames: "The specified path contains reserved path or file names: '%s'."
    parentPath: "Accessing parent directories is not allowed."
    notFullPath: "The specified path is not a valid full path."
    missingExt: "The specified path is missing a file extension."
  }
}

windowsReservedNameSet = {n, true for n in *{
  "CON", "PRN", "AUX", "NUL",
  "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
  "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
}}

---Reports whether the current process can use paths beyond the legacy MAX_PATH limit.
---@return boolean enabled True when this process may use long paths.
detectProcessLongPathsEnabled = ->
  -- ntdll!RtlAreLongPathsEnabled gives the effective per-process answer, folding in both the
  -- system registry policy and the process's manifest opt-in. A process whose executable manifest
  -- lacks the `longPathAware` setting stays capped at MAX_PATH even when the registry enables long
  -- paths. The symbol arrived in Windows 10 1607, when long paths were introduced. On older systems
  -- it is absent and long paths are unsupported, so they read as disabled.
  okLib, ntdll = pcall ffi.load, "ntdll"
  return false unless okLib
  pcall ffi.cdef, "unsigned char RtlAreLongPathsEnabled(void);"
  ok, enabled = pcall -> ntdll.RtlAreLongPathsEnabled! != 0
  return ok and enabled

---Reads the system-wide LongPathsEnabled policy from the Windows registry (HKLM\…\Control\FileSystem).
---@return boolean enabled True when the value is present and set to 1; false when it is missing, zero, or unreadable.
detectRegistryLongPathsEnabled = ->
  -- This reflects the system policy only, not the per-process manifest. It exists just to tailor
  -- the diagnostic when a path is rejected — telling "long paths are off system-wide" apart from
  -- "they're on, but this application isn't long-path-aware".
  okLib, advapi = pcall ffi.load, "advapi32"
  return false unless okLib
  pcall ffi.cdef, [[
    long RegOpenKeyExA(uintptr_t hKey, const char* subKey, unsigned long options, unsigned long samDesired, uintptr_t* result);
    long RegQueryValueExA(uintptr_t hKey, const char* valueName, unsigned long* reserved, unsigned long* type, unsigned char* data, unsigned long* dataSize);
    long RegCloseKey(uintptr_t hKey);
  ]]
  -- HKEY_LOCAL_MACHINE is (HKEY)(LONG)0x80000002; the int32->uintptr cast reproduces
  -- the sign-extended pointer value the API expects on both 32- and 64-bit builds.
  HKEY_LOCAL_MACHINE = ffi.cast "uintptr_t", ffi.cast "int32_t", 0x80000002
  KEY_READ, ERROR_CODE_SUCCESS = 0x20019, 0
  hKey = ffi.new "uintptr_t[1]"
  return false unless ERROR_CODE_SUCCESS == advapi.RegOpenKeyExA HKEY_LOCAL_MACHINE,
    "SYSTEM\\CurrentControlSet\\Control\\FileSystem", 0, KEY_READ, hKey
  value = ffi.new "unsigned long[1]"
  size = ffi.new "unsigned long[1]", ffi.sizeof "unsigned long"
  status = advapi.RegQueryValueExA hKey[0], "LongPathsEnabled", nil, nil,
    ffi.cast("unsigned char*", value), size
  advapi.RegCloseKey hKey[0]
  return status == ERROR_CODE_SUCCESS and value[0] == 1

windowsProcessLongPathsEnabled, windowsRegistryLongPathsEnabled = false, false
if ffi.os == "Windows"
  ok, res = pcall detectProcessLongPathsEnabled
  windowsProcessLongPathsEnabled = ok and res
  -- only needed to explain *why* long paths are unavailable
  unless windowsProcessLongPathsEnabled
    ok, res = pcall detectRegistryLongPathsEnabled
    windowsRegistryLongPathsEnabled = ok and res

-- effective full-path limit; on Windows this depends on whether *this process*
-- can use long paths (see detectProcessLongPathsEnabled)
pathMaxLength = if ffi.os == "Windows"
  windowsProcessLongPathsEnabled and WINDOWS_LONG_PATH_MAX or WINDOWS_MAX_PATH
else POSIX_PATH_MAX

---Lua patterns for matching path structure on the host platform.
---@class PathMatchPatterns
---@field sep string The native separator, escaped for use in a pattern.
---@field sepAll string Character class matching either separator.
---@field invalidChars string Character class matching characters no path component may contain.

-- forward-declared so the members below close over the local rather than a global of the same name
local PathOps

---Path composition, validation and normalization, plus Aegisub path-token resolution; nothing here
---touches the filesystem. `?state` falls back to `?user` on a build that predates the token.
---@class PathOps
PathOps = {
  ---@type string
  pathSep: ffi.os == "Windows" and "\\" or "/"
  ---@type PathMatchPatterns
  pathMatch: {
    sep: ffi.os == "Windows" and "\\" or "/"
    sepAll: ffi.os == "Windows" and "[\\/]" or "/"
    invalidChars: '[<>:"|%?%*%z%c;]'
  }
  ---@type integer
  pathMaxLength: pathMaxLength
  pathMaxSegmentLength: MAX_PATH_COMPONENT
  -- true when running on Windows but capped at the legacy MAX_PATH limit because this process
  -- can't use long paths. Drives the descriptive error below, and is always false off Windows.
  longPathsDisabled: ffi.os == "Windows" and not windowsProcessLongPathsEnabled
  -- when capped, whether the system registry policy enables long paths -- lets the error
  -- tell a system-wide opt-out apart from an app that isn't long-path-aware
  windowsRegistryLongPathsEnabled: windowsRegistryLongPathsEnabled

  ---Memoized `token -> isSupported` probe results; a test stubbing decode_path clears it directly.
  ---UnitTestSuite loads through Logger, which loads this module, so its test exports are out of reach here.
  ---@private
  __tokenSupport: {}

  ---Reports whether the running Aegisub resolves the given path token to a directory.
  ---@param token string The token to probe, leading "?" included.
  ---@return boolean isSupported False when Aegisub doesn't know the token or leaves it unset.
  isTokenSupported: (token) ->
    supported = PathOps.__tokenSupport[token]
    return supported unless supported == nil
    -- a token Aegisub can't resolve comes back verbatim, a resolved one as its directory
    supported = aegisub.decode_path(token) != token
    PathOps.__tokenSupport[token] = supported
    return supported

  ---Resolves every Aegisub path token in a path against the running build.
  ---Token matching is prefix-based, as in Aegisub itself, so a separator after the token is optional.
  ---@param path string A path that may start with an Aegisub path token.
  ---@return string decodedPath The path with all tokens resolved to absolute directories.
  decode: (path) ->
    for token, fallback in pairs fallbacks
      continue unless path\sub(1, #token) == token
      continue if PathOps.isTokenSupported token
      path = fallback .. path\sub #token + 1
      break
    return aegisub.decode_path path

  ---Generates a unique temporary directory path that does not exist yet.
  ---@return string tempDirPath Absolute path to a unique, not-yet-existing temporary directory.
  getTempDir: () ->
    return PathOps.decode "?temp/#{constants.DEPCTRL_NAMESPACE}_#{'%04X'\format math.random 0, 16^4-1}"

  ---Joins and resolves multiple path segments into a single path string.
  ---@param ... string|string[] One or more path segments, or arrays of path segments.
  ---@return string? joinedPath The path segments joined by OS-specific separators, or nil on error.
  ---@return string? err
  joinPath: (...) ->
    args = {...}
    -- detect root from the first string before splitting consumes separators
    firstStr = type(args[1]) == "table" and args[1][1] or args[1]
    return nil, msgs.joinPath.invalidSegment\format type firstStr if type(firstStr) ~= "string"
    absolutePathRoot = type(firstStr) == "string" and PathOps._getPathRoot firstStr

    invalidPathSegmentType = nil
    flatPathSegments = utils.flatten args, 3, (value, typ) ->
      if typ != "string"
        invalidPathSegmentType = typ
        return {}, true -- error is raised below via invalidPathSegmentType; contribute nothing here

      firstSegment, moreSegments = nil, nil
      for segment in PathOps.pathSegments value
        if firstSegment
          moreSegments or= {firstSegment}
          table.insert moreSegments, segment
        else firstSegment = segment
      -- an empty or separator-only segment has no components: return {} so it adds nothing, rather
      -- than a nil that would leave a hole and stop the ipairs walk over the flattened segments
      return {}, true unless firstSegment
      return moreSegments or firstSegment, moreSegments
    return nil, msgs.joinPath.invalidSegment\format invalidPathSegmentType if invalidPathSegmentType

    -- filter extraneous '.', resolve '..', and clamp path traversal at root
    segments = {}
    for i, segment in ipairs flatPathSegments
      switch segment
        when "." then segments[#segments + 1] = segment if i == 1 and not absolutePathRoot
        when ".."
          if #segments > (absolutePathRoot and 1 or 0) and segments[#segments] != ".."
            segments[#segments] = nil
          elseif not absolutePathRoot
            segments[#segments + 1] = segment
        else segments[#segments + 1] = segment
    -- re-add root separator for absolute paths on POSIX systems removed by splitting
    return "#{absolutePathRoot and ffi.os != "Windows" and PathOps.pathSep or ""}#{table.concat segments, PathOps.pathSep}"

  ---Returns an iterator over the non-empty components of a path, split on any separator.
  ---@param path string
  ---@return fun(): string? iterator
  pathSegments: (path) -> path\gmatch "[^/\\]+"

  ---Extracts the root anchor of an absolute path. Shared with FileOps, which splits it back off the
  ---directory for the pre-0.9 shape its own callers still expect; not general public API.
  ---@param absolutePath string The absolute path to inspect.
  ---@return string? root On Windows the drive prefix with its separator (e.g. "C:\"), on POSIX the leading slash plus first segment (e.g. "/usr"), or nil when the path has no such root.
  _getPathRoot: (absolutePath) ->
    return absolutePath\match "^[A-Za-z]:[/\\]" if ffi.os == "Windows"
    return absolutePath\match "^/[^/\\]+"

  ---Validates and normalizes an absolute filesystem path.
  ---@param path string|string[] Either a path or an array of path segments.
  ---@param checkFileExt? boolean Require the path to have a file extension.
  ---@param basePath? string|string[] Base path to resolve relative paths against; relative paths are rejected without it.
  ---@return string|false|nil normalizedPath The normalized path, false when it isn't absolute, nil on error.
  ---@return string? err Set only on failure.
  ---@return string? dir The absolute directory holding the path's leaf (success only).
  ---@return string? file The leaf's file name, nil when the path names a directory (success only).
  resolveFullPath: (path, checkFileExt, basePath) ->
    if "table" == type path
      path, errMsg = PathOps.joinPath path
      return nil, errMsg if not path
    elseif "string" != type path
      return nil, msgs.resolveFullPath.badType\format 1, "path", type(path)

    if "table" == type basePath
      basePath, errMsg = PathOps.joinPath basePath
      return nil, errMsg if not basePath
    elseif basePath and "string" != type basePath
      return nil, msgs.resolveFullPath.badType\format 3, "basePath", type(basePath)

    -- expand aegisub path specifiers
    path = PathOps.decode path
    -- expand home directory on linux
    homeDir = os.getenv "HOME"
    path = path\gsub "^~", "#{homeDir}/" if homeDir
    -- use single native path separators
    path = path\gsub "[\\/]+", PathOps.pathSep
    -- check length
    if #path > PathOps.pathMaxLength
      if PathOps.longPathsDisabled
        -- distinguish a system-wide opt-out from an app that isn't long-path-aware
        if PathOps.windowsRegistryLongPathsEnabled
          return nil, msgs.resolveFullPath.tooLongProcessUnaware\format #path, PathOps.pathMaxLength, PathOps.pathMaxLength
        return nil, msgs.resolveFullPath.tooLongRegistryDisabled\format #path, PathOps.pathMaxLength
      return nil, msgs.resolveFullPath.tooLong\format #path, PathOps.pathMaxLength
    -- check for invalid characters
    invChar = path\match PathOps.pathMatch.invalidChars, ffi.os == "Windows" and 3 or nil
    if invChar
      return nil, msgs.resolveFullPath.invalidChars\format invChar
    -- check if path is absolute
    root = PathOps._getPathRoot path
    unless root
      -- make relative paths absolute if base path is provided
      if basePath
        path, errMsg = PathOps.joinPath basePath, path
        return nil, errMsg if not path
        root = PathOps._getPathRoot path
      else return false, msgs.resolveFullPath.notFullPath
    -- parse path structure; the root is split off so the segment checks below skip it
    rest = path\sub #root + 1
    dir, file = rest\match "^(.*)[/\\]([^/\\]*)$"
    unless dir
      return false, msgs.resolveFullPath.notFullPath
    for segment in PathOps.pathSegments rest
      if #segment > PathOps.pathMaxSegmentLength
        return nil, msgs.resolveFullPath.segmentTooLong\format #segment, PathOps.pathMaxSegmentLength, segment
      if ffi.os == "Windows"
        segmentWithoutExt = segment\match("^[^%.]+") or segment
        if windowsReservedNameSet[segmentWithoutExt\upper!]
          return nil, msgs.resolveFullPath.reservedNames\format segmentWithoutExt
      unless segment\match "[^%.%s]$"
        return nil, msgs.resolveFullPath.notFullPath
    file = file != "" and file or nil
    if checkFileExt and not (file and file\match ".+%.+")
      return false, msgs.resolveFullPath.missingExt

    dir = root .. dir
    path = table.concat {dir, file and PathOps.pathSep, file}
    return path, nil, dir, file
}

return PathOps
