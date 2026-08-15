-- Drawings are read and written here as text and never as geometry: a coordinate stays the number it
-- was written as, and no two are ever paired into a point. Naming a drawing's defects and removing
-- what no renderer reads need nothing more than that, so anything that has to know where the shape
-- actually goes builds it above this file.
--
-- A malformed drawing is where the renderers part. Besides xy-VSFilter, the VSFilter line is read by
-- the build Aegisub bundled until it defaulted to xy-VSFilter in January 2013, and by the internal
-- subtitle renderers of MPC-HC (the original project and clsid's continuation) and MPC-BE.
--
-- Every reader of the VSFilter line agrees that:
--   * a character naming no command is passed over wherever it stands
--   * a command reaching for nodes it has not got is ignored rather than rejected, before the first
--     move as much as after it
--   * an open move reaching a point before any move throws the whole drawing away
--
-- They part on two points:
--   * curve points too few to finish a segment stay in the path for xy-VSFilter and are dropped by the
--     rest, which `canonicalizeDrawing` models
--   * command letters written against each other, as `ml`, are one command to MPC-HC, whose scan
--     consumes a run of them, and two to every other reader, which finds no node for the second and
--     ignores it. So `ml 0 0 …` opens a contour at the origin there and draws nothing anywhere else.
--     Nothing here models this, since no corpus drawing writes one among its commands.

{:emitNumber} = require "l0.AssParser.arguments"
{:DialectName, :DrawingCommandName, :drawingCommands} = require "l0.AssParser.dialects"

---One command of a drawing, with the coordinates written after it.
---@class AssDrawingCommand
---@field name? AssDrawingCommandName The command letter as the drawing wrote it, absent where a
---  drawing opens with coordinates before naming any command.
---@field coordinates number[] The numbers read for it: those written before the first word holding no
---  number, since every renderer stops reading a run there.
---@field junk? string[] Runs of characters naming no command, in the order written, read by no renderer.


-- Longest first, so a number with a decimal point is not cut short
numberPrefixes = {"^[-+]?%d+%.%d+", "^[-+]?%.%d+", "^[-+]?%d+%.?"}

---Reads as much of the text as forms a number, so a coordinate written against the text behind it
---still reads as a coordinate (e.g. `0With` is read as `0`).
---@param text string The drawing text from the position being read.
---@return string? numeral What was read, nil where no number starts here.
readNumberPrefix = (text) ->
  for pattern in *numberPrefixes
    numeral = text\match pattern
    return numeral if numeral and tonumber numeral
  return nil

---Splits a drawing into its commands and their coordinates, scanning character by character as every
---renderer does. A character naming a command opens one wherever it stands, and one naming nothing is
---passed over without consuming what follows it, so `}m 0 0` opens a move at the origin exactly as
---`m 0 0` does. Junk standing *between* a command and its numbers is a different matter: it ends the
---run, and the numbers behind it reach no command at all.
---
---The result is read-only, as a tag's `arguments` are. A drawing is emitted from its `text`, so to
---commit an edit, write the commands back with `emitDrawing` and assign the result to that.
---@param text string A drawing token's characters.
---@return AssDrawingCommand[] commands In the order written, empty for a drawing holding no word.
readDrawing = (text) ->
  commands, current = {}, nil
  open = (name) ->
    current = {:name, coordinates: {}}
    commands[#commands + 1] = current

  addJunk = (piece) ->
    open! unless current
    current.junk or= {}
    current.junk[#current.junk + 1] = piece

  for word in text\gmatch "%S+"
    index, straysHere = 1, nil
    while index <= #word
      numeral = readNumberPrefix word\sub index
      if numeral
        addJunk straysHere if straysHere
        straysHere = nil
        open! unless current
        if current.junk
          addJunk numeral
        else
          current.coordinates[#current.coordinates + 1] = tonumber numeral
        index += #numeral
        continue

      letter = word\sub index, index
      if drawingCommands[letter]
        addJunk straysHere if straysHere
        straysHere = nil
        open letter
      else
        straysHere = (straysHere or "") .. letter
      index += 1

    addJunk straysHere if straysHere

  return commands

---Converts parsed drawing commands back into their textual representation.
---Whitespace the source held between the numbers is not recorded, so this normalizes it to a single space.
---To keep an unmodified drawing byte for byte, emit the raw `text` it was read from, instead.
---@param commands AssDrawingCommand[] The commands to write, as `readDrawing` returns them.
---@return string text The drawing, as a token's `text`.
emitDrawing = (commands) ->
  words = {}
  for command in *commands
    words[#words + 1] = command.name if command.name
    words[#words + 1] = emitNumber coordinate for coordinate in *command.coordinates
    words[#words + 1] = piece for piece in *command.junk or {}
  return table.concat words, " "

---Counts the coordinates left over once every segment a command can draw is drawn.
---
---Most commands take the same number of coordinates for every segment: two for a line, six for a cubic
---curve, and the same again for each further one. A spline is the exception. It takes six coordinates
---to draw at all, and two for each point after that.
---@param count integer Coordinates written for the command.
---@param arity AssDrawingCommandArity What the command needs, from the tag tables.
---@return integer leftover Zero where every coordinate belongs to a segment, and `count` itself where
---  there are too few to draw anything.
countLeftoverCoordinates = (count, arity) ->
  return count if count < arity.opens
  (count - arity.opens) % arity.repeats

---Whether the drawing ever reaches a starting point, without which no part of it is drawn.
---@param commands AssDrawingCommand[] A drawing's parsed commands.
---@param dialect? AssDialectName Whose reading to apply.
---@return boolean opens False for a drawing the dialect (or, if omitted, any dialect) draws no part of.
drawingOpensUnder = (commands, dialect) ->
  moveSeen = false
  for command in *commands
    continue unless command.name
    moveSeen = true if command.name == DrawingCommandName.Move
    continue unless #command.coordinates >= 2
    return true if command.name == DrawingCommandName.Move

    if command.name == DrawingCommandName.OpenMove
      -- An open move reaching a point before any move is written (e.g. `n 0 0 l 100 0 100 100`) makes
      -- every renderer throw the whole drawing away, each in its own place: libass at the `n`, which it
      -- accepts as a root only after an `m` has been seen, and the VSFilter line and MPC once an `m` is
      -- reached with points already added.
      return false unless moveSeen

      -- After a move that reached no point (e.g. `m n 0 0 l 100 0 100 100`), libass lets the next open
      -- move stand in as the root where VSFilter draws nothing at all. With no reference dialect specified,
      -- this indicates whether any of them renders the drawing or the drawing may be removed outright.
      return true if dialect == DialectName.Libass or dialect == nil
  return false

---Strips everything from a drawing that changes nothing about how it renders, and rewrites the
---degenerate commands that do change something into ordinary ones that change it the same way.
---
---Given a reference dialect, the result renders identically to the original in that dialect, and
---identically *between* dialects. In the others it may differ from the original, since only one
---reading of a degenerate command can be kept.
---
---Without a reference dialect, changes are limited to those that render identically to the original in
---every dialect, so a degenerate command they disagree over stays as written and they go on
---disagreeing over it.
---
---The following parts are removed:
--- * a word that holds no number, and everything after it up to the next command
--- * a command left with no coordinates
--- * a spline extension with fewer than three nodes before it
--- * a single leftover coordinate at the end
--- * curve points too few to complete a group of three. libass discards them; VSFilter keeps them in
---   the path, where they widen the drawing without being drawn. Under VSFilter they are therefore
---   written as a contour of no area, which widens it the same way in every dialect. Given no dialect
---   they stay as written, since removing them would move libass's picture and writing them as a
---   contour would move VSFilter's.
---@param commands AssDrawingCommand[] A drawing's parsed commands.
---@param dialect? AssDialectName Whose reading to apply. Without one, only what every dialect
---  ignores is removed.
---@return string canonical The drawing with those parts removed, one space between words. Empty for a
---  drawing the dialect draws no part of.
---@return boolean reduced False where nothing was removed, so the drawing already reads as it draws
---  and needs no rewriting.
canonicalizeDrawing = (commands, dialect) ->
  return "", #commands > 0 unless drawingOpensUnder commands, dialect

  kept, reduced, nodes = {}, false, 0
  -- Where libass opened the drawing at an open move VSFilter would not, its reading is written with an
  -- ordinary move there and the move that reached no point goes with it. Nothing precedes the first
  -- contour for the two kinds of move to differ over, so libass draws the same picture and VSFilter
  -- now draws it too.
  promotesTheRoot = dialect == DialectName.Libass and drawingOpensUnder(commands, DialectName.Libass) and
    not drawingOpensUnder commands, DialectName.XyVsfilter
  rootPending = promotesTheRoot

  holdsAnOpenMove = false
  holdsAnOpenMove = true for command in *commands when command.name == DrawingCommandName.OpenMove

  widening = nil
  for command in *commands
    {:name, :coordinates} = command
    reduced = true if command.junk

    unless name
      reduced = true if #coordinates > 0
      continue

    arity = drawingCommands[name].arity
    if nodes < arity.needsNodes
      -- a command reaching back for nodes that are not there is read by no renderer
      reduced = true
      continue

    used = coordinates
    if arity.opens > 0 and #coordinates < arity.opens and arity.dropsPartialOpening
      -- too few coordinates to open the command, and every renderer discards those alike
      used = {}
      reduced = true
    elseif arity.opens > 0
      leftover, dropFrom = countLeftoverCoordinates(#coordinates, arity), nil
      if leftover == 1
        -- a lone coordinate makes no point to draw to
        dropFrom = #coordinates - 1
      elseif leftover > 1 and dialect
        -- dropped from the drawing under either reading, and held for the widening contour under VSFilter
        dropFrom = #coordinates - leftover
        if dialect == DialectName.XyVsfilter
          widening = [coordinates[index] for index = dropFrom + 1, #coordinates]
      if dropFrom
        used = [coordinates[index] for index = 1, dropFrom]
        reduced = true

    -- A command left with no coordinates draws nothing and is dropped, except an empty `m` a later open
    -- move still needs: in `m junk n 0 0 l 100 0` libass takes the `n` as the drawing's starting point
    -- only because an `m` came first, so dropping that `m` would leave libass drawing nothing at all.
    -- It stops being needed once `promotesTheRoot` has turned that `n 0 0` into an `m 0 0` starting the
    -- drawing on its own. An open move is never the predecessor another one needs, so an empty one of
    -- those goes whatever else the drawing holds.
    -- The promotion only happens for libass. VSFilter draws no part of such a drawing whatever is done
    -- to it, its first path element being an open move and an unclosed contour having no fill.
    opensADrawing = not promotesTheRoot and holdsAnOpenMove and name == DrawingCommandName.Move
    if #used == 0 and arity.opens > 0 and not opensADrawing
      reduced = true
    else
      written = name
      if rootPending and name == DrawingCommandName.OpenMove and #used >= 2
        written, reduced, rootPending = DrawingCommandName.Move, true, false

      nodes += math.floor #used / 2
      kept[#kept + 1] = {name: written, coordinates: used}

    if widening
      -- move onto the first of them, draw through the rest and close back onto it
      kept[#kept + 1] = {name: DrawingCommandName.Move, coordinates: {widening[1], widening[2]}}
      for index = 3, #widening, 2
        kept[#kept + 1] = {
          name: DrawingCommandName.Line
          coordinates: {widening[index], widening[index + 1]}
        }
      kept[#kept + 1] = {name: DrawingCommandName.Line, coordinates: {widening[1], widening[2]}}
      widening = nil

  return emitDrawing(kept), reduced

---A parser, emitter and normalizer for ASS drawing commands.
---@class AssDrawing
return {:readDrawing, :emitDrawing, :canonicalizeDrawing, :drawingOpensUnder, :countLeftoverCoordinates}
