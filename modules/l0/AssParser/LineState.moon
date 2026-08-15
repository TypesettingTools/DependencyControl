Ass = require "l0.AssParser.ass"
{:LineClass} = Ass
{:TagName, :TokenKind, :overrideTags} = require "l0.AssParser.dialects"

---Appearance attributes in force for the line as a whole rather than per run of text.
---Filled from the same token stream as `AssRunState`, independently of it.
---
---Most attributes take their value from the *first* tag that writes them, leaving a later one dead,
---while `\q` and a rectangular `\clip` take the last value written. A tag whose arguments match none
---of its signatures reads as nothing at all, settling neither the attribute it writes nor its slot,
---so a tag after it still counts.
---@class AssLineState
---@field position? {x: number, y: number} Where `\pos` put the line, absent where none took effect.
---@field move? {x1: number, y1: number, x2: number, y2: number, startTime: integer, endTime: integer}
---  What `\move` states, its times both 0 where it named none and the whole line is meant.
---@field alignment? integer Keypad alignment 1 through 9, converted where a legacy `\a` set it. Absent
---  where the style's own stands, which is what an argument outside either tag's range leaves. Such a
---  tag settles the slot regardless, as does either written bare, so `\an7` is dead after a `\a99` and
---  after a bare `\a` alike.
---@field origin? {x: number, y: number} The point rotation turns about.
---@field fade? {startAlpha: integer, midAlpha: integer, endAlpha: integer, fadeInStart: integer, fadeInEnd: integer, fadeOutStart: integer, fadeOutEnd: integer}
---  A fade in the seven-argument form, which the two-argument `\fad` is widened into.
---@field wrapStyle? integer What the last `\q` states, absent where none did and the script's own stands.
---@field clip? {inverse: boolean, rectangle?: {x1: integer, y1: integer, x2: integer, y2: integer}, drawing?: string, scale?: integer}
---  A clip as a rectangle or as a path, never both. `inverse` tells `\iclip` from `\clip`.
---@field collisionsDisabled? true Set where a tag stops the line being moved aside to clear another. A
---  scroll in the Effect field does the same, which nothing in the line's text can show.
class AssLineState
  new: =>
    ---which tag claimed each first-wins slot, so a later one can be refused and the claimant named
    ---@private
    @__claimedBy = {}

  ---Applies an override tag, reporting whether the line took it. A tag of a kind read from the line's
  ---first instance is refused where one already stands, which is what names a dead tag in a warning;
  ---`\q` and a rectangular `\clip` are always taken, since the last of those stands.
  ---@param token AssToken The tag to apply.
  ---@return boolean applied False where an earlier tag already settled what this one writes.
  ---@return string? claimedBy The tag that settled it, where this one was refused. It is not always the
  ---  same tag: `\pos` and `\move` compete for one slot, as do `\fad` and `\fade`, and `\an` and `\a`.
  applyTag: (token) =>
    return true unless token.kind == TokenKind.Tag
    definition = overrideTags[token.name]
    return true unless definition

    -- A `\t` switches collision detection off whatever it holds. `\pos`, `\move` and `\org` do so only
    -- where their arguments matched a signature.
    @collisionsDisabled = true if definition.disablesCollisionDetection and
      (token.name == TagName.Transform or token.arguments)

    slot = definition.firstWinsSlot
    if slot and @__claimedBy[slot]
      return false, @__claimedBy[slot]

    arguments = token.arguments or {}
    switch token.name
      when TagName.Position
        @position = {x: arguments[1], y: arguments[2]} if #arguments == 2

      when TagName.Move
        if #arguments == 4 or #arguments == 6
          @move = {
            x1: arguments[1], y1: arguments[2], x2: arguments[3], y2: arguments[4]
            startTime: arguments[5] or 0, endTime: arguments[6] or 0
          }

      when TagName.Alignment
        @alignment = arguments[1] if arguments[1] and arguments[1] >= 1 and arguments[1] <= 9

      when TagName.LegacyAlignment
        @alignment = Ass.getKeypadAlignment(arguments[1], Ass.AlignmentSource.OverrideTag) or @alignment

      when TagName.RotationOrigin
        @origin = {x: arguments[1], y: arguments[2]} if #arguments == 2

      -- Both \fade and \fad may hold either shape, with the argument count deciding between simple and complex.
      when TagName.Fade, TagName.FadeComplex
        if #arguments == 2
          @fade = {
            startAlpha: 255, midAlpha: 0, endAlpha: 255
            fadeInStart: 0, fadeInEnd: arguments[1]
            fadeOutStart: arguments[2], fadeOutEnd: 0
          }
        elseif #arguments == 7
          @fade = {
            startAlpha: arguments[1], midAlpha: arguments[2], endAlpha: arguments[3]
            fadeInStart: arguments[4], fadeInEnd: arguments[5]
            fadeOutStart: arguments[6], fadeOutEnd: arguments[7]
          }

      when TagName.WrapStyle
        @wrapStyle = arguments[1] if arguments[1] and arguments[1] >= 0 and arguments[1] <= 3

      when TagName.Clip, TagName.InverseClip
        @__applyClip token, arguments

      else
        return true

    @__claimedBy[slot] = token.name if slot and token.arguments
    true

  ---Records a clip, whose two forms are settled differently: four numbers replace whatever stands, a
  ---path is kept only where none stands already.
  ---@private
  ---@param token AssToken The `\clip` or `\iclip`.
  ---@param arguments any[] Its parsed arguments.
  __applyClip: (token, arguments) =>
    inverse = token.name == TagName.InverseClip
    if #arguments == 4
      @clip = {:inverse, rectangle: {x1: arguments[1], y1: arguments[2], x2: arguments[3], y2: arguments[4]}}
      return

    return if @clip and @clip.drawing
    if #arguments == 2
      @clip = {:inverse, scale: arguments[1], drawing: arguments[2]}
    elseif #arguments == 1
      @clip = {:inverse, scale: 1, drawing: arguments[1]}

---Reads a line's line-level state from a scan of it.
---@param tokens AssToken[] The tokens a scan produced.
---@return AssLineState state What the line as a whole is drawn with.
readTokens = (tokens) ->
  state = AssLineState!
  -- whole-line tags may appear in transforms at any nesting level and work exactly as if they were
  -- written directly on the line.
  apply = (list) ->
    for token in *list
      state\applyTag token
      apply token.children if token.children
  apply tokens
  return state

return {:AssLineState, :readTokens}
