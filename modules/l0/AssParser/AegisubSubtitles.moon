-- A well-formed file is already in Aegisub's group order, so an index into this object is an index into
-- `script.lines`. Only a file with interleaved sections needs the permutation `getGroupOrder` returns,
-- which has to be recomputed after every edit.
--
-- The instance table must stay empty. Aegisub's object throws on any unknown key, but a field set on the
-- table would be returned instead, so all state lives in the closures the metatable uses.

Ass = require "l0.AssParser.ass"

msgs = {
  new: {
    notAScript: "Expected an AssScript, got a %s."
  }
  object: {
    readOnly: "This subtitles object is read-only."
    badIndex: "Invalid indexing in Subtitle File object: '%s'."
    badIndexType: "Attempt to index a Subtitle File object with value of type '%s'."
    outOfRange: "Out of range line index: %s."
  }
}

-- Aegisub's defaults, taken from Gabest's VSFilter: 384x288 for a script setting neither dimension.
-- A missing dimension is otherwise derived at 4:3, except that 1280 and 1024 pair with each other.
FALLBACK_WIDTH, FALLBACK_HEIGHT = 384, 288
ODD_WIDTH, ODD_HEIGHT = 1280, 1024

---Aegisub's subtitle file interface over an `AssScript`, as a macro receives it. Lines are indexed from
---1 in Aegisub's group order: info lines, then styles, then dialogue lines. Each read returns a copy of
---the line, so as in Aegisub, a change takes effect only once the copy is assigned back with
---`subtitles[i] = line`.
---@class AegisubSubtitles
---@field n integer The number of lines, the same as `#subtitles`.
---@field append fun(...: AegisubLine) Adds each line after the last line of its class.
---@field insert fun(before: integer, ...: AegisubLine) Inserts the lines before the given index, in order.
---@field delete fun(...: integer|integer[]) Removes the lines at the given indices, passed as arguments
---  or as one table. Throws on an index out of range.
---@field deleterange fun(first: integer, last: integer) Removes the lines from `first` to `last`, both
---  included. Indices out of range are clamped.
---@field script_resolution fun(): integer, integer Returns the script's `PlayResX` and `PlayResY`,
---  filling in a missing dimension the way Aegisub does.
class AegisubSubtitles
  ---@param script AssScript The script to wrap. Every edit is applied to it.
  ---@param options? {readOnly?: boolean} `readOnly` makes every edit throw, as for the object Aegisub
  ---  passes to a macro's validation function.
  new: (script, options = {}) =>
    error msgs.new.notAScript\format(type script), 2 unless "table" == type(script) and script.lines
    {:readOnly} = options

    order = script\getGroupOrder!
    lines = script.lines

    lineIndexOf = (viewIndex) -> order and order[viewIndex] or viewIndex
    refresh = -> order = script\getGroupOrder!

    checkModify = -> error msgs.object.readOnly, 3 if readOnly
    checkBounds = (index) ->
      inRange = "number" == type(index) and index >= 1 and index <= #lines
      error msgs.object.outOfRange\format(tostring index), 3 unless inRange

    readAt = (viewIndex) ->
      at = lineIndexOf viewIndex
      line = {key, value for key, value in pairs lines[at]}
      line.section = Ass.sectionByClass[line.class]
      line.raw = script\serializeLineAt at
      line

    appendLines = (...) ->
      checkModify!
      script\addLine (select index, ...) for index = 1, select "#", ...
      refresh!

    insertLines = (before, ...) ->
      checkModify!
      inRange = "number" == type(before) and before >= 1 and before <= #lines + 1
      error msgs.object.outOfRange\format(tostring before), 3 unless inRange
      return appendLines ... if before == #lines + 1
      at = lineIndexOf before
      for index = 1, select "#", ...
        script\insertLineBefore at, (select index, ...)
        at += 1
      refresh!

    ---Removes the lines at the given indices. Lines are removed from the highest index down, so that no
    ---removal shifts a line that is still to be removed.
    ---@param viewIndices integer[] Indices into this object, in any order.
    removeAll = (viewIndices) ->
      checkBounds index for index in *viewIndices
      lineIndices = [lineIndexOf index for index in *viewIndices]
      table.sort lineIndices, (a, b) -> a > b
      script\removeLineAt at for at in *lineIndices
      refresh!

    deleteLines = (...) ->
      checkModify!
      return if select("#", ...) == 0
      first = select 1, ...
      removeAll "table" == type(first) and first or {...}

    deleteRange = (first, last) ->
      checkModify!
      first = math.max 1, "number" == type(first) and first or 1
      last = math.min #lines, "number" == type(last) and last or 0
      return if first > last
      removeAll [index for index = first, last]

    scriptResolution = ->
      width, height = 0, 0
      for line in *lines
        continue unless line.class == Ass.LineClass.Info
        width = math.floor(tonumber(line.value) or 0) if line.key == "PlayResX"
        height = math.floor(tonumber(line.value) or 0) if line.key == "PlayResY"
      return FALLBACK_WIDTH, FALLBACK_HEIGHT if width == 0 and height == 0
      return (height == ODD_HEIGHT and ODD_WIDTH or math.floor height * 4 / 3), height if width == 0
      return width, (width == ODD_WIDTH and ODD_HEIGHT or math.floor width * 3 / 4) if height == 0
      width, height

    named = {
      append: appendLines
      insert: insertLines
      delete: deleteLines
      deleterange: deleteRange
      script_resolution: scriptResolution
    }

    setmetatable @, {
      __len: -> #lines

      __ipairs: ->
        step = (_, index) ->
          return nil if index >= #lines
          index + 1, readAt index + 1
        step, nil, 0

      __index: (_, key) ->
        if "number" == type key
          checkBounds key
          return readAt key
        error msgs.object.badIndexType\format(type key), 2 unless "string" == type key
        return #lines if key == "n"
        held = named[key]
        error msgs.object.badIndex\format(key), 2 unless held
        held

      __newindex: (_, key, value) ->
        checkModify!
        error msgs.object.badIndexType\format(type key), 2 unless "number" == type key
        return insertLines -key, value if key < 0
        return appendLines value if key == 0
        return deleteLines key if value == nil
        checkBounds key
        script\replaceLineAt lineIndexOf(key), value
        refresh!
    }

return AegisubSubtitles
