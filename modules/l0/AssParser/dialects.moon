-- cspell:ignore clipm -- a tag written against its argument, quoted verbatim below
Enum = require "l0.DependencyControl.Enum"

---@alias AssTokenKind string
---The token types produced by the parser when reading a line of ASS dialogue text.
---| "block-start" # BlockStart: the opening brace of an override block
---| "block-end" # BlockEnd: the closing brace of an override block
---| "tag" # Tag: one recognized override tag, with the raw text after its name
---| "junk" # Junk: block content that began with a backslash and matched no known name
---| "comment" # Comment: block content holding no backslash at all
---| "text" # Text: plain rendered text
---| "drawing" # Drawing: text consumed while drawing mode is on
TokenKind = Enum "AssTokenKind", {
  BlockStart: "block-start"
  BlockEnd: "block-end"
  Tag: "tag"
  Junk: "junk"
  Comment: "comment"
  Text: "text"
  Drawing: "drawing"
}

---@alias AssDialectName string
---The different implementation-specific interpretations of the loosely defined ASS format this library supports.
---| "aegisub" # Aegisub: what `aegisub.parse_karaoke_data` and the rest of the shims reproduce
---| "libass" # Libass: what renders for most viewers, and what Aegisub previews through
---| "vsfilter" # XyVsfilter: what xy-VSFilter renders, and the closest thing the format has to a reference.
---  While guliverkli VSFilter and MPC ISR mostly agree, there are (at least) some differences in how they handle degenerate drawings.
DialectName = Enum "AssDialectName", {
  Aegisub: "aegisub"
  Libass: "libass"
  XyVsfilter: "vsfilter"
}

---The punctuation ASS override syntax is written with.
---@class AssSyntax
Syntax = {
  BlockOpen: "{"
  BlockClose: "}"
  ArgumentListOpen: "("
  ArgumentListClose: ")"
  TagPrefix: "\\"
  EscapePrefix: "\\"
  ArgumentSeparator: ","
  NegativeRelativeSizeSign: "-"
  PositiveRelativeSizeSign: "+"
}

---@alias AssTagName string
---The names of the ASS override tags (without the leading backslash) supported among the dialects.
---| "1c" # PrimaryColor: the fill color
---| "2c" # SecondaryColor: the color a karaoke syllable holds until its sweep reaches it
---| "3c" # OutlineColor: the border color
---| "4c" # ShadowColor: the shadow color
---| "1a" # PrimaryAlpha: the fill's transparency
---| "2a" # SecondaryAlpha: the unsung karaoke color's transparency
---| "3a" # OutlineAlpha: the border's transparency
---| "4a" # ShadowAlpha: the shadow's transparency
---| "alpha" # Alpha: every transparency at once
---| "c" # Color: the fill color, spelled the short way
---| "an" # Alignment: where the line sits, numbered as a keypad
---| "a" # LegacyAlignment: the SSA numbering the format used before `\an`
---| "fn" # FontName: the face to set
---| "fs" # FontSize: the size to set, or a size relative to the one in force where its argument carries a sign
---| "fsc" # ScaleReset: returns both scale axes to the style's. Not known to Aegisub.
---| "fscx" # ScaleX: horizontal scale, as a percentage
---| "fscy" # ScaleY: vertical scale, as a percentage
---| "fsp" # FontSpacing: extra space between characters
---| "fe" # FontEncoding: the character set the face is read with
---| "b" # Bold: weight, as a flag or a numeric weight
---| "i" # Italic: slant
---| "u" # Underline
---| "s" # StrikeOut
---| "bord" # Border: outline width on both axes
---| "xbord" # BorderX: outline width across
---| "ybord" # BorderY: outline width down
---| "shad" # Shadow: shadow depth on both axes
---| "xshad" # ShadowX: shadow offset across
---| "yshad" # ShadowY: shadow offset down
---| "blur" # Blur: a gaussian blur over the edges
---| "be" # BlurEdges: the older box blur, counted in passes
---| "frx" # RotateX: rotation about the horizontal axis
---| "fry" # RotateY: rotation about the vertical axis
---| "frz" # RotateZ: rotation in the plane of the frame
---| "fr" # Rotate: rotation in the plane, spelled the short way
---| "fax" # ShearX: shear across
---| "fay" # ShearY: shear down
---| "pos" # Position: where to put the line
---| "move" # Move: a position that travels between two points
---| "org" # RotationOrigin: the point rotation turns about
---| "k" # Karaoke: a syllable that switches color when its time arrives
---| "kf" # KaraokeFill: a syllable whose color sweeps across it
---| "K" # KaraokeFillLegacy: `\kf` under its older spelling
---| "ko" # KaraokeOutline: a syllable whose outline switches
---| "kt" # KaraokeAbsolute: sets the karaoke clock outright. Not known to Aegisub.
---| "p" # Drawing: enters drawing mode, and sets the scale the coordinates are read at
---| "pbo" # DrawingBaselineOffset: shifts a drawing off the text baseline
---| "clip" # Clip: limits drawing to a rectangle or a shape
---| "iclip" # InverseClip: limits drawing to everything outside one
---| "t" # Transform: animates the tags in its own arguments
---| "r" # Reset: returns to a style, named or the line's own
---| "q" # WrapStyle: how the line breaks across lines
---| "fad" # Fade: a fade in and out, given two durations
---| "fade" # FadeComplex: a fade given its alphas and all four times
TagName = Enum "AssTagName", {
  PrimaryColor: "1c"
  SecondaryColor: "2c"
  OutlineColor: "3c"
  ShadowColor: "4c"
  PrimaryAlpha: "1a"
  SecondaryAlpha: "2a"
  OutlineAlpha: "3a"
  ShadowAlpha: "4a"
  Alpha: "alpha"
  Color: "c"

  Alignment: "an"
  LegacyAlignment: "a"

  FontName: "fn"
  -- Aegisub declares `\fs+` and `\fs-` ahead of `\fs`, reading `{\fs+5}` as `\fs+` with a parameter of
  -- '5' where the renderers read `\fs` with '+5'. All three compute the same relative size and no
  -- Aegisub API hands a tag list to a script, so neither name is declared here and every dialect reads
  -- the signed form. Aegisub's script resolution resampler scales an absolute font size and leaves a
  -- relative one alone.
  FontSize: "fs"
  ScaleReset: "fsc"
  ScaleX: "fscx"
  ScaleY: "fscy"
  FontSpacing: "fsp"
  FontEncoding: "fe"

  Bold: "b"
  Italic: "i"
  Underline: "u"
  StrikeOut: "s"

  Border: "bord"
  BorderX: "xbord"
  BorderY: "ybord"
  Shadow: "shad"
  ShadowX: "xshad"
  ShadowY: "yshad"
  Blur: "blur"
  BlurEdges: "be"

  RotateX: "frx"
  RotateY: "fry"
  RotateZ: "frz"
  Rotate: "fr"
  ShearX: "fax"
  ShearY: "fay"

  Position: "pos"
  Move: "move"
  RotationOrigin: "org"

  Karaoke: "k"
  KaraokeFill: "kf"
  KaraokeFillLegacy: "K"
  KaraokeOutline: "ko"
  KaraokeAbsolute: "kt"

  Drawing: "p"
  DrawingBaselineOffset: "pbo"

  Clip: "clip"
  InverseClip: "iclip"

  Transform: "t"
  Reset: "r"
  WrapStyle: "q"
  Fade: "fad"
  FadeComplex: "fade"
}

---@alias AssArgumentType string
---The distinct data types used across all ASS override tags.
---| "text" # Text: a font name, which an argument of `0` puts back as a bare tag does
---| "color" # Color: a color, written `&HBBGGRR&` or as bare hex digits
---| "alpha" # Alpha: a transparency, written `&HAA&` or as bare hex digits
---| "size-or-scale" # SizeOrScale: a size, or a scale of the size in force where written with a
---  sign. `\fs` alone takes it, and the name is not `FontSize` because `AssRunField` already spells
---  that `font-size`, which a lookup keyed by one and given the other would silently accept.
---| "number" # Number: read as far as a leading numeral converts
---| "integer" # Integer: the same, stopping at the first non-digit
---| "flag" # Flag: 0 or 1, where any other value puts the style's back
---| "weight" # Weight: 0, 1 or 100 upwards, where any other value puts the style's back
---| "style-name" # StyleName: a style to take every field from, the line's own where it names none
---| "drawing" # Drawing: a shape written in drawing commands, as `\clip` takes
---| "tags" # Tags: a run of override tags, which only `\t` takes and which a scan parses recursively
ArgumentType = Enum "AssArgumentType", {
  Text: "text"
  Color: "color"
  Alpha: "alpha"
  SizeOrScale: "size-or-scale"
  Number: "number"
  Integer: "integer"
  Flag: "flag"
  Weight: "weight"
  StyleName: "style-name"
  Drawing: "drawing"
  Tags: "tags"
}

---One attribute of the appearance in force at a point in a line. The set is everything either renderer
---compares to decide where a run of text ends, so a dialect ignores the members it does not read.
---@alias AssRunField string
---| "font-name" # FontName: the face in force
---| "font-size" # FontSize: the size in force
---| "char-set" # CharSet: the character set a face is read with. VSFilter alone compares it.
---| "scale-x" # ScaleX: horizontal scale, as a percentage
---| "scale-y" # ScaleY: vertical scale, as a percentage
---| "spacing" # Spacing: extra space between characters
---| "border-style" # BorderStyle: outline, or the opaque box a style can ask for instead
---| "bold" # Bold: the weight, as a number rather than a switch
---| "italic" # Italic: slant
---| "underline" # Underline
---| "strike-out" # StrikeOut
---| "border-x" # BorderX: outline width across
---| "border-y" # BorderY: outline width down
---| "shadow-x" # ShadowX: shadow offset across
---| "shadow-y" # ShadowY: shadow offset down
---| "rotate-x" # RotateX: rotation about the horizontal axis
---| "rotate-y" # RotateY: rotation about the vertical axis
---| "rotate-z" # RotateZ: rotation in the plane of the frame
---| "shear-x" # ShearX: shear across
---| "shear-y" # ShearY: shear down
---| "blur" # Blur: the gaussian blur over the edges
---| "blur-edges" # BlurEdges: the older box blur, counted in passes
---| "color-1" # Color1: the fill color
---| "color-2" # Color2: the color a karaoke syllable holds until its sweep reaches it
---| "color-3" # Color3: the border color
---| "color-4" # Color4: the shadow color
---| "alpha-1" # Alpha1: the fill's transparency
---| "alpha-2" # Alpha2: the unsung karaoke color's transparency
---| "alpha-3" # Alpha3: the border's transparency
---| "alpha-4" # Alpha4: the shadow's transparency
RunField = Enum "AssRunField", {
  FontName: "font-name"
  FontSize: "font-size"
  CharSet: "char-set"
  ScaleX: "scale-x"
  ScaleY: "scale-y"
  Spacing: "spacing"
  BorderStyle: "border-style"

  Bold: "bold"
  Italic: "italic"
  Underline: "underline"
  StrikeOut: "strike-out"

  BorderX: "border-x"
  BorderY: "border-y"
  ShadowX: "shadow-x"
  ShadowY: "shadow-y"

  RotateX: "rotate-x"
  RotateY: "rotate-y"
  RotateZ: "rotate-z"
  ShearX: "shear-x"
  ShearY: "shear-y"

  Blur: "blur"
  BlurEdges: "blur-edges"

  Color1: "color-1"
  Color2: "color-2"
  Color3: "color-3"
  Color4: "color-4"
  Alpha1: "alpha-1"
  Alpha2: "alpha-2"
  Alpha3: "alpha-3"
  Alpha4: "alpha-4"
}

---@alias AssTransformBehavior string
---What a transform does with a tag written inside it.
---| "interpolated" # Interpolated: stands part way to its target while the interval is open
---| "applied-whole" # AppliedWhole: applies in full from the first frame, whether or not the interval has opened
TransformBehavior = Enum "AssTransformBehavior", {
  Interpolated: "interpolated"
  AppliedWhole: "applied-whole"
}

---Tag-specific settings like argument signatures, the line state attributes it modifies, and any special reading rules.
---@class AssTagDefinition
---@field runFields? AssRunField[] The fields this tag writes, all to the one value it takes, so every
---  tag naming one takes a single argument. `\bord` writes both border axes and `\alpha` all four
---  alphas. Absent where the tag writes none, where it rewrites all of them as `\r` does, and where
---  the tags it holds name them as `\t` does.
---@field signatures AssArgumentType[][] The argument lists this tag accepts, one per accepted length,
---  so the number of arguments picks one. Empty for a tag that takes none at all.
---@field acceptsBareTag? boolean Whether the tag may be written with no argument at all. Absent for
---  the seven a renderer reads nothing from that way, `\pos` and `\clip` among them. A bare tag either
---  restores what the style seeded or means whatever `bareTagDefault` records.
---@field reading? AssArgumentReading What every dialect does with the argument beyond reading its
---  type. Both renderers refuse a negative `\shad` and keep a negative `\xshad`, so this sits on the
---  tag rather than on the field the two of them share.
---@field transform? AssTransformBehavior What a transform holding this tag does with it. Nil where not applicable.
-- cspell:ignore clipm -- a tag written against its argument, quoted verbatim below
---@field requiresParentheses? boolean Whether this tag reads its arguments only from a parenthesized
---  list. libass fills one for these tags from the parenthesis alone and never from the text after the
---  name, so `\clip0,0,50,50` and `\clipm 0 0 l 50 0` are read by nobody, where an unparenthesized
---  `\bord2` is read everywhere.
---@field bareTagDefault? string The argument a tag written bare is equivalent to, for the tags whose
---  bare form means one value in every context. Absent where the bare form refers to something instead
---  — the style's own value, the line's style, the script's wrap style (none of which can be represented as a tag).
---@field firstWinsSlot? AssTagName The slot this tag competes for, where a line's *first* instance is
---  the one read and any later tag naming the same slot is dead. Absent where the tag takes the last
---  value written, as most do. Tags sharing a slot compete for it: `\pos` and `\move` both name `\pos`,
---  `\fad` and `\fade` name `\fad`, and `\a` and `\an` name `\an`.
---@field disablesCollisionDetection? true Whether writing this tag anywhere on a line stops the line
---  being moved aside to clear another. A scroll in the Effect field does the same without any tag.

-- Both renderers run `\fad` and `\fade` through one reading that picks a shape by how many arguments
-- it was given and never by which of the two names was written, so both names take both signatures:
-- two arguments fade in and out, seven state the whole envelope, and any other count fades not at all.
fadeSignatures = {
  {ArgumentType.Integer, ArgumentType.Integer}
  {
    ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer
    ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer
  }
}

---The signatures, reading rules and affected state variables for every tag supported among the dialects.
---@type table<AssTagName, AssTagDefinition>
overrideTags = {
  [TagName.PrimaryColor]: {
    runFields: {RunField.Color1}
    signatures: {{ArgumentType.Color}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.SecondaryColor]: {
    runFields: {RunField.Color2}
    signatures: {{ArgumentType.Color}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.OutlineColor]: {
    runFields: {RunField.Color3}
    signatures: {{ArgumentType.Color}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.ShadowColor]: {
    runFields: {RunField.Color4}
    signatures: {{ArgumentType.Color}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.PrimaryAlpha]: {
    runFields: {RunField.Alpha1}
    signatures: {{ArgumentType.Alpha}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.SecondaryAlpha]: {
    runFields: {RunField.Alpha2}
    signatures: {{ArgumentType.Alpha}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.OutlineAlpha]: {
    runFields: {RunField.Alpha3}
    signatures: {{ArgumentType.Alpha}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.ShadowAlpha]: {
    runFields: {RunField.Alpha4}
    signatures: {{ArgumentType.Alpha}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.Alpha]: {
    runFields: {RunField.Alpha1, RunField.Alpha2, RunField.Alpha3, RunField.Alpha4}
    signatures: {{ArgumentType.Alpha}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  -- The short spelling writes the same field as the numbered one, and the two were drawn against each
  -- other in an interval and outright, indistinguishable in both renderers.
  [TagName.Color]: {
    runFields: {RunField.Color1}
    signatures: {{ArgumentType.Color}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }

  -- VSFilter holds the alignment on the line rather than in the style.
  [TagName.Alignment]: {
    signatures: {{ArgumentType.Integer}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.Alignment
  }
  [TagName.LegacyAlignment]: {
    signatures: {{ArgumentType.Integer}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.Alignment
  }

  [TagName.FontName]: {
    runFields: {RunField.FontName}
    signatures: {{ArgumentType.Text}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  [TagName.FontSize]: {
    runFields: {RunField.FontSize}
    signatures: {{ArgumentType.SizeOrScale}}
    acceptsBareTag: true
    reading: {requiresPositive: true}
    transform: TransformBehavior.Interpolated
  }
  [TagName.ScaleReset]: {
    runFields: {RunField.ScaleX, RunField.ScaleY}
    signatures: {}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  [TagName.ScaleX]: {
    runFields: {RunField.ScaleX}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.ScaleY]: {
    runFields: {RunField.ScaleY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.FontSpacing]: {
    runFields: {RunField.Spacing}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.FontEncoding]: {
    runFields: {RunField.CharSet}
    signatures: {{ArgumentType.Integer}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }

  [TagName.Bold]: {
    runFields: {RunField.Bold}
    signatures: {{ArgumentType.Weight}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  [TagName.Italic]: {
    runFields: {RunField.Italic}
    signatures: {{ArgumentType.Flag}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  [TagName.Underline]: {
    runFields: {RunField.Underline}
    signatures: {{ArgumentType.Flag}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  [TagName.StrikeOut]: {
    runFields: {RunField.StrikeOut}
    signatures: {{ArgumentType.Flag}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }

  [TagName.Border]: {
    runFields: {RunField.BorderX, RunField.BorderY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.BorderX]: {
    runFields: {RunField.BorderX}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.BorderY]: {
    runFields: {RunField.BorderY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.Shadow]: {
    runFields: {RunField.ShadowX, RunField.ShadowY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.ShadowX]: {
    runFields: {RunField.ShadowX}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.ShadowY]: {
    runFields: {RunField.ShadowY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.Blur]: {
    runFields: {RunField.Blur}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    reading: {minimum: 0}
    transform: TransformBehavior.Interpolated
  }
  [TagName.BlurEdges]: {
    runFields: {RunField.BlurEdges}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }

  [TagName.RotateX]: {
    runFields: {RunField.RotateX}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.RotateY]: {
    runFields: {RunField.RotateY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.RotateZ]: {
    runFields: {RunField.RotateZ}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.Rotate]: {
    runFields: {RunField.RotateZ}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.ShearX]: {
    runFields: {RunField.ShearX}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }
  [TagName.ShearY]: {
    runFields: {RunField.ShearY}
    signatures: {{ArgumentType.Number}}
    acceptsBareTag: true
    transform: TransformBehavior.Interpolated
  }

  [TagName.Position]: {
    requiresParentheses: true
    signatures: {{ArgumentType.Number, ArgumentType.Number}}
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.Position
    disablesCollisionDetection: true
  }
  [TagName.RotationOrigin]: {
    requiresParentheses: true
    signatures: {{ArgumentType.Number, ArgumentType.Number}}
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.RotationOrigin
    disablesCollisionDetection: true
  }
  [TagName.Move]: {
    requiresParentheses: true
    signatures: {
      {ArgumentType.Number, ArgumentType.Number, ArgumentType.Number, ArgumentType.Number}
      {
        ArgumentType.Number, ArgumentType.Number, ArgumentType.Number, ArgumentType.Number
        ArgumentType.Integer, ArgumentType.Integer
      }
    }
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.Position
    disablesCollisionDetection: true
  }

  -- These end a run on a non-zero duration and on a change of karaoke type, neither of which is a
  -- style field, so the karaoke reader applies both rules rather than this table. `\kt` ends none: it
  -- moves the clock without writing a duration.
  -- None of these writes a value a transform could animate
  [TagName.Karaoke]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Integer}}
    bareTagDefault: "100"
    transform: nil
  }
  [TagName.KaraokeFill]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Integer}}
    bareTagDefault: "100"
    transform: nil
  }
  [TagName.KaraokeFillLegacy]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Integer}}
    bareTagDefault: "100"
    transform: nil
  }
  [TagName.KaraokeOutline]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Integer}}
    bareTagDefault: "100"
    transform: nil
  }
  [TagName.KaraokeAbsolute]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Number}}
    bareTagDefault: "0"
    transform: nil
  }

  -- Instead of having its toggle/scale value recorded in the run state, a drawing tag merely signals
  -- whether the characters following the tag block are to be read as drawing commands (and if so at
  -- what scale) or normal text. However, each drawing renders in an isolated run, so one *does* split
  -- karaoke syllables.
  [TagName.Drawing]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Integer}}
    reading: {minimum: 0}
    bareTagDefault: "0"
    transform: TransformBehavior.AppliedWhole
  }
  -- `\pbo` reaches the renderer rather than the style.
  [TagName.DrawingBaselineOffset]: {
    acceptsBareTag: true
    signatures: {{ArgumentType.Integer}}
    bareTagDefault: "0"
    transform: TransformBehavior.AppliedWhole
  }

  -- Which signature was written decides what a transform does with either of these, so the tag alone
  -- cannot answer it: four numbers are interpolated edge by edge, where a path is handed to a parser
  -- the interpolation factor never reaches and so applies whole and from the first frame. Both were
  -- observed in both renderers. A rewrite has to read the form before it may move one.
  [TagName.Clip]: {
    requiresParentheses: true
    signatures: {
      {ArgumentType.Drawing}
      {ArgumentType.Integer, ArgumentType.Drawing}
      {ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer}
    }
    transform: nil
  }
  [TagName.InverseClip]: {
    requiresParentheses: true
    signatures: {
      {ArgumentType.Drawing}
      {ArgumentType.Integer, ArgumentType.Drawing}
      {ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Integer}
    }
    transform: nil
  }

  -- `\t` names no run fields, but the tags it holds do, so `AssRunState` applies those instead. They
  -- write wherever the animation has reached, which means a run splits from the transform's start and
  -- not from the tag itself.
  [TagName.Transform]: {
    acceptsBareTag: true
    requiresParentheses: true
    signatures: {
      {ArgumentType.Tags}
      {ArgumentType.Number, ArgumentType.Tags}
      {ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Tags}
      {ArgumentType.Integer, ArgumentType.Integer, ArgumentType.Number, ArgumentType.Tags}
    }
    -- transforms do not nest and instead overwrite any previous one for the same run field and time slice
    transform: nil
    -- `\t` disables collision detection regardless of what tags it animates, even if it's empty.
    disablesCollisionDetection: true
    -- Both renderers draw a bare `\t` exactly as `\t(0,0,)`, but the latter arguably looks worse.
    -- It would also need the emitter to add parentheses, since a default is
    -- applied by assigning it to `params` and a bare `\t` records no form saying it has any.
    bareTagDefault: nil
  }
  [TagName.Reset]: {
    signatures: {{ArgumentType.StyleName}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  -- `\q` reaches the renderer rather than the style. It reaches a run only by moving where the line
  -- breaks, since a break ends one and `\n` breaks under wrap style 2 alone.
  [TagName.WrapStyle]: {
    signatures: {{ArgumentType.Integer}}
    acceptsBareTag: true
    transform: TransformBehavior.AppliedWhole
  }
  [TagName.Fade]: {
    requiresParentheses: true
    signatures: fadeSignatures
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.Fade
  }
  [TagName.FadeComplex]: {
    requiresParentheses: true
    signatures: fadeSignatures
    transform: TransformBehavior.AppliedWhole
    firstWinsSlot: TagName.Fade
  }
}

---A normalization applied to tag arguments and style values before comparing them against or writing
---them to a line's run state. Not to be confused with the bounds in `AssArgumentReading`, which are
---applied to tag arguments read from text (after conversions are applied), but never to style values.
---@class AssValueConversion
---@field roundsToWhole? boolean Whether the value becomes a whole number, rounding at the half.
---@field resolvesWeight? boolean Whether 0 and 1 become GDI's normal and bold weights rather than staying as written.

---What a dialect does with a tag's argument: the type it reads it as, the conversion applied to the
---result, and the bounds it is held to. Every field is optional, and an absent one leaves the tag's own
---declaration in force.
---@class AssArgumentReading
---@field type? AssArgumentType The type the argument is read as, where that differs from the type the
---  tag declares. Applies to a tag taking a single parameter (subject to change in case a
---  multi-parameter reading quirk is discovered).
---@field conversion? AssValueConversion Applied to the value once the argument is read, and to a
---  style's own value before the two are compared.
---@field requiresPositive? boolean Whether a value landing at or below zero puts the style's own back
---  instead of being taken. A restore rather than a clamp, and applied to the result, so a scale that
---  falls to zero restores as surely as a zero written outright.
---@field minimum? number The least value accepted, which anything smaller is written back as.
---@field maximum? number The greatest, likewise.
---@field refusesLiteralWithoutDigits? boolean Whether a literal holding no digit at all puts the style's
---  own value back rather than reading as zero. Only applies to color and alpha tags, where a
---  prefix can stand with nothing behind it (e.g. `\c&&`).

---Builds the set of names a dialect matches against, and reports the longest of them so prefix
---matching knows the width to start at.
---@param unknown AssTagName[] The names this dialect does not declare.
---@return table<string, true> names Every declared name except those, as a set.
---@return integer longest Length of the longest name in the set.
buildTagNames = (unknown) ->
  excluded = {name, true for name in *unknown}

  names, longest = {}, 0
  for name in *TagName.values
    continue if excluded[name]
    names[name] = true
    longest = math.max longest, #name
  names, longest

---One implementation's reading of override syntax: the names it declares, and the decisions it takes
---that the other two take differently, both while scanning and while deciding where a run of text ends.
---@class AssDialect
---@field name string Identifies the dialect in test names and errors.
---@field unknownTagNames AssTagName[] Declared names this dialect does not know, which is what makes
---  its scan fall back onto a shorter name prefixing the same text.
---@field tagNames table<string, true> Names this dialect knows, without a leading backslash.
---@field longestTagName integer Length of the longest name, where prefix matching starts.
---@field argumentReadings table<AssTagName, AssArgumentReading> What this dialect does with a tag's
---  argument where that differs from the tag's own reading.
---  How an argument is read belongs here and which fields a run comparison reads belongs in
---  `runComparison`: libass rounding `\be0.6` up to 1 is the first, and VSFilter counting the
---  character set, so that `\fe` ends a run, is the second.
---@field skipsWhitespaceAfterBackslash boolean Whether a space or a tab between the backslash and the
---  name is ignored.
---@field honorsBraceEscapes boolean Whether `\{` and `\}` render a literal brace instead of ordinary text.
---@field hasCommentBlockType boolean Whether brace content holding no backslash is a block type of its own.
---  Where it is not, that content is emitted as junk, so a scan stays lossless in every dialect.
---@field argumentsEndAtFirstParen boolean Whether a parenthesized argument list stops at the first `)`.
---@field trimsLeadingWhitespaceInArguments boolean Whether whitespace leading an argument is dropped
---  along with the whitespace trailing one, which every dialect drops. Only Aegisub does, so
---  `{\r Bold}` finds the style there and puts the line's own back in both renderers. A font name has
---  its leading whitespace skipped everywhere regardless, which is the `\fn` handler's own doing.
---@field runComparison? AssRunComparison How this dialect decides where a run of text ends. Absent for
---  a dialect that compares no runs, which is what makes every trait describing that comparison moot.
---@field restoresTheStyleInForce? boolean Whether a tag written bare, or one whose argument is refused,
---  puts back the style an earlier `\rStyle` put in force. Where false it puts back the line's own style
---  instead, so `{\rBold\b}` draws bold where this is true and regular where it is false.
---  Absent for dialects that don't do run comparisons.
---@field softLineBreaksActiveAboveDeclaredWrapStylesRange? boolean Whether a wrap style number greater
---  than the highest supported one makes `\n` break the line. Both renderers break under the no-wrap style and
---  neither breaks below zero, so this is the whole of where they part on a soft break, and no
---  conforming script reaches it. Absent for dialects that don't do run comparisons.

---Which style fields a dialect compares to decide where a run of text ends. A run is a maximal span of
---like-styled characters, and a renderer shapes, measures and draws one as a single unit. A tag writing
---any of the compared fields ends the run, and ends the karaoke syllable in progress with it.
---@class AssRunComparison
---@field comparesCharacterSet boolean Whether `\fe` ends a run.
---@field foldsBorderStyle boolean Whether a style's border style is compared only as 3 against not-3,
---  so a style declaring 1 and one declaring 2 compare equal. No tag writes the field, but `\r`
---  switches to a style that may declare a different one.

---The dialects a scan can be driven with, keyed by name.
---@type table<string, AssDialect>
dialects = {
  -- Aegisub's own tag table spells a name with its backslash where the renderers' tables do not. Names
  -- are held bare for every dialect here and `getOverrideTag` puts the backslash back where Aegisub's
  -- API expects one, so the spelling never reaches a dialect trait.
  --
  -- Aegisub edits a script rather than drawing one, so it never asks where a run of text ends and
  -- declares no `runComparison`.
  aegisub: {
    name: DialectName.Aegisub
    -- reads `\fsc` as `\fs` with a size of 'c', and `\kt` as `\k` with a duration of 't100'. Both
    -- fallbacks are visible to a script, each yielding a karaoke syllable the renderers do not report.
    unknownTagNames: {TagName.ScaleReset, TagName.KaraokeAbsolute}
    argumentReadings: {}
    skipsWhitespaceAfterBackslash: false
    honorsBraceEscapes: false
    hasCommentBlockType: true
    argumentsEndAtFirstParen: false
    trimsLeadingWhitespaceInArguments: true
  }

  libass: {
    name: DialectName.Libass
    unknownTagNames: {}
    argumentReadings: {
      [TagName.BlurEdges]: {conversion: {roundsToWhole: true}, minimum: 0, maximum: 127}
      [TagName.Karaoke]: {type: ArgumentType.Number}
      [TagName.KaraokeFill]: {type: ArgumentType.Number}
      [TagName.KaraokeFillLegacy]: {type: ArgumentType.Number}
      [TagName.KaraokeOutline]: {type: ArgumentType.Number}
    }
    skipsWhitespaceAfterBackslash: true
    honorsBraceEscapes: true
    hasCommentBlockType: false
    argumentsEndAtFirstParen: true
    trimsLeadingWhitespaceInArguments: false
    restoresTheStyleInForce: true
    -- asks whether the wrap style is the no-wrap one, so nothing else breaks `\n`
    softLineBreaksActiveAboveDeclaredWrapStylesRange: false
    runComparison:
      comparesCharacterSet: false
      foldsBorderStyle: false
  }

  vsfilter: {
    name: DialectName.XyVsfilter
    unknownTagNames: {}
    -- `\c&&` puts the style's color back here and draws black under libass, both at block level and
    -- inside a transform's interval, drawn against a style holding neither. Every color and alpha tag
    -- reads a digit-less literal that way, which is why all ten say so.
    argumentReadings: {
      [TagName.Bold]: {conversion: {resolvesWeight: true}}
      [TagName.Karaoke]: {type: ArgumentType.Number}
      [TagName.KaraokeFill]: {type: ArgumentType.Number}
      [TagName.KaraokeFillLegacy]: {type: ArgumentType.Number}
      [TagName.KaraokeOutline]: {type: ArgumentType.Number}
      [TagName.PrimaryColor]: {refusesLiteralWithoutDigits: true}
      [TagName.SecondaryColor]: {refusesLiteralWithoutDigits: true}
      [TagName.OutlineColor]: {refusesLiteralWithoutDigits: true}
      [TagName.ShadowColor]: {refusesLiteralWithoutDigits: true}
      [TagName.Color]: {refusesLiteralWithoutDigits: true}
      [TagName.PrimaryAlpha]: {refusesLiteralWithoutDigits: true}
      [TagName.SecondaryAlpha]: {refusesLiteralWithoutDigits: true}
      [TagName.OutlineAlpha]: {refusesLiteralWithoutDigits: true}
      [TagName.ShadowAlpha]: {refusesLiteralWithoutDigits: true}
      [TagName.Alpha]: {refusesLiteralWithoutDigits: true}
    }
    skipsWhitespaceAfterBackslash: true
    honorsBraceEscapes: false
    hasCommentBlockType: false
    argumentsEndAtFirstParen: true
    trimsLeadingWhitespaceInArguments: false
    restoresTheStyleInForce: false
    -- asks instead whether the wrap style is one of the three that wrap, so every other value breaks
    softLineBreaksActiveAboveDeclaredWrapStylesRange: true
    runComparison:
      comparesCharacterSet: true
      foldsBorderStyle: true
  }
}

-- Filled in from each dialect's own `unknownTagNames`, since the set a scan matches against is what
-- that list leaves standing.
for _, dialect in pairs dialects
  dialect.tagNames, dialect.longestTagName = buildTagNames dialect.unknownTagNames

-- Merged once per dialect so that reading one costs a pair of table indexes rather than a merge.
readingByDialect = {}
for dialectName in *DialectName.values
  overrides = dialects[dialectName].argumentReadings or {}
  readings = {}
  for name, definition in pairs overrideTags
    merged = {key, value for key, value in pairs definition.reading or {}}
    merged[key] = value for key, value in pairs overrides[name] or {}
    -- the nested conversion merges as its own table, or a tag stating one would lose the other's
    conversion = {key, value for key, value in pairs (definition.reading or {}).conversion or {}}
    conversion[key] = value for key, value in pairs (overrides[name] or {}).conversion or {}
    merged.conversion = next(conversion) and conversion or nil
    readings[name] = merged
  readingByDialect[dialectName] = readings

---What a dialect does with one tag's argument, taking the tag's own reading where it states no override.
---@param dialect AssDialectName Whose reading to apply.
---@param name AssTagName The tag whose argument is being read.
---@return AssArgumentReading reading Empty where neither states anything, never nil for a declared name.
getArgumentReading = (dialect, name) ->
  readings = readingByDialect[dialect]
  readings and readings[name] or {}

-- Per dialect, the conversion each compared field takes, for the fields where there is one at all.
-- All tags writing the same run field have to agree on the conversion, or they might be evaluated as
-- unequal despite their argument literals being identical.
conversionByDialect = {}
for dialectName in *DialectName.values
  conversions = {}
  for name, definition in pairs overrideTags
    continue unless definition.runFields
    {:conversion} = readingByDialect[dialectName][name]
    continue unless conversion
    conversions[field] = conversion for field in *definition.runFields
  conversionByDialect[dialectName] = conversions

---The conversion one dialect applies to a compared field, which a style's own value takes before it
---can be compared against what a tag writes.
---@param dialect AssDialectName Whose conversion to apply.
---@param field AssRunField The compared field.
---@return AssValueConversion? conversion Nil where the field is held as the number was read.
getFieldConversion = (dialect, field) ->
  conversions = conversionByDialect[dialect]
  conversions and conversions[field]

---The primitives a drawing is built from. Each selects the kind of segment the
---coordinates after it continue the drawing with.
---@alias AssDrawingCommandName string
---| "m" # Move: closes the contour before it and starts one at the point given
---| "n" # OpenMove: starts a contour without closing the one before it
---| "l" # Line: a straight segment to the point given
---| "b" # CubicCurve: a cubic curve through three points
---| "s" # Spline: a b-spline through three points
---| "p" # SplineExtension: one more point on the spline already open
---| "c" # SplineClose: closes the spline by repeating its first three points
DrawingCommandName = Enum "AssDrawingCommandName", {
  Move: "m"
  OpenMove: "n"
  Line: "l"
  CubicCurve: "b"
  Spline: "s"
  SplineExtension: "p"
  SplineClose: "c"
}

---What a drawing command needs before it draws anything.
---@class AssDrawingCommandArity
---@field opens integer Coordinates the command needs before it draws at all.
---@field repeats integer Coordinates each further segment takes, the command holding until the next
---  one names something else, so `l 0 0 10 10` draws two lines. A spline opens on three points and
---  extends by one at a time, so it is the one command that repeats at a different count than it opens.
---@field needsNodes integer Nodes the drawing must already hold for the command to be read at all.
---@field dropsPartialOpening boolean Whether an opening group left incomplete is discarded by every
---  renderer. A spline is, at one point and at two alike, observed in both. A cubic curve is not, and
---  that is the divergence: libass drops such points where VSFilter keeps them in the path, widening
---  the drawing without drawing them. Where a command opens on one point there is no group to leave
---  partial, so this never bites.

---One command of a drawing, and what every dialect makes of it.
---@class AssDrawingCommandDefinition
---@field arity AssDrawingCommandArity What the command needs before it draws anything.

---The commands a drawing is written with, keyed by the letter that names one.
---@type table<AssDrawingCommandName, AssDrawingCommandDefinition>
drawingCommands = {
  [DrawingCommandName.Move]: {arity: {opens: 2, repeats: 2, needsNodes: 0, dropsPartialOpening: true}}
  [DrawingCommandName.OpenMove]: {arity: {opens: 2, repeats: 2, needsNodes: 0, dropsPartialOpening: true}}
  [DrawingCommandName.Line]: {arity: {opens: 2, repeats: 2, needsNodes: 1, dropsPartialOpening: true}}
  [DrawingCommandName.CubicCurve]: {arity: {opens: 6, repeats: 6, needsNodes: 1, dropsPartialOpening: false}}
  [DrawingCommandName.Spline]: {arity: {opens: 6, repeats: 2, needsNodes: 1, dropsPartialOpening: true}}
  [DrawingCommandName.SplineExtension]: {arity: {opens: 2, repeats: 2, needsNodes: 3, dropsPartialOpening: true}}
  [DrawingCommandName.SplineClose]: {arity: {opens: 0, repeats: 0, needsNodes: 3, dropsPartialOpening: true}}
}

---Builds the override tag for a bare name, adding the backslash that introduces it.
---@param name AssTagName A bare name, as `TagName` holds and a scan reports.
---@return string tag The name with its leading backslash.
getOverrideTag = (name) -> Syntax.TagPrefix .. name

---Whether a tag opens a karaoke syllable, which every dialect decides the same way: by the name
---starting with `k` in either case. That covers `\K`, `\kf`, `\ko`, `\kt`, and a `\kt` that fell
---back to `\k` in a dialect not declaring it.
---@param name AssTagName A bare name, as a scan reports.
---@return boolean
isKaraokeTagName = (name) -> name\lower!\sub(1, 1) == TagName.Karaoke

---The vocabulary an override-tag scan is written against, and the three dialects it can be driven
---with. Aegisub, libass and VSFilter disagree about enough of ASS override syntax that which one is
---asked changes the answer, so a dialect is a required argument to anything that scans.
---@class AssOverrideDialects
return {
  :TokenKind, :Syntax, :TagName, :DialectName, :ArgumentType, :RunField, :DrawingCommandName
  :TransformBehavior, :drawingCommands
  :getOverrideTag, :isKaraokeTagName, :getArgumentReading, :getFieldConversion, :overrideTags, :dialects
}
