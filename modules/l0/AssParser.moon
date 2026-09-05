DependencyControl = require "l0.DependencyControl"
constants = require "l0.DependencyControl.Constants"
AegisubSubtitles = require "l0.AssParser.AegisubSubtitles"
Ass = require "l0.AssParser.ass"
AssScript = require "l0.AssParser.AssScript"
Karaoke = require "l0.AssParser.karaoke"
Scanner = require "l0.AssParser.Scanner"
AssRunState = require "l0.AssParser.RunState"
Arguments = require "l0.AssParser.arguments"
Diagnostics = require "l0.AssParser.diagnostics"
Dialects = require "l0.AssParser.dialects"
Drawing = require "l0.AssParser.drawing"
Emitter = require "l0.AssParser.emitter"
LineState = require "l0.AssParser.LineState"
Normalizer = require "l0.AssParser.normalizer"

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
---@class AssParser
---@field version DependencyControlRecord This module's version record.
AssParser = {
  :version
  :Ass
  :AssScript
  :AegisubSubtitles
  :Arguments
  :Diagnostics
  :Dialects
  :Drawing
  :Emitter
  :Karaoke
  :LineState
  :Normalizer
  :Scanner
  RunState: AssRunState
}

return version\register AssParser
