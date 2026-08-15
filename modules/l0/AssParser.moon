DependencyControl = require "l0.DependencyControl"
constants = require "l0.DependencyControl.Constants"

Ass = require "l0.AssParser.ass"
AssFile = require "l0.AssParser.ass-file"
Karaoke = require "l0.AssParser.karaoke"
Scanner = require "l0.AssParser.Scanner"
AssRunState = require "l0.AssParser.RunState"
Arguments = require "l0.AssParser.arguments"
Diagnostics = require "l0.AssParser.diagnostics"
Dialects = require "l0.AssParser.dialects"
Drawing = require "l0.AssParser.drawing"
Emit = require "l0.AssParser.emit"
LineState = require "l0.AssParser.LineState"
Normalize = require "l0.AssParser.normalize"

version = DependencyControl {
  name: "AssParser"
  version: "0.10.0" -- @{l0.AssParser:version}
  description: "Reads, rewrites and writes back ASS files and their override tags."
  author: "line0"
  moduleName: "l0.AssParser"
  url: "https://github.com/TypesettingTools/DependencyControl"
  feed: constants.DEPCTRL_FEED_URL
}

---Reading, rewriting and writing back Advanced SubStation Alpha files and the override tags inside
---them, as Aegisub, libass and xy-VSFilter each read them. Every reading is a dialect's, so which one
---is asked decides the answer wherever the three part.
---
---Nothing here reproduces an Aegisub API or reaches the filesystem beyond `AssFile.readFile`, so a
---script that only wants to read or rewrite a line needs none of the headless shims.
---@class AssParser
---@field version DependencyControlRecord This module's version record.
AssParser = {
  :version
  :Ass
  :AssFile
  :Arguments
  :Diagnostics
  :Dialects
  :Drawing
  :Emit
  :Karaoke
  :LineState
  :Normalize
  :Scanner
  RunState: AssRunState
}

return version\register AssParser
