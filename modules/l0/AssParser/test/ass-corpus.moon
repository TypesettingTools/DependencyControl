-- Conformance corpus for ASS override-tag scanning: one input line, and the token stream each of the
-- three dialects is expected to make of it. The suite runs every row against the scanner in both
-- directions, so this file is the scanner's specification rather than a record of its behavior.

Enum = require "l0.DependencyControl.Enum"

---Where a row's expectation came from, which is what says how far to trust it.
---@alias AssCorpusProvenance string
---| "derived" # Derived: read out of the implementation's source and never run, so a hypothesis
---| "partial" # Partial: the row's outcome was reproduced, while some token in it stays derived
---| "observed" # Observed: captured from the implementation itself, running
Provenance = Enum "AssCorpusProvenance", {
  Derived: "derived"
  Partial: "partial"
  Observed: "observed"
}

---One line and what each dialect is expected to make of it.
---@class AssCorpusCase
---@field name string Short identifier, used in test names.
---@field input string The line text, exactly as it would appear in the Text field.
---@field why string What the case is here to pin down.
---@field aegisub table The expected token stream under the Aegisub dialect.
---@field libass table The expected token stream under the libass dialect.
---@field vsfilter table The expected token stream under the VSFilter dialect.
---@field source table<string, AssCorpusProvenance> Where each dialect's expectation came from.

---@type AssCorpusCase[]
return {
  {
    name: "plainTextOnly"
    input: "Hello world"
    why: "A line with no braces is one text token, and every dialect agrees. No competing reading
      exists to rule out, so libass observing it is a by-product: every control the rendering probe
      compares against is a plain line, and each one renders as the characters it holds."
    aegisub: {{kind: "text", text: "Hello world"}}
    libass: {{kind: "text", text: "Hello world"}}
    vsfilter: {{kind: "text", text: "Hello world"}}
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "singleTag"
    input: "{\\b1}bold"
    why: "The baseline shape: a block holding one tag, then text."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "b", params: "1"}
      {kind: "block-end"}
      {kind: "text", text: "bold"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "b", params: "1"}
      {kind: "block-end"}
      {kind: "text", text: "bold"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "b", params: "1"}
      {kind: "block-end"}
      {kind: "text", text: "bold"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "tagsShareOneBlock"
    input: "{\\b1\\i1}both"
    why: "Several overrides in one pair of braces, which the specification explicitly allows."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "b", params: "1"}
      {kind: "tag", name: "i", params: "1"}
      {kind: "block-end"}
      {kind: "text", text: "both"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "b", params: "1"}
      {kind: "tag", name: "i", params: "1"}
      {kind: "block-end"}
      {kind: "text", text: "both"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "b", params: "1"}
      {kind: "tag", name: "i", params: "1"}
      {kind: "block-end"}
      {kind: "text", text: "both"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "karaokeLongerNameWinsOverShorter"
    input: "{\\kf30}fade"
    why: "Both dialects order their tag tables longest-first for the k family, so \\kf must not be
      read as \\k with a parameter of 'f30'. Aegisub lists \\ko and \\kf ahead of \\k; libass tests
      kt, kf, ko before k. In libass the syllable sweeps, matching the same line written with \\K and
      parting from both a zero-duration \\k and a plain \\k of the same length."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "kf", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "fade"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "kf", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "fade"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "kf", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "fade"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "unknownKaraokeTagFallsBackToPrefix"
    input: "{\\kt100}start"
    why: "AEGISUB ALONE. libass and VSFilter both know \\kt; Aegisub does not, so its proto scan
      matches \\k by prefix
      and leaves 't100' as the parameter, which parses as integer 0. The same line is a karaoke
      timing tag to one and a zero-duration syllable to the other. Aegisub marks the tag valid, so
      the fallback is a match rather than an error it recovers from."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "t100"}
      {kind: "block-end"}
      {kind: "text", text: "start"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "kt", params: "100"}
      {kind: "block-end"}
      {kind: "text", text: "start"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "kt", params: "100"}
      {kind: "block-end"}
      {kind: "text", text: "start"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "unknownScaleTagFallsBackToFontSize"
    why: "AEGISUB ALONE. libass and VSFilter both know \\fsc, which resets both scale axes; Aegisub
      does not, and its
      proto scan reaches \\fs first by prefix, leaving 'c' as a font size. Aegisub reports the name
      as \\fs with one float parameter holding 'c', which is the whole of the predicted reading.
      Showing the libass half needs a scale moved off the style's value first, since a reset lands
      where the scale already sat: after \\fscx300 the tag returns the line to its style width."
    input: "{\\fsc}text"
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "fs", params: "c"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "fsc", params: ""}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "fsc", params: ""}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "relativeFontSize"
    why: "SHARED, and deliberately so. All three treat the size as relative, which rendering confirms:
      this line matches {\\fs72}text exactly, each computing 48 * (1 + 5/10). Aegisub reaches that
      through two tag names of its own, declaring \\fs+ and \\fs- ahead of \\fs so the sign belongs to
      the name; the renderers match \\fs and keep the sign in the parameter. Neither split is modeled,
      because no Aegisub API hands a tag list to a script — parse_karaoke_data reports karaoke tags
      and nothing else — so the difference cannot be observed from automation, and modeling it would
      leave every consumer handling two spellings of one thing. What the split is for inside Aegisub
      is its parameter classes, which class \\fs as an absolute size and these two as nothing so that
      resampling scales a size and leaves a factor alone; a consumer wanting that needs the classes,
      which are not recorded here either. A name absent from a tag table is not evidence that the
      behavior is absent too."
    input: "{\\fs+5}text"
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "fs", params: "+5"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "fs", params: "+5"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "fs", params: "+5"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "tabAfterBackslash"
    input: "{\\\tk30}tab"
    why: "AEGISUB ALONE, and for the same reason the space row states. Both renderers skip a tab as
      readily as a space, since the `skip_spaces` they read a name through takes those two characters
      and nothing else. Observed by rendering, on the pair together, so the row does not rest on the
      space case generalizing."
    aegisub: {
      {kind: "block-start"}
      {kind: "junk", text: "\\\tk30"}
      {kind: "block-end"}
      {kind: "text", text: "tab"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "tab"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "tab"}
    }
  }

  {
    name: "karaokeAroundADrawing"
    input: "{\\k50}a{\\p1}m 0 0{\\p0}b"
    why: "All three read the same tokens; what they do with them parts the renderers from Aegisub. Both
      renderers isolate a drawing in a run of its own, so `b` waits, observed by rendering a degenerate
      drawing between two words. Aegisub splits on karaoke tags alone and reports one syllable running
      the whole 500ms, holding `m 0 0` out of the stripped text and keeping it in `text`, observed
      through `parse_karaoke_data`."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "50"}
      {kind: "block-end"}
      {kind: "text", text: "a"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "1"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "0"}
      {kind: "block-end"}
      {kind: "text", text: "b"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "50"}
      {kind: "block-end"}
      {kind: "text", text: "a"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "1"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "0"}
      {kind: "block-end"}
      {kind: "text", text: "b"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "50"}
      {kind: "block-end"}
      {kind: "text", text: "a"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "1"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "0"}
      {kind: "block-end"}
      {kind: "text", text: "b"}
    }
  }

  {
    name: "whitespaceAfterBackslash"
    input: "{\\ k30}space"
    why: "AEGISUB ALONE. libass and VSFilter both skip spaces after the backslash before reading a
      name; Aegisub matches
      its proto names by literal prefix, so nothing matches. Aegisub keeps the whole run as the tag's
      name and marks it invalid, which is what junk means here and what stops karaoke splitting from
      opening a syllable on it."
    aegisub: {
      {kind: "block-start"}
      {kind: "junk", text: "\\ k30"}
      {kind: "block-end"}
      {kind: "text", text: "space"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "space"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "space"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "transformHoldsInnerTags"
    input: "{\\t(0,500,\\frz30)}spin"
    why: "The dialects agree, against what reading Aegisub's splitter suggested. Aegisub gives \\t
      four typed parameters, the last a block, and parses the inner tag into it as \\frz with a
      parameter of '30'; libass recurses into the last argument to the same effect. This is why a
      token stream needs `children` at all, and the earlier reading that the inner tag stays opaque
      parameter text was wrong. The whole nested stream is kept, the timings before the inner tag
      included, so that emitting it reproduces `params`."
    -- `params` is the raw text after the name, where Aegisub holds four typed parameters here and
    -- reports the third as absent. The row is simpler than the parser on purpose.
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\frz30", children: {
        {kind: "junk", text: "0,500,"}
        {kind: "tag", name: "frz", params: "30"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "spin"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\frz30", children: {
        {kind: "junk", text: "0,500,"}
        {kind: "tag", name: "frz", params: "30"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "spin"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\frz30", children: {
        {kind: "junk", text: "0,500,"}
        {kind: "tag", name: "frz", params: "30"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "spin"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "fontEncodingInTransform"
    input: "{\\t(0,500,\\fe128)}text"
    why: "`\\fe` applies whole from the first frame in both renderers, interval or no interval, which is
      what lets the normalizer lift it out to stand before the transform. Settling that took a
      different line in each renderer, since libass spends the value on the bidi base direction alone
      and VSFilter puts it in the LOGFONT's charset: the charset cases move ink only in VSFilter and
      the bidi cases only in libass, so a single probe line would have reported the tag inert in
      whichever renderer it did not suit. Aegisub is derived, its splitter having no say in what a
      transform does with a tag."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\fe128", children: {
        {kind: "junk", text: "0,500,"}
        {kind: "tag", name: "fe", params: "128"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\fe128", children: {
        {kind: "junk", text: "0,500,"}
        {kind: "tag", name: "fe", params: "128"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\fe128", children: {
        {kind: "junk", text: "0,500,"}
        {kind: "tag", name: "fe", params: "128"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Derived, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "transformLastArgumentIsAlwaysTags"
    input: "{\\t(0,500\\fscx200)}text"
    why: "A transform's last comma-separated argument is the tag list, so what precedes it is one
      argument short of what the commas suggest: this is the acceleration form, `0` accelerating and
      `500\\fscx200` standing where the tags go. Both renderers draw it at full scale from the first
      frame, exactly as `\\t(0,\\fscx200)` does and unlike the three-argument `\\t(0,500,\\fscx200)`
      that climbs across its interval. This is why an emptied transform keeps its trailing comma:
      dropping it would move the author's numbers into the acceleration and tag-list slots."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500\\fscx200", children: {
        {kind: "junk", text: "0,500"}
        {kind: "tag", name: "fscx", params: "200"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500\\fscx200", children: {
        {kind: "junk", text: "0,500"}
        {kind: "tag", name: "fscx", params: "200"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500\\fscx200", children: {
        {kind: "junk", text: "0,500"}
        {kind: "tag", name: "fscx", params: "200"}
      }}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Derived, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "transformEmptiedOfItsTags"
    input: "{\\fe128\\t(0,500,)}text"
    why: "What the normalizer writes when the only tag a transform held applies whole and is lifted
      out. The transform stays, because both renderers switch collision detection off for any `\\t`
      at all: two lines that stack when neither carries one draw over each other when one does, and
      `\\t(0,500,)`, `\\t(0,500)` and `\\t()` are alike in that. The empty argument list holds no
      backslash, so nothing recurses and the tag keeps no children."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "fe", params: "128"}
      {kind: "tag", name: "t", params: "0,500,"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "fe", params: "128"}
      {kind: "tag", name: "t", params: "0,500,"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "fe", params: "128"}
      {kind: "tag", name: "t", params: "0,500,"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Derived, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "unclosedBraceIsText"
    input: "before {\\b1 after"
    why: "All three agree today, which is the correction this corpus exists to hold onto: Aegisub's
      source comment says libass treats an unclosed block as a block, and current libass guards on
      finding the closing brace and falls through to reading the character as text. Aegisub splits
      this into two plain blocks at the brace it rejected, which concatenate to the one text token."
    aegisub: {{kind: "text", text: "before {\\b1 after"}}
    libass: {{kind: "text", text: "before {\\b1 after"}}
    vsfilter: {{kind: "text", text: "before {\\b1 after"}}
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "blockWithoutBackslashIsComment"
    input: "{note}text"
    why: "Brace content holding no backslash. Aegisub builds a comment block, a type of its own that
      holds the braces with it; libass finds no tag and consumes the block. Neither renders it, so
      the visible outcome matches even though the token kinds differ."
    aegisub: {
      {kind: "block-start"}
      {kind: "comment", text: "note"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "junk", text: "note"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "junk", text: "note"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "escapedBrace"
    input: "a\\{b"
    why: "LIBASS ALONE, the one case where Aegisub is not the odd one out. libass reads \\{ as a
      literal brace while scanning text; neither of the others has escape handling in its block loop,
      so in both the backslash is ordinary text and the brace opens nothing here
      because no closing brace follows. That second clause is why this input cannot isolate escaping
      on its own, and escapedBraceClosed carries the discriminating form."
    -- Aegisub splits plain text at every brace it examines, so it yields two blocks here, 'a\\'
    -- and '{b', joined into the one run that renders
    aegisub: {{kind: "text", text: "a\\{b"}}
    libass: {{kind: "text", text: "a{b"}}
    vsfilter: {{kind: "text", text: "a\\{b"}}
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "escapedBraceClosed"
    input: "a\\{b}c"
    why: "The form that separates escape handling from the unclosed-brace rule, which escapedBrace
      confounds. With no escape, the brace opens a block that closes, so {b} is a comment and drops
      out of the rendered text; with one, all six characters render and the braces are literal.
      Aegisub gives the three blocks without an escape, keeping the backslash in the text."
    aegisub: {
      {kind: "text", text: "a\\"}
      {kind: "block-start"}
      {kind: "comment", text: "b"}
      {kind: "block-end"}
      {kind: "text", text: "c"}
    }
    libass: {{kind: "text", text: "a{b}c"}}
    vsfilter: {
      {kind: "text", text: "a\\"}
      {kind: "block-start"}
      {kind: "junk", text: "b"}
      {kind: "block-end"}
      {kind: "text", text: "c"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "escapedClosingBraceMidRun"
    input: "a\\}b"
    why: "The closing brace escapes exactly as the opening one does, and in the middle of a run rather
      than at the start of one, which is where a scan that only broke its text runs on `\\{` used to
      miss it. libass draws three glyphs here, the same width as `a}b`; xy-VSFilter draws four, the
      backslash and the brace both, which is the width of `a\\b` and `a}b` added over `ab`. Aegisub
      keeps the backslash too, and unlike with `\\{` it does not even split the run, since it splits
      only where a brace could open a block."
    aegisub: {{kind: "text", text: "a\\}b"}}
    libass: {{kind: "text", text: "a}b"}}
    vsfilter: {{kind: "text", text: "a\\}b"}}
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "whitespaceOnlyArgument"
    input: "{\\bord }X"
    why: "An argument of whitespace alone is no argument: both renderers draw this as the bare `\\bord`,
      restoring the style's outline rather than reading a zero, and Aegisub's parser reports the
      parameter with an empty value and writes the tag back as `\\bord`. The scan keeps the text as
      written, so `params` still holds the space and the round trip is unharmed; what changes is the
      typed argument, which comes back empty."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "bord", params: " "}
      {kind: "block-end"}
      {kind: "text", text: "X"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "bord", params: " "}
      {kind: "block-end"}
      {kind: "text", text: "X"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "bord", params: " "}
      {kind: "block-end"}
      {kind: "text", text: "X"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "nestedParenthesesCloseAtFirst"
    input: "{\\clip(m 0 0 l (1 1))}shape"
    why: "libass says in a comment that it stops at the first closing parenthesis to match VSFilter.
      Aegisub does not: it hands \\clip the whole of 'm 0 0 l (1 1)', inner parentheses and all, so
      nothing is left over inside the block. This input cannot tell balancing apart from the rule
      Aegisub actually applies, since both give that answer; `twoTransformsInOneBlock` is the case
      that separates them."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "clip", params: "m 0 0 l (1 1)"}
      {kind: "block-end"}
      {kind: "text", text: "shape"}
    }
    -- Neither implementation gives the leftover parenthesis a token of its own; both skip it while
    -- looking for the next backslash. It is emitted as junk anyway, because a stream that drops
    -- characters cannot rebuild the line, and junk is what says a run produced no tag.
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "clip", params: "m 0 0 l (1 1"}
      {kind: "junk", text: ")"}
      {kind: "block-end"}
      {kind: "text", text: "shape"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "clip", params: "m 0 0 l (1 1"}
      {kind: "junk", text: ")"}
      {kind: "block-end"}
      {kind: "text", text: "shape"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Derived, vsfilter: Provenance.Partial}
  }

  {
    name: "drawingMode"
    input: "{\\p1}m 0 0 l 100 0{\\p0}after"
    why: "Drawing mode is state that outlives the block that set it, so the text between the two
      blocks is a drawing rather than rendered text. Aegisub types that block as a drawing and stamps
      it with the scale in force, 1 here. libass renders it identically to the same path spelled with
      twice the characters, which only a parse into geometry can do. Whether the two dialects agree
      on where a drawing ends is untested."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "1"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0 l 100 0"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "0"}
      {kind: "block-end"}
      {kind: "text", text: "after"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "1"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0 l 100 0"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "0"}
      {kind: "block-end"}
      {kind: "text", text: "after"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "1"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0 l 100 0"}
      {kind: "block-start"}
      {kind: "tag", name: "p", params: "0"}
      {kind: "block-end"}
      {kind: "text", text: "after"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "emptyBlock"
    input: "{}text"
    why: "A block with nothing in it, which both consume without emitting a tag. Aegisub builds an
      override block holding zero tags, so the braces survive the parse even though the karaoke
      window shows them gone."
    aegisub: {
      {kind: "block-start"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "block-end"}
      {kind: "text", text: "text"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "karaokeAcrossSyllables"
    input: "{\\k20}ka{\\k30}ra{\\k25}o"
    why: "The shape parse_karaoke_data is built on, and the case that has to keep working whatever
      the dialects do elsewhere. Aegisub yields three syllables running 0-200, 200-500 and 500-750,
      each holding its own text with the karaoke tag consumed. libass is read at two timestamps, 150ms
      putting the first boundary past it and 250ms putting the second before it."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "20"}
      {kind: "block-end"}
      {kind: "text", text: "ka"}
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "ra"}
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "25"}
      {kind: "block-end"}
      {kind: "text", text: "o"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "20"}
      {kind: "block-end"}
      {kind: "text", text: "ka"}
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "ra"}
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "25"}
      {kind: "block-end"}
      {kind: "text", text: "o"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "20"}
      {kind: "block-end"}
      {kind: "text", text: "ka"}
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "30"}
      {kind: "block-end"}
      {kind: "text", text: "ra"}
      {kind: "block-start"}
      {kind: "tag", name: "k", params: "25"}
      {kind: "block-end"}
      {kind: "text", text: "o"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Partial}
  }

  {
    name: "twoTransformsInOneBlock"
    input: "{\\t(0,500,\\bord2)\\t(500,1000,\\bord0)}ab"
    why: "The case that settles how Aegisub delimits a parenthesized argument list, which
      `nestedParenthesesCloseAtFirst` cannot. A parenthesis suspends its tag splitting until the first
      `)` and the tag then runs on to the next backslash, so the second transform is a tag of its own
      rather than argument text of the first. Two transforms in one block is ordinary in a karaoke
      template, so a reading that swallowed the second would corrupt the lines people actually write."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\bord2", children: {{kind: "junk", text: "0,500,"}, {kind: "tag", name: "bord", params: "2"}}}
      {kind: "tag", name: "t", params: "500,1000,\\bord0", children: {{kind: "junk", text: "500,1000,"}, {kind: "tag", name: "bord", params: "0"}}}
      {kind: "block-end"}
      {kind: "text", text: "ab"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\bord2", children: {{kind: "junk", text: "0,500,"}, {kind: "tag", name: "bord", params: "2"}}}
      {kind: "tag", name: "t", params: "500,1000,\\bord0", children: {{kind: "junk", text: "500,1000,"}, {kind: "tag", name: "bord", params: "0"}}}
      {kind: "block-end"}
      {kind: "text", text: "ab"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\bord2", children: {{kind: "junk", text: "0,500,"}, {kind: "tag", name: "bord", params: "2"}}}
      {kind: "tag", name: "t", params: "500,1000,\\bord0", children: {{kind: "junk", text: "500,1000,"}, {kind: "tag", name: "bord", params: "0"}}}
      {kind: "block-end"}
      {kind: "text", text: "ab"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }

  {
    name: "tagAfterStrayTextInABlock"
    input: "{\\t(0,500,\\bord2)x\\shad3}ab"
    why: "DIVERGENCE. Aegisub resumes looking for a backslash once the parenthesis closes, so the
      stray character joins the tag it follows rather than standing alone, and `form.trailing` is
      where a scan keeps it. The renderers end the argument list at that parenthesis and leave the
      character as junk. All three read `\\shad3` either way, so nothing about what is drawn turns on
      it; what turns on it is which tag a tool rewriting one of them would disturb."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\bord2", children: {{kind: "junk", text: "0,500,"}, {kind: "tag", name: "bord", params: "2"}}, form: {parenthesized: true, argumentsClosed: true, trailing: "x"}}
      {kind: "tag", name: "shad", params: "3"}
      {kind: "block-end"}
      {kind: "text", text: "ab"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\bord2", children: {{kind: "junk", text: "0,500,"}, {kind: "tag", name: "bord", params: "2"}}}
      {kind: "junk", text: "x"}
      {kind: "tag", name: "shad", params: "3"}
      {kind: "block-end"}
      {kind: "text", text: "ab"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,500,\\bord2", children: {{kind: "junk", text: "0,500,"}, {kind: "tag", name: "bord", params: "2"}}}
      {kind: "junk", text: "x"}
      {kind: "tag", name: "shad", params: "3"}
      {kind: "block-end"}
      {kind: "text", text: "ab"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }
  {
    name: "nestedTransformClosingParenthesis"
    input: "{\\t(0,100,\\t(0,200,\\fad(0,500)\\p1))}m 0 0 l 100 0 l 100 100 l 0 100"
    why: "A transform holding another transform, where the inner one holds a parenthesized tag, so the
      first `)` can be read as closing the `\\fad` or as closing the outer argument list. Both renderers
      end the outer list at it, which leaves the inner transform and the `\\fad` unclosed and puts
      `\\p1))` at block level, where it opens a drawing. `\\p` cannot show that on its own, since a
      transform applies it too and a drawing renders under either reading; what settles it is a marker
      gated on time, `{\\t(0,100,\\t(5000,6000,\\fad(0,500)\\fscx200))}` scaling exactly as a
      block-level `\\fscx200))` does while the inner interval has not opened. Aegisub was asked through
      `ass_tag_dump` and nests and blocks it the same way, with `\\p` a sibling of the transform holding
      `1))`, but `GetText` streams the block back with a `)` the author never wrote. The shape occurs in
      39 scripts of the wild corpus."
    aegisub: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,100,\\t(0,200,\\fad(0,500", children: {
        {kind: "junk", text: "0,100,"}
        {kind: "tag", name: "t", params: "0,200,\\fad(0,500", children: {
          {kind: "junk", text: "0,200,"}
          {kind: "tag", name: "fad", params: "0,500", form: {parenthesized: true, argumentsClosed: false}}
        }, form: {parenthesized: true, argumentsClosed: false}}
      }, form: {parenthesized: true, argumentsClosed: true}}
      {kind: "tag", name: "p", params: "1))"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0 l 100 0 l 100 100 l 0 100"}
    }
    libass: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,100,\\t(0,200,\\fad(0,500", children: {
        {kind: "junk", text: "0,100,"}
        {kind: "tag", name: "t", params: "0,200,\\fad(0,500", children: {
          {kind: "junk", text: "0,200,"}
          {kind: "tag", name: "fad", params: "0,500", form: {parenthesized: true, argumentsClosed: false}}
        }, form: {parenthesized: true, argumentsClosed: false}}
      }, form: {parenthesized: true, argumentsClosed: true}}
      {kind: "tag", name: "p", params: "1))"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0 l 100 0 l 100 100 l 0 100"}
    }
    vsfilter: {
      {kind: "block-start"}
      {kind: "tag", name: "t", params: "0,100,\\t(0,200,\\fad(0,500", children: {
        {kind: "junk", text: "0,100,"}
        {kind: "tag", name: "t", params: "0,200,\\fad(0,500", children: {
          {kind: "junk", text: "0,200,"}
          {kind: "tag", name: "fad", params: "0,500", form: {parenthesized: true, argumentsClosed: false}}
        }, form: {parenthesized: true, argumentsClosed: false}}
      }, form: {parenthesized: true, argumentsClosed: true}}
      {kind: "tag", name: "p", params: "1))"}
      {kind: "block-end"}
      {kind: "drawing", text: "m 0 0 l 100 0 l 100 100 l 0 100"}
    }
    source: {aegisub: Provenance.Observed, libass: Provenance.Observed, vsfilter: Provenance.Observed}
  }
}
