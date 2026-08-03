utils = require "l0.DependencyControl.utils"

msgs = {
  include: {
    unsupported: "Aegisub's include('%s') has no headless stand-in. Available: %s."
  }
}

---One of Aegisub's thin include files, which publishes a module as a global and may hand it back.
---@class AegisubIncludeFile
---@field global string Name of the global the file publishes.
---@field moduleName string Require id of the module it publishes.
---@field returns boolean Whether the file also returns that module to its caller.

---The include files a shim can serve, keyed by the file name Aegisub knows them under.
---@type table<string, AegisubIncludeFile>
includeFiles = {
  "clipboard.lua": {global: "clipboard", moduleName: "l0.AegisubShims.clipboard", returns: true}
  "re.lua": {global: "re", moduleName: "l0.AegisubShims.re", returns: true}
  "unicode.lua": {global: "unicode", moduleName: "l0.AegisubShims.unicode", returns: true}
  -- utils.lua is a one-line alias for utils-auto4.lua, and neither hands the module back
  "utils-auto4.lua": {global: "util", moduleName: "l0.AegisubShims.util", returns: false}
  "utils.lua": {global: "util", moduleName: "l0.AegisubShims.util", returns: false}
  "lfs.lua": {global: "lfs", moduleName: "lfs", returns: true}
}

supportedNames = table.concat [name for name in pairs includeFiles], ", "

---Loads one of Aegisub's include files, publishing its global exactly as the real file does.
---@param fileName string Plain file name, as Aegisub's include takes it.
---@return any? included The module for a file that returns one, nil for one that only sets its global.
include = (fileName) ->
  utils.assertArgType fileName, 1, "string"
  entry = includeFiles[fileName]
  error msgs.include.unsupported\format(fileName, supportedNames), 2 unless entry

  loaded = require entry.moduleName
  _G[entry.global] = loaded
  return loaded if entry.returns

---Headless stand-in for Aegisub's `include` script global. Instead of reading include files from disk,
---it serves the shims we have available and throws for any other name.
---@class AegisubShimsInclude
return {:include, :includeFiles}
