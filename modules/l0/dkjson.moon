-- DependencyControl wrapper around the vendored upstream dkjson.
--
-- The upstream library is kept pristine and unmodified at `modules/l0/dkjson/vendor/dkjson.lua`
-- so it can be updated by dropping in a new copy. The wrapper is a thin overlay that only
-- carries a DependencyControl version record, adds a Prettier-flavored `indentMode` encode option,
-- and defers everything else to the upstream module.
--
-- Resolving the bare module specifiers this module `provides` ("json", "dkjson") is
-- handled by DependencyControl's module searcher. Locally installed copies of dkjson,
-- luajson or any other JSON module will take precedence over this one if imported
-- via bare specifier.

dkjson = require "l0.dkjson.vendor.dkjson"

DEFAULT_PRETTIER_PRINT_WIDTH = 80

-- Serializes a Lua value to Prettier-flavored JSON: two-space indents, a space after every colon,
-- one property per line for objects, and arrays kept on a single line when they fit within
-- the print width (otherwise one element per line). Object keys listed in `state.keyorder` are
-- emitted first in that order; any remaining keys follow `state.defaultKeyOrder` (case-insensitive
-- alphabetical by default), so the output is fully deterministic. Scalars and the null sentinel are
-- delegated to upstream dkjson for correct escaping.
prettyEncode = (value, state = {}) ->
    keyorder = state.keyorder or {}
    printWidth = state.indentPrintWidth or DEFAULT_PRETTIER_PRINT_WIDTH
    defaultKeySorter = (a, b) -> string.lower(tostring a) < string.lower tostring b
    defaultKeySorter = state.defaultKeyOrder if type(state.defaultKeyOrder) == "function"

    rank = {k, i for i, k in ipairs keyorder}
    indentStr = (level) -> ("  ")\rep level

    -- Classifies a table as a JSON "array" or "object", honoring dkjson's decode-time __jsontype
    -- tag and otherwise falling back to a key-shape heuristic (empty tables become objects).
    classify = (tbl, meta) ->
        return meta.__jsontype if meta and meta.__jsontype
        len, count = #tbl, 0
        count += 1 for _ in pairs tbl
        return len > 0 and len == count and "array" or "object"

    -- Object keys ordered by `keyorder` rank first, then alphabetically.
    orderedKeys = (tbl) ->
        keys = [k for k in pairs tbl]
        table.sort keys, (a, b) ->
            ra, rb = rank[a], rank[b]
            return ra < rb if ra and rb
            return ra != nil if ra or rb
            defaultKeySorter a, b
        keys

    local compact, forcesBreak, render

    -- Single-line rendering, used only to measure whether an array fits on the current line.
    compact = (val) ->
        meta = getmetatable val
        return dkjson.encode val if type(val) != "table" or (meta and meta.__tojson)
        if classify(val, meta) == "array"
            "[#{table.concat [compact v for v in *val], ", "}]"
        else
            "{#{table.concat ["#{dkjson.encode k}: #{compact val[k]}" for k in *orderedKeys val], ", "}}"

    -- Whether a value must span multiple lines regardless of width: non-empty objects always break,
    -- and an array breaks if any of its elements does.
    forcesBreak = (val) ->
        meta = getmetatable val
        return false if type(val) != "table" or (meta and meta.__tojson)
        if classify(val, meta) == "array"
            for v in *val
                return true if forcesBreak v
            false
        else next(val) != nil

    -- Full rendering. `col` is the column the value begins at, used to decide whether an array
    -- still fits on the current line.
    render = (val, col, level) ->
        meta = getmetatable val
        return dkjson.encode val if type(val) != "table" or (meta and meta.__tojson)

        if classify(val, meta) == "array"
            return "[]" if #val == 0
            unless forcesBreak val
                inline = compact val
                return inline if col + #inline <= printWidth
            inner = indentStr level + 1
            "[\n#{table.concat ["#{inner}#{render v, (level + 1) * 2, level + 1}" for v in *val], ",\n"}\n#{indentStr level}]"
        else
            keys = orderedKeys val
            return "{}" if #keys == 0
            inner = indentStr level + 1
            parts = for k in *keys
                key = dkjson.encode k
                "#{inner}#{key}: #{render val[k], #inner + #key + 2, level + 1}"
            "{\n#{table.concat parts, ",\n"}\n#{indentStr level}}"

    render value, 0, 0

wrapper = setmetatable {}, __index: dkjson

---Encodes a Lua value as JSON.
---The DependencyControl-bundled package adds the following state options on top of upstream dkjson:
---- `state.indentMode`: when set to 'prettier', formatting matches Prettier (two-space indents, a space
---  after each colon, objects one-property-per-line, arrays collapsed when they fit within the configured
---  print width).
---- `state.indentPrintWidth`: the target line width for the 'prettier' indent mode (default: 80).
---- `state.defaultKeyOrder`: a function that accepts two keys and returns true if the first should appear
---  before the second when encoding objects, and false otherwise. Used to sort object keys not present in
---  `state.keyorder` (which takes precedence). Default is case-insensitive alphabetical, and currently only
---  applies in the 'prettier' indent mode.
---Any other `indentMode` (or none) defers entirely to upstream dkjson.
---@param value any The value to encode.
---@param state? table dkjson encode state, optionally carrying `indentMode`/`keyorder`.
---@return string|boolean json The JSON string, or dkjson's native return value for non-prettier modes.
wrapper.encode = (value, state) ->
    return prettyEncode value, state if state and state.indentMode == "prettier"
    return dkjson.encode value, state

wrapper.__depCtrlInit = (DependencyControl) ->
    wrapper.version = DependencyControl {
        name: "dkjson"
        version: "2.10.0"
        description: "David Kolf's JSON module for Lua."
        author: "David Kolf"
        moduleName: "l0.dkjson"
        url: "http://dkolf.de/dkjson-lua/"
        feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/DependencyControl.json"
        provides: {"json", "dkjson"}
    }

return wrapper
