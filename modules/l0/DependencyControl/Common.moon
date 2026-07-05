ffi = require "ffi"
Crypto = require "l0.DependencyControl.Crypto"
Enum = require "l0.DependencyControl.Enum"
constants = require "l0.DependencyControl.Constants"

---Serializes a value into a canonical string for hashing: table keys are emitted in sorted
---order so field ordering never affects the result, and every value is tagged with its type
---so distinct types can't collide (e.g. the number 1 vs. the string "1").
---@param value any The value to canonicalize.
---@return string canonical The canonicalized string.
canonicalize = (value) ->
    switch type value
        when "table"
            entries = {}
            entries[#entries + 1] = "#{canonicalize k}=#{canonicalize v}" for k, v in pairs value
            table.sort entries
            "{#{table.concat entries, ","}}"
        when "string" then "s:#{value}"
        when "number" then "n:#{string.format "%.17g", value}"
        when "boolean" then "b:#{value and 1 or 0}"
        when "nil" then "nil"
        else "#{type value}:#{tostring value}"

-- Compares two values for deep equality. Tables are compared recursively;
-- other types use == except that two identical values always compare equal.
-- Circular references are handled.
_equals = (a, b, aType, bType) ->
    treeA, treeB, depth = {}, {}, 0

    recurse = (a, b, aType = type a, bType) ->
        return true if a == b
        bType or= type b
        return false if aType != bType or aType != "table"

        return false if #a != #b

        aFieldCnt, bFieldCnt = 0, 0
        local tablesSeenAtKeys

        depth += 1
        treeA[depth], treeB[depth] = a, b

        for k, v in pairs a
            vType = type v
            if vType == "table"
                tablesSeenAtKeys or= {}
                tablesSeenAtKeys[k] = true

            for i = 1, depth
                return true if v == treeA[i] and b[k] == treeB[i]

            unless recurse v, b[k], vType
                depth -= 1
                return false

            aFieldCnt += 1

        for k, v in pairs b
            continue if tablesSeenAtKeys and tablesSeenAtKeys[k]
            if bFieldCnt == aFieldCnt or not recurse v, a[k]
                depth -= 1
                return false
            bFieldCnt += 1

        res = recurse getmetatable(a), getmetatable b
        depth -= 1
        return res

    return recurse a, b, aType, bType

-- Compares table items for equality ignoring keys.
-- Delegates table-vs-table comparisons to _equals.
_itemsEqual = (a, b, onlyNumKeys = true, ignoreExtraAItems, requireIdenticalItems) ->
    seen, aTbls = {}, {}
    aCnt, aTblCnt, bCnt = 0, 0, 0

    findEqualTable = (bTbl) ->
        for i, aTbl in ipairs aTbls
            if _equals aTbl, bTbl
                table.remove aTbls, i
                seen[aTbl] = nil
                return true
        return false

    if onlyNumKeys
        aCnt, bCnt = #a, #b
        return false if not ignoreExtraAItems and aCnt != bCnt

        for v in *a
            seen[v] = true
            if "table" == type v
                aTblCnt += 1
                aTbls[aTblCnt] = v

        for v in *b
            if seen[v]
                seen[v] = nil
                continue

            if type(v) != "table" or requireIdenticalItems or not findEqualTable v
                return false

    else
        for _, v in pairs a
            aCnt += 1
            seen[v] = true
            if "table" == type v
                aTblCnt += 1
                aTbls[aTblCnt] = v

        for _, v in pairs b
            bCnt += 1
            if seen[v]
                seen[v] = nil
                continue

            if type(v) != "table" or requireIdenticalItems or not findEqualTable v
                return false

        return false if not ignoreExtraAItems and aCnt != bCnt

    return true


getTableLength = (tbl) ->
    n = 0
    n += 1 for _, _ in pairs tbl
    return n

isPureArrayTable = (tbl) ->
    typ = type tbl
    return false, nil, typ if typ != "table"
    len = getTableLength tbl
    return #tbl == len, len, typ

---Flattens nested array tables into a single array up to the specified depth. Values that are not (or not converted to) pure array tables are included as-is.
---@param value any The value to flatten.
---@param depth? number Maximum depth to flatten (default 1).
---@param toArrayTable? fun(value: any, valueType: string): table?, boolean? Converts a non-array value to an array table.
---@return table flattened A flattened array table containing the flattened values.
---@return number flattenedCount The number of elements in the flattened array.
flatten = (value, depth = 1, toArrayTable) ->
    flattened, f = {}, 0

    recurse = (v, d) ->
        isArray, _, typ = isPureArrayTable v
        if toArrayTable and not isArray
            v, isArray = toArrayTable v, typ
            isArray = isPureArrayTable(v) if isArray == nil
        if isArray and d > 0
            recurse nestedVal, d - 1 for nestedVal in *v
        else
            f += 1
            flattened[f] = v

    recurse value, depth
    return flattened, f


---Shared constants, enums, and terminology used across DependencyControl modules.
---@class DependencyControlCommon
class DependencyControlCommon
    msgs = {
        validateNamespace: {
            badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        }
    }
    -- Some terms are shared across components
    @platform = "#{ffi.os}-#{ffi.arch}"

    @moduleName = "l0.DependencyControl"

    ---@alias RecordType
    ---| "managed" # Managed: a script/module DependencyControl installs and keeps up to date
    ---| "unmanaged" # Unmanaged: a record describing a module DependencyControl tracks but does not update
    RecordType = Enum "RecordType", {
        Managed: "managed"
        Unmanaged: "unmanaged"
    }
    @RecordType = RecordType

    ---@alias ScriptType
    ---| "automation" # Automation: an automation script (macro / applied filter)
    ---| "module" # Module: a require()-able module
    ScriptType = Enum "ScriptType", {
        Automation: "automation"
        Module: "module"
    }
    @ScriptType = ScriptType

    ---@alias ScriptTypeSection
    ---| "macros" # Automation scripts are stored in the "macros" section
    ---| "modules" # Modules are stored in the "modules" section
    ---Per-script type property names used in update feed data and config files.
    @ScriptTypeSection = Enum "ScriptTypeSection", {
        [ScriptType.Automation]: "macros"
        [ScriptType.Module]: "modules"
    }

    @terms = {
        scriptType: {
            singular: {
                [ScriptType.Automation]: "automation script"
                [ScriptType.Module]: "module"
            }
            plural: {
                [ScriptType.Automation]: "automation scripts"
                [ScriptType.Module]: "modules"
            }
        }

        isInstall: {
            [true]: "installation"
            [false]: "update"
        }

        capitalize: (str) -> (str\sub 1, 1)\upper! .. str\sub 2
    }

    ---Validates a DependencyControl namespace string.
    ---@param namespace string
    ---@return boolean? valid True when the namespace is well-formed.
    ---@return string? err Validation error message when invalid.
    @validateNamespace = (namespace) ->
        segments = [seg for seg in namespace\gmatch "[^%.]+"]
        _, dotCount = namespace\gsub "%.", ""
        if #segments >= 2 and dotCount == #segments - 1 and not namespace\match "[^-._%w]"
            return true
        return false, msgs.validateNamespace.badNamespace\format namespace

    @getAutomationDir: (scriptType, rootDir = "?user") =>
        switch scriptType
            when @ScriptType.Automation then aegisub.decode_path("#{rootDir}/automation/autoload")
            when @ScriptType.Module then aegisub.decode_path("#{rootDir}/automation/include")
            else nil
        
    @getTestDir = (scriptType, rootDir = "?user") =>
        switch scriptType
            when @ScriptType.Automation then aegisub.decode_path("#{rootDir}/automation/tests/DepUnit/macros")
            when @ScriptType.Module then aegisub.decode_path("#{rootDir}/automation/tests/DepUnit/modules")
            else nil

    ---Whether DependencyControl is running headless — outside a real Aegisub session, on the Aegisub
    ---shims (the CLI and unit test runner). Lets a script skip Aegisub-session-only startup work.
    ---@return boolean headless
    @isHeadless = -> aegisub[constants.DEPCTRL_PRIVATE_GLOBAL_VAR_PREFIX] != nil


    ---Deep equality comparison. Tables compared recursively; other types use ==.
    ---Circular references are handled. Metatables are included in the comparison.
    ---@param a any
    ---@param b any
    ---@return boolean equal
    @equals = _equals

    ---Compares table items for equality, ignoring keys.
    ---By default only numerical indexes are compared.
    ---@param a table
    ---@param b table
    ---@param onlyNumKeys? boolean Compare only sequential numeric indices (default true).
    ---@param ignoreExtraAItems? boolean Allow `a` to contain items absent from `b` (default false).
    ---@param requireIdenticalItems? boolean Require identical (not merely equal) table items (default false).
    ---@return boolean equal
    @itemsEqual = _itemsEqual

    ---Shallow-copies a table (no metatable).
    ---@param tbl table The table to copy.
    ---@return table copy The copied table.
    @copy = (tbl) -> {k, v for k, v in pairs tbl}

    ---Deep-copies a table recursively (no metatables).
    ---@param tbl table The table to deep-copy.
    ---@return table copy The deep-copied table.
    deepCopy = (tbl) -> {k, (type(v) == "table" and deepCopy(v) or v) for k, v in pairs tbl}

    ---Deep-copies a table recursively (no metatables).
    ---@param tbl table The table to deep-copy.
    ---@return table copy The deep-copied table.
    @deepCopy = deepCopy

    ---Builds (or extends) a set from an array's values: each value becomes a key mapped to `value`.
    ---@param source any[] Array whose values become the set's keys.
    ---@param target? table Table to populate (default a new table).
    ---@param overwrite? boolean Overwrite keys already present in `target` (default true).
    ---@param value? any Value to map each key to (default true).
    ---@return table set The populated `target`.
    @makeSet = (source, target = {}, overwrite = true, value = true) ->
        target[v] = value for v in *source when overwrite or not target[v]
        return target

    ---Reports whether an array contains a value (compared with `==`).
    ---@param list any[] The array to search.
    ---@param value any The value to look for.
    ---@return boolean included Whether `value` is an element of `list`.
    @listIncludes = (list, value) ->
        for entry in *list
            return true if entry == value
        return false

    ---Fills in missing entries of `tbl` from `defaults`, mutating `tbl` in place.
    ---@param tbl table The table to fill in.
    ---@param defaults table Default key/value pairs.
    ---@param predicate? fun(value: any, key: any, tbl: table): boolean Per-key test for whether to apply the default; when omitted, defaults apply wherever `tbl[key]` is nil.
    ---@return number addedCount The number of defaults applied.
    @addDefaults = (tbl, defaults, predicate) ->
        addedCnt = 0
        for k, v in pairs defaults
            if not predicate and tbl[k] == nil or predicate and predicate tbl[k], k, tbl
                addedCnt += 1
                tbl[k] = v
        return addedCnt

    ---Strips leading and trailing whitespace from a string.
    ---@param str string The string to trim.
    ---@return string trimmed The trimmed string.
    @trim = (str) -> (str\gsub "^%s*(.-)%s*$", "%1")

    ---Flattens nested array tables into a single array up to the specified depth. Values that are not (or not converted to) pure array tables are included as-is.
    ---@param value any The value to flatten.
    ---@param depth? number Maximum depth to flatten (default 1).
    ---@param toArrayTable? fun(value: any, valueType: string): table?, boolean? Converts a non-array value to an array table.
    ---@return table flattened A flattened array table containing the flattened values.
    ---@return number flattenedCount The number of elements in the flattened array.
    @flatten = flatten

    ---Produces a deterministic SHA-1 hash of a (possibly nested) Lua value.
    ---Table keys are sorted before hashing, so field ordering never affects the result; pass an
    ---object pruned to just the fields you care about to obtain a stable content signature that
    ---ignores irrelevant differences. Useful for cheaply detecting whether semantic content changed.
    ---@param value any The value to hash.
    ---@return string hash A 40-character lowercase SHA-1 hex digest.
    @getObjectHash = (value) -> Crypto.sha1 canonicalize value

    ---Generates a random RFC-4122 version-4 UUID string.
    ---@return string uuid
    @uuid = ->
        -- https://gist.github.com/jrus/3197011
        "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"\gsub "[xy]", (c) ->
            v = c == "x" and math.random(0, 0xf) or math.random 8, 0xb
            return "%x"\format v
