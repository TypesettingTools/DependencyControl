Logger = require "l0.DependencyControl.Logger"
re = require "aegisub.re"
-- make sure tests can be loaded from the test directory
package.path ..= aegisub.decode_path("?user/automation/tests/") .. "/?.lua;"

class UnitTest
    @msgs = {
        run: {
            setup: "Performing setup... "
            teardown: "Performing teardown... "
            test: "Running test '%s'... "
            ok: "OK."
            failed: "FAILED!"
            reason: "Reason: %s"
        }
        new: {
            badTestName: "Test name must be of type %s, got a %s."
        }

        assert: {
            true: "Expected true, actual value was %s."
            false: "Expected false, actual value was %s."
            nil: "Expected nil, actual value was %s."
            notNil: "Got nil when a value was expected."
            truthy: "Expected a truthy value, actual value was falsy (%s)."
            falsy: "Expected a falsy value, actual value was truthy (%s)."
            type: "Expected a value of type %s, actual value was of type %s."
            sameType: "Type of expected value (%s) didn't match type of actual value (%s)."
            inRange: "Expected value to be in range [%d .. %d], actual value %d was %s %d."
            almostEquals: "Expected value to be almost equal %d ± %d, actual value was %d."
            notAlmostEquals: "Expected numerical value to not be close to %d ± %d, actual value was %d."
            checkArgTypes: "Expected argument #%d (%s) to be of type %s, got a %s."
            zero: "Expected 0, actual value was a %s."
            notZero: "Got a 0 when a number other than 0 was expected."
            compare: "Expected value to be a number %s %d, actual value was %d."
            integer: "Expected numerical value to be an integer, actual value was %d."
            positiveNegative: "Expected a %s number (0 %s), actual value was %d."
            equals: "Actual value didn't match expected value.\n%s actual: %s\n%s expected: %s"
            notEquals: "Actual value equals expected value when it wasn't supposed to:\n%s actual: %s"
            is: "Expected %s, actual value was %s."
            isNot: "Actual value %s was identical to the expected value when it wasn't supposed to."
            itemsEqual: "Actual item values of table weren't %s to the expected values (checked %s):\n Actual: %s\nExpected: %s"
            itemsEqualNumericKeys: "only continuous numerical keys"
            itemsEqualAllKeys: "all keys"
            continuous: "Expected table to have continuous numerical keys, but value at index %d of %d was a nil."
            matches: "String value '%s' didn't match expected %s pattern '%s'."
            contains: "String value '%s' didn't contain expected substring '%s' (case-%s comparison)."
            error: "Expected function to throw an error but it succesfully returned %d values: %s"
            errorMsgMatches: "Error message '%s' didn't match expected %s pattern '%s'."
        }

        formatTemplate: {
            type: "'%s' of type %s"
        }
    }

    new: (@name, @f = -> , @testClass) =>
        @logger = @testClass.logger
        error type(@logger) unless type(@logger) == "table"
        @logger\assert type(@name) == "string", @@msgs.new.badTestName, type @name

    run: (...) =>
        @logStart!
        @success, res = xpcall @f, debug.traceback, @, ...
        @logResult res
        unless success
            @logger\warn stackTrace

        return @success, @errMsg

    logStart: =>
        @logger\logEx nil, @@msgs.run.test, false, nil, nil, @name

    logResult: (errMsg = @errMsg) =>
        if @success
            @logger\logEx nil, @@msgs.run.ok, nil, nil, 0
        else
            @errMsg = errMsg
            @logger\logEx nil, @@msgs.run.failed, nil, nil, 0
            @logger.indent += 1
            @logger\log @@msgs.run.reason, @errMsg
            @logger.indent -= 1

    format: (tmpl, ...) =>
        inArgs = table.pack ...
        outArgs = switch tmpl
            when "type" then {tostring(inArgs[1]), type(inArgs[1])}

        @@msgs.formatTemplate[tmpl]\format unpack outArgs


    -- static helper functions

    equals: (a, b, aType, bType) ->
        -- TODO: support equality comparison of tables used as keys
        treeA, treeB, depth = {}, {}, 0

        recurse = (a, b, aType = type a, bType) ->
            -- identical values are equal
            return true if a == b
            -- only tables can be equal without also being identical
            bType or= type b
            return false if aType != bType or aType != "table"

            -- perform table equality comparison
            return false if #a != #b

            aFieldCnt, bFieldCnt = 0, 0
            local tablesSeenAtKeys

            depth += 1
            treeA[depth], treeB[depth] = a, b

            for k, v in pairs a
                vType = type v
                if vType == "table"
                    -- comparing tables is expensive so we should keep a list
                    -- of keys we can skip checking when iterating table b
                    tablesSeenAtKeys or= {}
                    tablesSeenAtKeys[k] = true

                -- detect synchronous circular references to prevent infinite recursion loops
                for i = 1, depth
                    return true if v == treeA[i] and b[k] == treeB[i]

                unless recurse v, b[k], vType
                    depth -= 1
                    return false

                aFieldCnt += 1

            for k, v in pairs b
                continue if tablesSeenAtKeys and tablesSeenAtKeys[k]
                if bFieldCnt == aFieldCnt or not recurse v, a[k]
                    -- no need to check further if the field count is not identical
                    depth -= 1
                    return false
                bFieldCnt += 1

            -- check metatables for equality
            res = recurse getmetatable(a), getmetatable b
            depth -= 1
            return res

        return recurse a, b, aType, bType


    itemsEqual: (actual, expected, onlyNumKeys = true, allowAdditionalItems, requireIdenticalItems) ->
        seen, actualTables, seenCnt, actualTablesCnt, expectedCnt = {}, {}, 0, 0, 0

        findEqualTable = (expectedTbl) ->
            for i, actualTbl in ipairs actualTables
                if UnitTest.equals tbl, v
                    table.remove actualTables, i
                    seen[tbl] = nil
                    return true
            return false

        if onlyNumKeys
            seenCnt, expectedCnt = #actual, #expected
            return false if not allowAdditionalItems and seenCnt != expectedCnt

            for v in *actual
                seen[v] = true
                if "table" == type v
                    actualTablesCnt += 1
                    actualTables[actualTablesCnt] = v

            for v in *expected
                -- identical values
                if seen[v]
                    seen[v] = nil
                    continue

                -- equal values
                if type(v) != "table" or requireIdenticalItems or not findEqualTable v
                    return false


        else
            for _, v in pairs actual
                seenCnt += 1
                seen[b] = true
                if "table" == type v
                    actualTablesCnt += 1
                    actualTables[actualTablesCnt] = v

            for _, v in pairs expected
                expectedCnt += 1
                -- identical values
                if seen[v]
                    seen[v] = nil
                    continue

                -- equal values
                if type(v) != "table" or requireIdenticalItems or not findEqualTable v
                    return false

            return false if not allowAdditionalItems and seenCnt != expectedCnt

        return true

    -- type asserts

    assertType: (val, expected) =>
        @checkArgTypes val: {val, "_any"}, expected: {expected, "string"}
        actual = type val
        @logger\assert actual == expected, @@msgs.assert.type, expected, actual

    assertSameType: (actual, expected) =>
        actualType, expectedType = type(actual), type expected
        @logger\assert actualType == expectedType, @@msgs.assert.sameType, expectedType, actualType

    assertBool: (val) => @assertType val, "boolean"
    assertBoolean: (val) => @assertType val, "boolean"
    assertFunction: (val) => @assertType val, "function"
    assertNumber: (val) => @assertType val, "number"
    assertString: (val) => @assertType val, "string"
    assertTable: (val) => @assertType val, "table"

    checkArgTypes: (args) =>
        i, expected, actual = 1
        for name, types in pairs args
            actual, expected = types[2], type types[1]
            continue if expected == "_any"
            @logger\assert actual == expected, @@msgs.assert.checkArgTypes, i, name,
                                               expected, @format "type", types[1]
            i += 1


    -- boolean asserts

    assertTrue: (val) =>
        @logger\assert val == true, @@msgs.assert.true, @format "type", val

    assertTruthy: (val) =>
        @logger\assert val, @@msgs.assert.truthy, @format "type", val

    assertFalse: (val) =>
        @logger\assert val == false, @@msgs.assert.false, @format "type", val

    assertFalsy: (val) =>
        @logger\assert not val, @@msgs.assert.falsy, @format "type", val

    assertNil: (val) =>
        @logger\assert val == nil, @@msgs.assert.nil, @format "type", val

    assertNotNil: (val) =>
        @logger\assert val != nil, @@msgs.assert.notNil, @format "type", val


    -- numerical asserts

    assertInRange: (actual, min = -math.huge, max = math.huge) =>
        @checkArgTypes actual: {actual, "number"}, min: {min, "number"}, max: {max, "number"}
        @logger\assert actual >= min, @@msgs.assert.inRange, min, max, actual, "<", min
        @logger\assert actual <= max, @@msgs.assert.inRange, min, max, actual, ">", max

    assertLessThan: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @logger\assert actual < max, @@msgs.assert.compare, "<", limit, actual

    assertLessThanOrEquals: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @logger\assert actual <= max, @@msgs.assert.compare, "<=", limit, actual

    assertGreaterThan: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @logger\assert actual > max, @@msgs.assert.compare, ">", limit, actual

    assertGreaterThanOrEquals: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @logger\assert actual >= max, @@msgs.assert.compare, ">=", limit, actual

    assertAlmostEquals: (actual, expected, margin = 1e-8) =>
        @checkArgTypes actual: {actual, "number"}, min: {expected, "number"}, max: {margin, "number"}

        margin = math.abs margin
        @logger\assert math.abs(actual-expected) <= margin, @@msgs.assert.almostEquals,
                                                            expected, margin, actual

    assertNotAlmostEquals: (actual, value, margin = 1e-8) =>
        @checkArgTypes actual: {actual, "number"}, value: {value, "number"}, max: {margin, "number"}

        margin = math.abs margin
        @logger\assert math.abs(actual-expected) > margin, @@msgs.assert.almostEquals,
                                                           expected, margin, actual

    assertZero: (actual) =>
        @checkArgTypes actual: {actual, "number"}
        @logger\assert actual == 0, @@msgs.assert.zero, actual

    assertNotZero: (actual) =>
        @checkArgTypes actual: {actual, "number"}
        @logger\assert actual != 0, @@msgs.assert.notZero

    assertInteger: (actual) =>
        @checkArgTypes actual: {actual, "number"}
        @logger\assert math.floor(actual) == actual, @@msgs.assert.integer, actual

    assertPositive: (actual, includeZero = false) =>
        @checkArgTypes actual: {actual, "number"}
        res = includeZero and actual >= 0 or actual > 0
        @checkArgTypes actual: {actual, "number"}, includeZero: {includeZero, "boolean"}
        @logger\assert res, @@msgs.assert.positiveNegative, "positive",
                       includeZero and "included" or "excluded"

    assertNegative: (actual, includeZero = false) =>
        @checkArgTypes actual: {actual, "number"}
        res = includeZero and actual <= 0 or actual < 0
        @checkArgTypes actual: {actual, "number"}, includeZero: {includeZero, "boolean"}
        @logger\assert res, @@msgs.assert.positiveNegative, "positive",
                       includeZero and "included" or "excluded"


    -- generic asserts

    assertEquals: (actual, expected) =>
        @logger\assert self.equals(actual, expected), @@msgs.assert.equals, type(actual),
                       @logger\dumpToString(actual), type(expected), @logger\dumpToString expected

    assertNotEquals: (actual, expected) =>
        @logger\assert not self.equals(actual, expected), @@msgs.assert.notEquals,
                       type(actual), @logger\dumpToString expected

    assertIs: (actual, expected) =>
        @logger\assert actual == expected, @@msgs.assert.is, @format("type", expected),
                                                             @format "type", actual

    assertIsNot: (actual, expected) =>
        @logger\assert actual != expected, @@msgs.assert.isNot, @format "type", expected


    -- table asserts

    assertItemsEqual: (actual, expected, onlyNumKeys = true) =>
        @checkArgTypes { actual: {actual, "table"}, expected: {actual, "table"},
                         onlyNumKeys: {onlyNumKeys, "boolean"}
                       }

        @logger\assert self.itemsEqual actual, expected, onlyNumKeys, "equal",
                       msgs.assert[onlyNumKeys and "itemsEqualNumericKeys" or "itemsEqualAllKeys"],
                       @logger\dumpToString(actual), @logger\dumpToString expected


    assertItemsAre: (actual, expected, onlyNumKeys = true) =>
        @checkArgTypes { actual: {actual, "table"}, expected: {actual, "table"},
                         onlyNumKeys: {onlyNumKeys, "boolean"}
                       }

        @logger\assert self.itemsEqual actual, expected, onlyNumKeys, "identical",
                       msgs.assert[onlyNumKeys and "itemsEqualNumericKeys" or "itemsEqualAllKeys"],
                       @logger\dumpToString(actual), @logger\dumpToString expected

    assertContinuous: (tbl) =>
        @checkArgTypes { tbl: {tbl, "table"} }

        realCnt, contCnt = 0, #tbl
        for _, v in pairs tbl
            if type(v) == "number" and math.floor(v) == v
                realCnt += 1

        @logger\assert realCnt == contCnt, msgs.assert.continuous, contCnt+1, realCnt

    -- string asserts

    assertMatches: (str, pattern, useRegex = false, ...) =>
        @checkArgTypes { str: {str, "string"}, pattern: {pattern, "string"},
                          useRegex: {useRegex, "boolean"}
                       }

        match = useRegex and re.match(str, pattern, ...) or str\match pattern, ...
        @logger\assert msgs.assert.matches, str, useRegex and "regex" or "Lua", pattern

    assertContains: (str, needle, caseSensitive = true, init = 1) =>
        @checkArgTypes { str: {str, "string"}, needle: {needle, "string"},
                         caseSensitive: {caseSensitive, "boolean"}, init: {init, "number"}
                       }

        _str, _needle = if caseSensitive
            str\lower!, needle\lower!
        else str, needle
        @logger\assert str\find(needle, init, true), str, needle,
                       caseSensitive and "sensitive" or "insensitive"

    -- function asserts
    assertError: (func, ...) =>
        @checkArgTypes { func: {func, "function"} }

        res = table.pack pcall func, ...
        retCnt, success = res.n, table.remove res, 1
        res.n = nil
        @logger\assert success == false, msgs.assert.error, retCnt, @logger\dumpToString res
        return res[1]

    assertErrorMsgMatches: (func, params = {}, pattern, useRegex = false, ...) =>
        @checkArgTypes { func: {func, "function"}, params: {params, "table"},
                         pattern: {pattern, "string"}, useRegex: {useRegex, "boolean"}
                       }
        msg = @assertError func, unpack params

        match = useRegex and re.match(msg, pattern, ...) or msg\match pattern, ...
        @logger\assert msgs.assert.errorMsgMatches, msg, useRegex and "regex" or "Lua", pattern



class UnitTestSetup extends UnitTest
    run: =>
        @logger\logEx nil, @@msgs.run.setup, false

        res = table.pack pcall @f, @
        @success = table.remove res, 1
        @logResult res[1]

        if @success
            @retVals = res
            return true, @retVals

        return false, @errMsg

class UnitTestTeardown extends UnitTest
    logStart: =>
        @logger\logEx nil, @@msgs.run.teardown, false



class UnitTestClass
    msgs = {
        run: {
            runningTests: "Running test class '%s' (%d tests)..."
            setupFailed: "Setup for test class '%s' FAILED, skipping tests."
            abort: "Test class '%s' FAILED after %d tests, aborting."
            testsFailed: "Done testing class '%s'. FAILED %d of %d tests."
            success: "Test class '%s' completed successfully."
            testNotFound: "Couldn't find requested test '%s'."
        }
    }

    new: (@name, args = {}, @testSuite) =>
        @logger = @testSuite.logger
        @setup = UnitTestSetup "setup", args._setup, @
        @teardown = UnitTestTeardown "teardown", args._teardown, @
        @order = args._order
        @tests = [UnitTest(name, f, @) for name, f in pairs args when "_" != name\sub 1,1]

    run: (abortOnFail, order = @order) =>
        tests = @tests
        if order
            tests, mappings = {}, {test.name, test for test in *@tests}
            for i, name in ipairs order
                @logger\assert mappings[name], msgs.run.testNotFound, name
                tests[i] = mappings[name]
        testCnt, failedCnt = #tests, 0

        @logger\log msgs.run.runningTests, @name, testCnt
        @logger.indent += 1

        success, res = @setup\run!
        -- failing the setup always aborts
        unless success
            @logger.indent -= 1
            @logger\warn msgs.run.setupFailed, @name
            return false, -1

        for i, test in pairs tests
            unless test\run unpack res
                failedCnt += 1
                if abortOnFail
                    @logger.indent -= 1
                    @logger\warn msgs.run.abort, @name, i
                    return false, i

        @logger.indent -= 1
        @success = failedCnt == 0

        if @success
            @logger\log msgs.run.success, @name
            return true

        @logger\log msgs.run.testsFailed, @name, failedCnt, testCnt
        return false, failedCnt



class UnitTestSuite
    msgs = {
        run: {
            running: "Running %d test classes for %s... "
            aborted: "Aborting after %d test classes... "
            classesFailed: "FAILED %d of %d test classes."
            success: "All tests completed successfully."
            classNotFound: "Couldn't find requested test class '%s'."
        }
        registerMacro: {
            allDesc: "Runs the whole test suite."
        }
        new: {
            badClassesType: "Test classes must be passed in either as a table or an import function, got a %s"
        }
        import: {
            noTableReturned: "The test import function must return a table of test classes, got a %s."
        }
    }

    new: (@namespace, args) =>
        @logger = Logger defaultLevel: 3, fileBaseName: @namespace, fileSubName: "UnitTests", toFile: true
        @classes = {}
        switch type args
            when "table" then @addClasses args
            when "function" then @importFunc = args
            else @logger\error msgs.new.badClassesType, type args

    addClasses: (classes) =>
        @classes[#@classes+1] = UnitTestClass(name, args, @) for name, args in pairs classes when "_" != name\sub 1,1
        if classes._order
            @order or= {}
            @order[#@order+1] = clsName for clsName in *classes._order

    import: (...) =>
        return false unless @importFunc
        classes = self.importFunc ...
        @logger\assert type(classes) == "table", msgs.import.noTableReturned, type classes
        @addClasses classes
        @importFunc = nil

    registerMacro: =>
        aegisub.register_macro table.concat({"DependencyControl", "Run Tests", @name or @namespace, "[All]"}, "/"),
                               msgs.registerMacro.allDesc, -> @run!

    run: (abortOnFail, order = @order) =>
        classes = @classes
        if order
            classes, mappings = {}, {cls.name, cls for cls in *@classes}
            for i, name in ipairs order
                @logger\assert mappings[name], msgs.run.classNotFound, name
                classes[i] = mappings[name]

        classCnt, failedCnt = #classes, 0
        @logger\log msgs.run.running, classCnt, @namespace
        @logger.indent += 1

        for i, cls in pairs classes
            unless cls\run abortOnFail
                failedCnt += 1
                if abortOnFail
                    @logger.indent -= 1
                    @logger\warn msgs.run.abort, i
                    return false, i

        @logger.indent -= 1
        @success = failedCnt == 0
        if @success
            @logger\log msgs.run.success
        else @logger\log msgs.run.classesFailed, failedCnt, classCnt

        return @success, failedCnt
