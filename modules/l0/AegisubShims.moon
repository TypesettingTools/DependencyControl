aegisub = require "l0.AegisubShims.aegisub"
includeShim = require "l0.AegisubShims.include"
-- Aegisub unconditionally exposes the aegisub and include globals
_G.aegisub = aegisub
_G.include = includeShim.include

ass = require "l0.AegisubShims.ass"
clipboard = require "l0.AegisubShims.clipboard"
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

-- Aegisub runs this for every Lua state it creates on Windows, so the CLI has to as well or its paths
-- reach the C runtime in a different encoding than they do in Aegisub. It reports what it did rather
-- than raising, since every platform but Windows needs nothing.
unicodePatch = require "l0.AegisubShims.unicode-monkeypatch"

textExtents = require "l0.AegisubShims.text-extents"
textExtentsGdi = require "l0.AegisubShims.text-extents-backends.gdi"
textExtentsCoreText = require "l0.AegisubShims.text-extents-backends.coretext"
textExtentsFreeType = require "l0.AegisubShims.text-extents-backends.freetype"
textExtentsPango = require "l0.AegisubShims.text-extents-backends.pango"

-- The default backend measures by the Windows contract: GDI natively on Windows, CoreText natively
-- on macOS, FreeType with fontconfig everywhere else. Where none is reachable, text_extents keeps
-- raising until a caller installs a backend of its own.
defaultTextExtentsBackend = textExtents.selectBackend!
aegisub.__depCtrl.setTextExtentsBackend defaultTextExtentsBackend if defaultTextExtentsBackend

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
  -- the shapes Aegisub's data model carries, rather than a module a script requires by name
  Ass: ass
  -- Re-expose the shim's configuration hooks for callers.
  setPathToken: aegisub.__depCtrl.setPathToken
  getPathToken: aegisub.__depCtrl.getPathToken
  setClipboardBackend: clipboard.__depCtrl.setBackend
  getClipboardBackend: clipboard.__depCtrl.getBackend
  setTextExtentsBackend: aegisub.__depCtrl.setTextExtentsBackend
  getTextExtentsBackend: aegisub.__depCtrl.getTextExtentsBackend
  selectTextExtentsBackend: textExtents.selectBackend
  TextExtentsMetricMode: textExtents.MetricMode
  -- The measurement backends themselves, for building a configured one to install through the hook.
  TextExtents: textExtents
  TextExtentsGdi: textExtentsGdi
  TextExtentsCoreText: textExtentsCoreText
  TextExtentsFreeType: textExtentsFreeType
  TextExtentsPango: textExtentsPango
  :unicodePatch
}
