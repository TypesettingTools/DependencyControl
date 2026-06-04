ffi = require "ffi"

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

--- Shared constants, enums, and terminology used across DependencyControl modules.
-- @class DependencyControlCommon
class DependencyControlCommon
    msgs = {
        validateNamespace: {
            badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        }
    }
    -- Some terms are shared across components
    @platform = "#{ffi.os}-#{ffi.arch}"

    @moduleName = "l0.DependencyControl"

    @terms = {
        scriptType: {
            singular: { "automation script", "module" }
            plural: { "automation scripts", "modules" }
        }

        isInstall: {
            [true]: "installation"
            [false]: "update"
        }

        capitalize: (str) -> (str\sub 1, 1)\upper! .. str\sub 2
    }

    -- Common enums
    @RecordType = {
        Managed: 1
        Unmanaged: 2
    }

    @ScriptType = {
        Automation: 1
        Module: 2
        name: {
            legacy: { "macros", "modules" }
            canonical: {"automation", "modules"}
        }
    }

    --- Validates a DependencyControl namespace string.
    -- @param namespace string
    -- @return boolean|nil
    -- @return string|nil err
    @validateNamespace = (namespace) ->
        segments = [seg for seg in namespace\gmatch "[^%.]+"]
        _, dotCount = namespace\gsub "%.", ""
        if #segments >= 2 and dotCount == #segments - 1 and not namespace\match "[^-._%w]"
            return true
        return false, msgs.validateNamespace.badNamespace\format namespace

    automationDir: {
        aegisub.decode_path("?user/automation/autoload"),
        aegisub.decode_path("?user/automation/include")
    }

    @testDir = {aegisub.decode_path("?user/automation/tests/DepUnit/macros"),
                aegisub.decode_path("?user/automation/tests/DepUnit/modules")}

    --- Resolves the install path of a packaged file from its owning script's namespace,
    -- mirroring the layout the Updater installs into: automation scripts go to the
    -- autoload dir, modules to the include dir (under their namespace path), and test
    -- files to the matching DepUnit test dir.
    -- @param namespace string
    -- @param scriptType number a ScriptType value
    -- @param fileName string the file's feed name (e.g. ".moon", "/Common.moon")
    -- @param[opt="script"] fileType string "script" or "test"
    -- @return string path
    @getFileDeployPath = (namespace, scriptType, fileName, fileType = "script") =>
        subDir = scriptType == @ScriptType.Module and (namespace\gsub "%.", "/") or namespace
        baseDir = fileType == "test" and @testDir[scriptType] or @automationDir[scriptType]
        return "#{baseDir}/#{subDir}#{fileName}"

    --- Deep equality comparison. Tables compared recursively; other types use ==.
    -- Circular references are handled. Metatables are included in the comparison.
    -- @static
    -- @param a
    -- @param b
    -- @treturn boolean
    @equals = _equals

    --- Compares table items for equality, ignoring keys.
    -- By default only numerical indexes are compared.
    -- @static
    -- @tparam table a
    -- @tparam table b
    -- @tparam[opt=true] boolean onlyNumKeys
    -- @tparam[opt=false] boolean ignoreExtraAItems
    -- @tparam[opt=false] boolean requireIdenticalItems
    -- @treturn boolean
    @itemsEqual = _itemsEqual

    --- Shallow-copies a table (no metatable).
    -- @static
    -- @param tbl table the table to copy
    -- @return table the copied table
    @copy = (tbl) -> {k, v for k, v in pairs tbl}

    --- Deep-copies a table recursively (no metatables).
    -- @param tbl table the table to deep copy
    -- @return table the deep-copied table
    deepCopy = (tbl) -> {k, (type(v) == "table" and deepCopy(v) or v) for k, v in pairs tbl}
    
    --- Deep-copies a table recursively (no metatables).
    -- @static
    -- @param tbl table the table to deep copy
    -- @return table the deep-copied table
    @deepCopy = deepCopy
