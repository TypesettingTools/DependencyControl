-- cspell:ignore macrotoo furi -- karaskel's own parameter and function-name spellings

-- The vendored upstream file is kept pristine at `vendor/karaskel-auto4.lua` (including its UTF-8 BOM) and was taken from Aegisub
-- at commit 2fd5cc2634be1e2ba8fbfb354a6f979ad042f10a (2026-01-30, first shipped with 3.5.0-beta).
-- The last non-cosmetic change was in 2015, so the file is not expected to change anytime soon.

includeShim = require "l0.AegisubShims.include"

-- karaskel-auto4.lua calls include() while it loads, and publishes itself as a global rather than
-- returning, so the global has to be in place before the file runs.
_G.include or= includeShim.include
require "l0.AegisubShims.vendor.karaskel-auto4"

---Aegisub's karaoke skeleton, which turns a subtitle line into styled, positioned syllables. Every
---function takes the `meta` and `styles` tables `collect_head` produced, and mutates the line it is
---given rather than returning a new one.
---@class AegisubKaraskel
---@field collect_head fun(subs: table, generate_furigana?: boolean): table, table Reads the script's metadata and styles, returning both.
---@field preproc_line fun(subs: table, meta: table, styles: table, line: AegisubDialogueLine) Runs the text, size and position passes over one line.
---@field preproc_line_text fun(meta: table, styles: table, line: AegisubDialogueLine) Splits the line into syllables and furigana.
---@field preproc_line_size fun(meta: table, styles: table, line: AegisubDialogueLine) Measures the line and each syllable, needing a text-extents backend.
---@field preproc_line_pos fun(meta: table, styles: table, line: AegisubDialogueLine) Lays out syllable positions from those measurements.
---@field do_basic_layout fun(meta: table, styles: table, line: AegisubDialogueLine) Positions syllables side by side.
---@field do_furigana_layout fun(meta: table, styles: table, line: AegisubDialogueLine) Positions furigana over the syllables they annotate.
---@field use_fx_library fun(macrotoo?: boolean) Registers the fx-library skeleton as a filter, and as a macro when asked.
---@field use_fx_library_furi fun(use_furigana?: boolean, macrotoo?: boolean) The same, with furigana layout.
---@field use_classic_adv fun(use_furigana?: boolean, macrotoo?: boolean) Registers the classic_adv skeleton.
return _G.karaskel
