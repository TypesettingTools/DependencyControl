aegisub = require "l0.AegisubShims.aegisub"

-- Aegisub ships some of its automation API as ordinary Lua modules beside the `aegisub` global, which
-- a script reaches by require. Claiming those require ids in package.preload puts the shims ahead of
-- the path searchers, and a loader body only runs once something asks for that module.
package.preload["aegisub.util"] = -> require "l0.AegisubShims.util"
package.preload["aegisub.re"] = -> require "l0.AegisubShims.re"

-- Re-expose the shim's configuration hooks (see AegisubShims.aegisub) so callers can
-- relocate path tokens without reaching into the faux `aegisub` global.
return {
  :aegisub
  setPathToken: aegisub.__depCtrl.setPathToken
  getPathToken: aegisub.__depCtrl.getPathToken
}
