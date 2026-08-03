aegisub = require "l0.AegisubShims.aegisub"
clipboard = require "l0.AegisubShims.clipboard"
includeShim = require "l0.AegisubShims.include"
re = require "l0.AegisubShims.re"
unicode = require "l0.AegisubShims.unicode"
util = require "l0.AegisubShims.util"

-- Aegisub ships some of its automation API as ordinary Lua modules beside the `aegisub` global, which
-- a script reaches by require. Claiming those require ids in package.preload puts the shims ahead of
-- the path searchers, and a loader body only runs once something asks for that module.
package.preload["aegisub.util"] = -> util
package.preload["aegisub.re"] = -> re
package.preload["aegisub.unicode"] = -> unicode
package.preload["aegisub.clipboard"] = -> clipboard

-- Register the globals unconditionally exposed by Aegisub
_G.aegisub = aegisub
_G.include = includeShim.include

-- Aegisub's include files are also reachable by requiring their bare identifiers
-- and publish their module as a global once they are loaded in whichever way.
for fileName, entry in pairs includeShim.includeFiles
  shortId = fileName\gsub "%.lua$", ""
  -- a preloader for a module already exclusively reachable through its bare identifier
  -- is not just unnecessary, but would also cause an infinite recursion.
  continue if shortId == entry.moduleName
  package.preload[shortId] = -> includeShim.include fileName

return {
  :aegisub
  :clipboard
  include: includeShim.include,
  :re
  :unicode
  :util
  -- Re-expose the shim's configuration hooks for callers.
  setPathToken: aegisub.__depCtrl.setPathToken
  getPathToken: aegisub.__depCtrl.getPathToken
  setClipboardBackend: clipboard.__depCtrl.setBackend
  getClipboardBackend: clipboard.__depCtrl.getBackend
}
