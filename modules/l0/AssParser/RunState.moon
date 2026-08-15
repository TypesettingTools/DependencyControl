bit = require "bit"
{:BorderStyle, :FontWeight, :parseColor, :splitStyleColor} = require "l0.AssParser.ass"
tagArguments = require "l0.AssParser.arguments"
{:DialectName, :TagName, :overrideTags, :ArgumentType, :RunField, :dialects, :getArgumentReading,
  :getFieldConversion, :TransformBehavior} = require "l0.AssParser.dialects"
utils = require "l0.DependencyControl.utils"

-- A transform with a zero or unset end time animates across the whole line duration, which this stands
-- in for when the caller provides none.
DEFAULT_EVENT_DURATION = 10000

-- Read once per tag applied, which is often enough that a set beats reaching through the definition.
isInterpolatedTagName = {}
for name, definition in pairs overrideTags
  isInterpolatedTagName[name] = true if definition.transform == TransformBehavior.Interpolated

msgs = {
  new: {
    unknownDialect: "No such dialect '%s'."
    comparesNoRuns: "Dialect '%s' compares no runs of text."
  }
}

-- What both renderers hold to zero as they read a style line, before a single tag is applied, so a
-- style declaring a negative scale or width begins at zero rather than at what it wrote. This is the
-- style parser's doing rather than any tag's, which is why it is neither a reading nor a dialect
-- trait: `\xshad` keeps a negative where `\shad` clamps one, but the style's own Shadow is clamped
-- for both. Aegisub clamps none of it and compares nothing, so nothing here reaches it.
clampedStyleFields = {
  RunField.ScaleX, RunField.ScaleY, RunField.Spacing
  RunField.BorderX, RunField.BorderY, RunField.ShadowX, RunField.ShadowY
}

---Which run fields each dialect doesn't track; to be omitted from the run state.
---Empty for a dialect comparing no runs.
---@type table<AssDialectName, table<string, true>>
ignoredFieldsByDialect = {}
for dialectName in *DialectName.values
  ignored = {}
  comparison = dialects[dialectName].runComparison
  ignored[RunField.CharSet] = true if comparison and not comparison.comparesCharacterSet
  ignoredFieldsByDialect[dialectName] = ignored

---The style values a line begins under, in the fields the renderers compare. Color and alpha are
---held apart because a style packs them into one field while `\1c` and `\1a` write one each, and the
---four switches are held as the numbers their tags write rather than as booleans.
---@param style AegisubStyleLine The style the line is set in.
---@param dialect AssDialectName Whose conversion to apply to each field, since a seeded value is compared
---  against what a tag writes into the same field and the two have to be held alike.
---@return table<string, any> values The value each compared field starts at; fields this dialect doesn't track excluded
seedStateFrom = (style, dialect) ->
  values = {
    [RunField.FontName]: style.fontname
    [RunField.FontSize]: style.fontsize
    [RunField.CharSet]: style.encoding
    [RunField.ScaleX]: style.scale_x
    [RunField.ScaleY]: style.scale_y
    [RunField.Spacing]: style.spacing
    [RunField.BorderStyle]: style.borderstyle
    [RunField.Bold]: style.bold and 1 or 0
    [RunField.Italic]: style.italic and 1 or 0
    [RunField.Underline]: style.underline and 1 or 0
    [RunField.StrikeOut]: style.strikeout and 1 or 0
    [RunField.BorderX]: style.outline
    [RunField.BorderY]: style.outline
    [RunField.ShadowX]: style.shadow
    [RunField.ShadowY]: style.shadow
    [RunField.RotateZ]: style.angle
    -- no style declares these, and both renderers put a bare tag back to zero
    [RunField.Blur]: 0
    [RunField.BlurEdges]: 0
    [RunField.RotateX]: 0
    [RunField.RotateY]: 0
    [RunField.ShearX]: 0
    [RunField.ShearY]: 0
  }

  -- a style packs the alpha into the top byte of the color it declares, which `\1a` writes alone
  colorFields = {RunField.Color1, RunField.Color2, RunField.Color3, RunField.Color4}
  alphaFields = {RunField.Alpha1, RunField.Alpha2, RunField.Alpha3, RunField.Alpha4}
  for index = 1, 4
    values[colorFields[index]], values[alphaFields[index]] = splitStyleColor parseColor style["color#{index}"] or ""

  values[field] = math.max 0, values[field] for field in *clampedStyleFields

  -- One dialect keeps only the opaque box apart from everything else, which is reachable through a
  -- `\r` between two styles and through nothing else, since no tag writes the field.
  if dialects[dialect].runComparison.foldsBorderStyle
    box = values[RunField.BorderStyle] == BorderStyle.OpaqueBox
    values[RunField.BorderStyle] = box and BorderStyle.OpaqueBox or BorderStyle.Outline

  -- Assigning to a key already present is defined during a `pairs` walk, and nothing new is added.
  for field, value in pairs values
    conversion = getFieldConversion dialect, field
    values[field] = tagArguments.applyDialectSpecificReading value, {:conversion} if conversion

  values[field] = nil for field in pairs ignoredFieldsByDialect[dialect]
  return values

---A font weight as commonly referred to in `\b` tags.
---`\b1` and `\b700` pick the same face and both come back as 1;
---`\b0` and `\b400` do the same for 0.
---@param value number A weight or a flag, as the dialect in hand holds it.
---@return number value 0 for regular, 1 for bold, or the weight itself where it names neither.
toCanonicalFontWeight = (value) ->
  switch value
    when FontWeight.Normal then 0
    when FontWeight.Bold then 1
    else value

---A pair of transform functions to convert between one dialect's representation and the canonical one.
---@class AssCanonicalMapping
---@field to? fun(value: any): any A value this dialect holds, in the canonical representation.
---@field from? fun(value: any): any A value in the canonical representation, as this dialect holds it. Each
---  is absent where the dialect already stores the canonical representation as it stands.

-- The conversions each dialect needs. They convert between values that name the same visual effect and
-- are not there to paper over a genuine difference in what is drawn, such as libass rounding `\be0.6`
-- to `\be1` where VSFilter draws the fraction.
canonicalValueMapperByDialectAndRunField = {
  [DialectName.Libass]: {
    [RunField.Bold]: {to: toCanonicalFontWeight}

    -- libass draws the opaque box and its own shadow box each its own way and everything else as an
    -- outline, so a value the format gives no meaning to comes back as the outline
    [RunField.BorderStyle]: {
      to: (value) ->
        return value if value == BorderStyle.OpaqueBox or value == BorderStyle.ShadowBox
        return BorderStyle.Outline
    }
  }

  [DialectName.XyVsfilter]: {
    -- VSFilter represents all font weights by the GDI `LOGFONT.lfWeight` values which also align
    -- with the OpenType `OS/2.usWeightClass` values.
    [RunField.Bold]: {
      to: toCanonicalFontWeight
      from: (value) ->
        switch value
          when 0 then FontWeight.Normal
          when 1 then FontWeight.Bold
          else value
    }

    -- No `to` converter is required, because the internal state can only ever be OpaqueBox or Outline.
    -- No tag writes it, values declared in the style are folded by the seed, and user-set values
    -- are folded by the `from` converter below.
    [RunField.BorderStyle]: {
      from: (value) -> value == BorderStyle.OpaqueBox and value or BorderStyle.Outline
    }
  }
}

colorFields = utils.makeSet {RunField.Color1, RunField.Color2, RunField.Color3, RunField.Color4}

---Blends two packed colors a channel at a time, which is how both renderers animate one. Blending the
---packed numbers instead would carry each channel's fraction into the channel above it.
---@param held integer The color in force.
---@param target integer The color being animated towards.
---@param power number How far along the interval stands, 0 through 1.
---@return integer color The blended color, each channel truncated as libass's `dtoi32` truncates, so a
---  channel landing halfway between 0 and 255 comes back 127 rather than 128.
blendChannels = (held, target, power) ->
  blended = 0
  for shift = 0, 16, 8
    channelHeld = bit.band bit.rshift(held, shift), 0xFF
    channelTarget = bit.band bit.rshift(target, shift), 0xFF
    channel = math.floor channelHeld * (1 - power) + channelTarget * power
    blended = bit.bor blended, bit.lshift channel, shift
  blended

---The appearance in force at a point in a line, as the renderers track it to decide where a run of
---text ends. Seeded from the line's style, moved by each tag applied to it.
---@class AssRunState
---@field eventDuration integer How long the line is on screen, which a transform with a zero or unset
---  end time animates across. `DEFAULT_EVENT_DURATION` where the duration was not given.
---@field time? integer Where in the duration of a line to read the state, in milliseconds from the line's start.
---  Absent leaves every transform applied at its targets, which answers for any frame past a transform's start.
---@field dialect AssDialect The dialect whose comparison this applies. Read-only.
---@field comparison AssRunComparison Which fields that dialect compares to decide where a run ends. Read-only.
---@field values table<string, any> What each compared field currently holds, in this dialect's own
---  representation. Use `getValue` to read the fields in the canonical representation.
---@field seeded table<string, any> What the style declared, which a tag written bare puts back.
---@field __ignored table<string, true> The fields this dialect leaves out of the comparison. Read-only.
---@field __lineSeeded table<string, any> The state seeded from the line's declared style.
---@private __ignored
---@private __lineSeeded
class AssRunState
  ---What `eventDuration` starts at where a caller states none.
  ---@type integer
  @DEFAULT_EVENT_DURATION = DEFAULT_EVENT_DURATION

  ---@param style AegisubStyleLine The style the line is set in.
  ---@param dialect string|AssDialect A dialect name, or a dialect table to compare with directly.
  ---@param stylesByName? table<string, AegisubStyleLine> Every style the script declares, which `\r` reaches by name.
  ---@param eventDuration? integer How long the line is on screen, `DEFAULT_EVENT_DURATION` by default.
  new: (@style, dialect, @stylesByName, @eventDuration = DEFAULT_EVENT_DURATION) =>
    -- a name that matches nothing has to fall through to the assert, which an `and`/`or` chain would
    -- defeat by handing back the name itself
    @dialect = if type(dialect) == "string" then dialects[dialect] else dialect
    assert @dialect, msgs.new.unknownDialect\format tostring(dialect)

    @comparison = @dialect.runComparison
    assert @comparison, msgs.new.comparesNoRuns\format tostring(@dialect.name)


    @__ignored = ignoredFieldsByDialect[@dialect.name]
    @__lineSeeded = seedStateFrom @style, @dialect.name
    @reset!

  ---Puts every field back to what a style declares, which is what `\r` does.
  ---@param styleName? string The style to reset to, the line's own where absent or unknown.
  reset: (styleName) =>
    style = styleName and @stylesByName and @stylesByName[styleName]
    inForce = seedStateFrom(style or @style, @dialect.name)
    @seeded = @dialect.restoresTheStyleInForce and inForce or @__lineSeeded
    @values = utils.copy inForce

  ---Calculates the interpolation factor a transform stands at, read against the time this state was given.
  ---@private
  ---@param token AssToken A `\t` token.
  ---@return number power 0 before the interval opens through 1 once it has closed, and 1 throughout where
  ---  this state was given no time, which leaves every transform applied at its targets.
  __getTransformPower: (token) =>
    return 1 unless @time
    args = token.arguments or {}
    startTime, endTime, acceleration = 0, 0, 1
    switch #args - 1
      when 3 then startTime, endTime, acceleration = args[1], args[2], args[3]
      when 2 then startTime, endTime = args[1], args[2]
      when 1 then acceleration = args[1]

    -- Event duration is used for a zero or unset end time (i.e. `\t(tags)`, `\t(accel, tags)`, `\t`).
    endTime = @eventDuration if endTime == 0

    return 0 if @time < startTime
    return 1 if @time >= endTime
    return ((@time - startTime) / (endTime - startTime)) ^ acceleration

  ---Commits one override tag to this state, reporting whether it moved anything a renderer compares.
  ---A tag that writes the value already in force moves nothing, keeping any karaoke syllable open across it.
  ---A `\t` applies the tags it holds, at the values they animate towards.
  ---@param token AssToken The tag to apply.
  ---@param power? number How far a transform holding it stands through its interval, 1 by default so a
  ---  tag written outside one applies in full.
  ---@return boolean moved Whether any compared field now differs from what it held.
  applyTag: (token, power = 1) =>
    definition = overrideTags[token.name]
    return false unless definition

    -- every tag naming a field takes exactly one argument, so the first signature holds its type
    argument = definition.signatures[1][1]

    if argument == ArgumentType.StyleName
      before = utils.copy @values
      @reset token.arguments and token.arguments[1] or nil
      for field, value in pairs @values
        return true unless before[field] == value
      return false

    if argument == ArgumentType.Tags
      moved = false
      held = @__getTransformPower token
      for child in *token.children or {}
        -- A transform inside a transform replaces the interval it sits in for everything after it rather
        -- than composing with it, which both renderers were observed doing, so the inner one's factor
        -- governs its own tags and the rest of the list holding it alike.
        held = @__getTransformPower child if child.name == TagName.Transform
        moved = @applyTag(child, held) or moved
      return moved

    return false unless definition.runFields

    isBareTag = #token.params == 0

    moved = false
    for field in *definition.runFields
      continue if @__ignored[field]

      reading = getArgumentReading @dialect.name, token.name
      seeded = @seeded[field]
      value = seeded
      unless isBareTag
        value = tagArguments.sanitizeArgument argument, token.arguments[1]
        value = seeded if value == nil

        -- A hex value without digits (e.g. `\c&&`) is typed as zero, so we need to check the raw params
        value = seeded if reading.refusesLiteralWithoutDigits and not token.params\match "%x"

        -- the one argument that does anything but replace, scaling the size in force by a tenth of
        -- what it names, so `\fs+10` doubles it
        if token.sizeIsRelative
          value = @values[field] * (1 + token.arguments[1] / 10)

      -- A tag the transform interpolates lands part way to its target; one it does not is applied whole
      -- from the first frame, interval or no interval, so it reaches here unchanged.
      if power < 1 and isInterpolatedTagName[token.name] and "number" == type(value) and
          "number" == type @values[field]
        value = colorFields[field] and blendChannels(@values[field], value, power) or
          @values[field] * (1 - power) + value * power

      -- Both renderers defer rounding and clamping to after transform interpolation: a size animating toward
      -- a refused zero draws every step of the way down and puts the style's back only once the transform ends,
      -- and a border animating toward a negative one is floored where it arrives rather than before it sets off.
      value = tagArguments.applyDialectSpecificReading value, reading
      value = seeded if reading.requiresPositive and "number" == type(value) and value <= 0

      unless @values[field] == value
        @values[field] = value
        moved = true

    return moved

  ---A style field's current value in the canonical representation, where a dialect may hold any of
  ---several values that refer to the same visual effect. A weight comes back as 0 for regular, whether
  ---the dialect holds 0 or 400, and as 1 for bold, whether it holds 1 or 700. A border style comes back
  ---as the value naming what is drawn, so the 2 the format leaves meaningless comes back as `Outline`.
  ---
  ---Two dialects' snapshots of one line are comparable through this and not through `values`, which
  ---holds the representation each dialect uses to decide where a run of text ends.
  ---@param field AssRunField The field to read.
  ---@return any? value Nil where this dialect leaves the field out of its comparison, as libass does
  ---  with the character set.
  getValue: (field) =>
    value = @values[field]
    return nil if value == nil
    mapper = @__getCanonicalValueMapper field
    return value unless mapper and mapper.to
    return mapper.to value

  ---Sets a style field from a value in the canonical representation, converting to whatever this
  ---dialect holds it as, so a weight of 1 becomes 1 for libass and 700 for VSFilter.
  ---
  ---Where a dialect has no value for the effect asked for, the field takes what that dialect draws
  ---instead: VSFilter draws libass's shadow box as an outline, so it stores the outline. Reading the
  ---field back therefore reports the effect in force, which is not always the value written.
  ---@param field AssRunField The field to write.
  ---@param value any The value, in the canonical representation.
  ---@return boolean moved Whether the field now differs from what it held, so whether a run of text
  ---  ends here. False for a field this dialect's run state doesn't track.
  ---@return any? held The effect now in force, in the canonical representation. Nil for a field this
  ---  dialect's run state doesn't track.
  setValue: (field, value) =>
    return false, nil if @__ignored[field]

    -- A read folds several of a dialect's values onto one, and writing that one back would pick a
    -- representative and discard whichever was in force. libass reads border styles 1 and 2 alike and
    -- compares them apart, so replacing its 2 with a 1 would lose a run boundary `\r` really produces.
    reads = @getValue field
    return false, reads if reads == value

    written = value
    mapping = @__getCanonicalValueMapper field
    written = mapping.from value if mapping and mapping.from

    moved = @values[field] != written
    @values[field] = written
    moved, @getValue field

  ---@private
  ---@param field AssRunField The compared field.
  ---@return AssCanonicalMapping? mapping Nil where this dialect already holds the canonical representation.
  __getCanonicalValueMapper: (field) =>
    byField = canonicalValueMapperByDialectAndRunField[@dialect.name]
    byField and byField[field]

return AssRunState
