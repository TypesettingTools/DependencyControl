-- One rewrite a normalizer might make, and which dialects cannot tell the two forms apart. Every row
-- records what probing the renderers established, so this file is a specification rather than a record
-- of what this library believes: `diagnostics.isEquivalent` derives the same answer independently, and
-- the Diagnostics suite fails where the two part.
-- Required by test.moon and handed to the suites that read it.

{:BorderStyle, :WrapStyle, :defaultStyle} = require "l0.AssParser.ass"
{:DialectName} = require "l0.AssParser.dialects"

renderers = {DialectName.Libass, DialectName.XyVsfilter}
libassOnly = {DialectName.Libass}
vsfilterOnly = {DialectName.XyVsfilter}
neither = {}

-- Styles alike but for a border style, which is reachable only through `\r` since no tag writes the
-- field. 2 is a value the format gives no meaning to and both renderers draw as the outline 1 asks for,
-- so one dialect folding it and the other comparing the number is a difference in reading alone. 4 is
-- the one libass draws its own way, as a box behind the whole line, which VSFilter draws as an outline
-- like everything else it does not read as the opaque box.
borderStyles =
  Outlined: {k, v for k, v in pairs defaultStyle}
  Unmeaning: {k, v for k, v in pairs defaultStyle}
  Shadowed: {k, v for k, v in pairs defaultStyle}
borderStyles.Outlined.name, borderStyles.Outlined.borderstyle = "Outlined", 1
borderStyles.Unmeaning.name, borderStyles.Unmeaning.borderstyle = "Unmeaning", 2
borderStyles.Shadowed.name, borderStyles.Shadowed.borderstyle = "Shadowed", BorderStyle.ShadowBox

-- A style declaring bold, which `\r` reaches by name. A refused `\b` puts a style's bold back, and
-- the two renderers read that from different styles once a reset has moved one of them.
weightStyles =
  Regular: {k, v for k, v in pairs defaultStyle}
  Bolded: {k, v for k, v in pairs defaultStyle}
weightStyles.Regular.name = "Regular"
weightStyles.Bolded.name, weightStyles.Bolded.bold = "Bolded", true

---One rewrite a normalizer might make, and the dialects that cannot tell the two forms apart. The
---context is deliberately the same throughout — a karaoke tag, a character, the tag in question,
---another character — so that a row reports the tag's reading and not the shape it was put in.
---@class AssEquivalence
---@field name string
---@field written string The line as it might be found.
---@field rewritten string The line a normalizer would put in its place.
---@field dialects AssDialectName[] Those that read the two alike, so the rewrite is safe for them.
---@field stylesByName? table<string, AegisubStyleLine> Styles the pair reaches by name.
---@field wrapStyle? AssWrapStyle The script's wrap style the pair is read under, for a row that turns on it.
---@field note? string Why the row is worth keeping, where that is not obvious.
equivalences = {
  -- A value outside what a tag accepts puts the style's back, which is what a bare tag does. Both
  -- renderers agree, so these are the rewrites a normalizer can make without asking anything else.
  {name: "weightOutsideItsRange", written: "{\\k50}a{\\b2}b", rewritten: "{\\k50}a{\\b}b", dialects: renderers}
  {name: "weightBelowOneHundred", written: "{\\k50}a{\\b99}b", rewritten: "{\\k50}a{\\b}b", dialects: renderers}
  {name: "negativeFlag", written: "{\\k50}a{\\i-1}b", rewritten: "{\\k50}a{\\i}b", dialects: renderers}
  {name: "flagAboveOne", written: "{\\k50}a{\\i5}b", rewritten: "{\\k50}a{\\i}b", dialects: renderers}
  {name: "fractionalFlag", written: "{\\k50}a{\\u1.5}b", rewritten: "{\\k50}a{\\u1}b", dialects: renderers,
    note: "an argument is read as a whole number, so this switches the underline on rather than being refused"}
  {name: "fontNameZero", written: "{\\k50}a{\\fn0}b", rewritten: "{\\k50}a{\\fn}b", dialects: renderers}

  -- Both renderers hold these at zero or above, so a negative argument is the same as writing zero.
  {name: "negativeBorder", written: "{\\k50}a{\\bord-2}b", rewritten: "{\\k50}a{\\bord0}b", dialects: renderers}
  {name: "negativeBorderAxis", written: "{\\k50}a{\\xbord-2}b", rewritten: "{\\k50}a{\\xbord0}b", dialects: renderers}
  {name: "negativeVerticalBorderAxis", written: "{\\k50}a{\\ybord-2}b", rewritten: "{\\k50}a{\\ybord0}b", dialects: renderers}
  {name: "negativeShadow", written: "{\\k50}a{\\shad-2}b", rewritten: "{\\k50}a{\\shad0}b", dialects: renderers}
  {name: "negativeBlur", written: "{\\k50}a{\\blur-5}b", rewritten: "{\\k50}a{\\blur0}b", dialects: renderers}
  {name: "negativeDrawingScale", written: "{\\k50}a{\\p-1}b", rewritten: "{\\k50}a{\\p0}b", dialects: renderers}
  {name: "zeroSize", written: "{\\k50}a{\\fs0}b", rewritten: "{\\k50}a{\\fs}b", dialects: renderers,
    note: "a size at or below zero puts the style's own back rather than being held at zero"}
  {name: "sizeScaledToZero", written: "{\\k50}a{\\fs-10}b", rewritten: "{\\k50}a{\\fs}b", dialects: renderers,
    note: "a signed size scales the size in force by a tenth of what it names, so -10 lands the scale
      at zero and the restore is what both draw"}

  -- The rewrites that look like the ones above and are not. Each is safe for at most one renderer, so
  -- a normalizer asked to satisfy both has to refuse the line rather than tidy it.
  {name: "negativeShadowAxis", written: "{\\k50}a{\\xshad-2}b", rewritten: "{\\k50}a{\\xshad0}b", dialects: neither,
    note: "the trap of the set: it reads like `\\shad`, and neither renderer clamps it"}
  {name: "fractionalBlurEdges", written: "{\\k50}{\\be1}a{\\be0.6}b", rewritten: "{\\k50}{\\be1}a{\\be1}b", dialects: libassOnly,
    note: "one renderer rounds to a whole pass, and the fraction reaches the other's raster"}
  {name: "negativeBlurEdges", written: "{\\k50}a{\\be-3}b", rewritten: "{\\k50}a{\\be0}b", dialects: libassOnly}
  {name: "explicitWeight", written: "{\\k50}{\\b1}a{\\b700}b", rewritten: "{\\k50}{\\b1}a{\\b1}b", dialects: vsfilterOnly,
    note: "one resolves both spellings to a weight, the other compares the number as written"}
  {name: "refusedWeightAfterReset", written: "{\\k50}a{\\rBolded\\b50}b", rewritten: "{\\k50}a{\\rBolded}b",
    dialects: libassOnly, stylesByName: weightStyles,
    note: "one restores the style the reset put in force, so dropping the refused weight changes nothing;
      the other restores the line's own style and the drop turns the text bold"}
  {name: "shadowBoxBorderStyle", written: "{\\k50}a{\\rShadowed}b", rewritten: "{\\k50}a{\\rOutlined}b",
    dialects: vsfilterOnly, stylesByName: borderStyles,
    note: "the one border style libass draws its own way, which the folding dialect cannot tell from
      the outline it draws for it"}
  {name: "meaninglessBorderStyle", written: "{\\k50}a{\\rUnmeaning}b", rewritten: "{\\k50}a{\\rOutlined}b",
    dialects: vsfilterOnly, stylesByName: borderStyles,
    note: "reachable only through `\\r`, so a style-level divergence is a line-level one too"}
  {name: "outOfRangeWrapStyle", written: "{\\q9}{\\k50}aa\\nbb", rewritten: "{\\q}{\\k50}aa\\nbb",
    dialects: renderers, wrapStyle: WrapStyle.NoWordWrap,
    note: "both renderers put the script's wrap style back for an argument outside the declared four,
      as a bare tag does. The row departs from the shared context because a `\\q` shows only through a
      soft break, and the script has to state the no-wrap style: under any other, restoring and keeping
      the 9 read alike and the row would check nothing"}
}

return equivalences
