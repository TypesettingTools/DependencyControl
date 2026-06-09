
Logger = require "l0.DependencyControl.Logger"
Common = require "l0.DependencyControl.Common"
Stub   = require "l0.DependencyControl.Stub"
DependencyControl = nil

package.path ..= "#{package.path\sub(-1) == ";" and "" or ";"}#{aegisub.decode_path "?user/automation/tests"}/?.lua;"

--- A class for all single unit tests.
-- Provides useful assertion and logging methods for a user-specified test function.
-- @classmod UnitTest
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
            error: "Expected function to throw an error but it successfully returned %d values: %s"
            errorMsgMatches: "Error message '%s' didn't match expected %s pattern '%s'."
        }

        formatTemplate: {
            type: "'%s' of type %s"
        }

    }

    --- Creates a single unit test.
    -- Instead of calling this constructor you'd usually provide test data
    -- in a table structure to @{UnitTestSuite:new} as an argument.
    -- @tparam string name a descriptive title for the test
    -- @tparam function(UnitTest, ...) testFunc the function containing the test code
    -- @tparam UnitTestClass testClass the test class this test belongs to
    -- @treturn UnitTest the unit test
    -- @see UnitTestSuite:new
    new: (@name, @f = -> , @testClass) =>
        @logger = @testClass.logger
        error type(@logger) unless type(@logger) == "table"
        @logger\assert type(@name) == "string", @@msgs.new.badTestName, type @name

    --- Runs the unit test function.
    -- In addition to the @{UnitTest} object itself, it also passes
    -- the specified arguments into the function.
    -- @param[opt] args any optional modules or other data the test function needs
    -- @treturn[1] boolean true (test succeeded)
    -- @treturn[2] boolean false (test failed)
    -- @treturn[2] string the error message describing how the test failed
    run: (...) =>
        @assertFailed = false
        @ran = true
        @stubs = {}
        @logStart!
        startTime = os.clock!
        @success, res = xpcall @f, debug.traceback, @, ...
        @duration = os.clock! - startTime
        for i = #@stubs, 1, -1
            @stubs[i]\restore!
        @logResult res

        return @success, @errMsg

    --- Formats and writes a "running test x" message to the log.
    -- @local
    logStart: =>
        @logger\logEx nil, @@msgs.run.test, false, nil, nil, @name

    --- Formats and writes the test result to the log.
    -- In case of failure the message contains details about either the test assertion that failed
    -- or a stack trace if the test ran into a different exception.
    -- @local
    -- @tparam[opt=errMsg] the error message being logged; defaults to the error returned by the last run of this test
    logResult: (errMsg = @errMsg) =>
        if @success
            @logger\logEx nil, @@msgs.run.ok, nil, nil, 0
        else
            if @assertFailed
                -- scrub useless stack trace from asserts provided by this module
                errMsg = errMsg\gsub "%[%w+ \".-\"%]:%d+:", ""
                errMsg = errMsg\gsub "stack traceback:.*", ""
            @errMsg = errMsg
            @logger\logEx nil, @@msgs.run.failed, nil, nil, 0
            @logger.indent += 1
            @logger\log @@msgs.run.reason, @errMsg
            @logger.indent -= 1

    --- Formats a message with a specified predefined template.
    -- Currently only supports the "type" template.
    -- @local
    -- @tparam string template the name of the template to use
    -- @param[opt] args any arguments required for formatting the message
    format: (tmpl, ...) =>
        inArgs = table.pack ...
        outArgs = switch tmpl
            when "type" then {tostring(inArgs[1]), type(inArgs[1])}

        @@msgs.formatTemplate[tmpl]\format unpack outArgs


    -- static helper functions

    --- Compares equality of two specified arguments
    -- Requirements for values are considered equal:
    -- [1] their types match
    -- [2] their metatables are equal
    -- [3] strings and numbers are compared by value
    --     functions and cdata are compared by reference
    --     tables must have equal values at identical indexes and are compared recursively
    --     (i.e. two table copies of `{"a", {"b"}}` are considered equal)
    -- @static
    -- @param a the first value
    -- @param b the second value
    -- @tparam[opt] string aType if already known, specify the type of the first value
    --                           for a small performance benefit
    -- @tparam[opt] string bType the type of the second value
    -- @treturn boolean `true` if a and b are equal, otherwise `false`
    equals: Common.equals

    --- Compares equality of two specified tables ignoring table keys.
    -- The table comparison works much in the same way as @{UnitTest:equals},
    -- however this method doesn't require table keys to be equal between a and b
    -- and considers two tables to be equal if an equal value is found in b for every value in a and vice versa.
    -- By default this only looks at numerical indexes
    -- as this kind of comparison doesn't usually make much sense for hashtables.
    -- @static
    -- @tparam table a the first table
    -- @tparam table b the second table
    -- @tparam[opt=true] bool onlyNumericalKeys Disable this option to also compare items with non-numerical keys
    --                                          at the expense of a performance hit.
    -- @tparam[opt=false] bool ignoreExtraAItems Enable this option to make the comparison one-sided,
    --                                           ignoring additional items present in a but not in b.
    -- @tparam[opt=false] bool requireIdenticalItems Enable this option if you require table items to be identical,
    --                                               i.e. compared by reference, rather than by equality.
    itemsEqual: Common.itemsEqual

    --- Replaces tbl[key] with a Stub and registers it for automatic cleanup after the test.
    -- If tbl is a string, looks up the module in package.loaded.
    -- @tparam table|string tbl the table (or module name) containing the value to replace
    -- @tparam string key the field name to stub
    -- @treturn Stub
    stub: (tbl, key) =>
        s = Stub tbl, key, @logger, @
        @stubs[#@stubs+1] = s
        return s

    --- Wraps tbl[key] with a Stub that forwards all calls to the original.
    -- The original value is restored automatically (LIFO) after the test completes.
    -- @tparam table|string tbl the table (or module name) containing the value to wrap
    -- @tparam string key the field name to spy on
    -- @treturn Stub
    spy: (tbl, key) =>
        s = Stub\spy tbl, key, @logger, @
        @stubs[#@stubs+1] = s
        return s

    --- Helper method to mark a test as failed by assertion and throw a specified error message.
    -- @local
    -- @param condition passing in a falsy value causes the assertion to fail
    -- @tparam string message error message (may contain format string templates)
    -- @param[opt] args any arguments required for formatting the message
    assert: (condition, ...) =>
        args = table.pack ...
        msg = table.remove args, 1
        unless condition
            @assertFailed = true
            @logger\logEx 1, msg, nil, nil, 0, unpack args


    -- type assertions

    --- Fails the assertion if the specified value didn't have the expected type.
    -- @param value the value to be type-checked
    -- @tparam string expectedType the expected type
    assertType: (val, expected) =>
        @checkArgTypes val: {val, "_any"}, expected: {expected, "string"}
        actual = type val
        @assert actual == expected, @@msgs.assert.type, expected, actual

    --- Fails the assertion if the types of the actual and expected value didn't match
    -- @param actual the actual value
    -- @param expected the expected value
    assertSameType: (actual, expected) =>
        actualType, expectedType = type(actual), type expected
        @assert actualType == expectedType, @@msgs.assert.sameType, expectedType, actualType

    --- Fails the assertion if the specified value isn't a boolean
    -- @param value the value expected to be a boolean
    assertBoolean: (val) => @assertType val, "boolean"
    --- Shorthand for @{UnitTest:assertBoolean}
    assertBool: (val) => @assertType val, "boolean"

    --- Fails the assertion if the specified value isn't a function
    -- @param value the value expected to be a function
    assertFunction: (val) => @assertType val, "function"

    --- Fails the assertion if the specified value isn't a number
    -- @param value the value expected to be a number
    assertNumber: (val) => @assertType val, "number"

    --- Fails the assertion if the specified value isn't a string
    -- @param value the value expected to be a string
    assertString: (val) => @assertType val, "string"

    --- Fails the assertion if the specified value isn't a table
    -- @param value the value expected to be a table
    assertTable: (val) => @assertType val, "table"

    --- Helper method to type-check arguments as a prerequisite to other asserts.
    -- @local
    -- @tparam {[string]={value, string}} args a hashtable of argument values and expected types
    --                                         indexed by the respective argument names
    checkArgTypes: (args) =>
        i = 1
        for name, types in pairs args
            declared, actual = types[2], type types[1]
            continue if declared == "_any"
            @logger\assert declared == actual, @@msgs.assert.checkArgTypes, i, name,
                                               declared, @format "type", types[1]
            i += 1


    -- boolean asserts

    --- Fails the assertion if the specified value isn't the boolean `true`.
    -- @param value the value expected to be `true`
    assertTrue: (val) =>
        @assert val == true, @@msgs.assert.true, @format "type", val

    --- Fails the assertion if the specified value doesn't evaluate to boolean `true`.
    -- In Lua this is only ever the case for `nil` and boolean `false`.
    -- @param value the value expected to be truthy
    assertTruthy: (val) =>
        @assert val, @@msgs.assert.truthy, @format "type", val

    --- Fails the assertion if the specified value isn't the boolean `false`.
    -- @param value the value expected to be `false`
    assertFalse: (val) =>
        @assert val == false, @@msgs.assert.false, @format "type", val

    --- Fails the assertion if the specified value doesn't evaluate to boolean `false`.
    -- In Lua `nil` is the only other value that evaluates to `false`.
    -- @param value the value expected to be falsy
    assertFalsy: (val) =>
        @assert not val, @@msgs.assert.falsy, @format "type", val

    --- Fails the assertion if the specified value is not `nil`.
    -- @param value the value expected to be `nil`
    assertNil: (val) =>
        @assert val == nil, @@msgs.assert.nil, @format "type", val

    --- Fails the assertion if the specified value is `nil`.
    -- @param value the value expected to not be `nil`
    assertNotNil: (val) =>
        @assert val != nil, @@msgs.assert.notNil, @format "type", val


    -- numerical asserts

    --- Fails the assertion if a number is out of the specified range.
    -- @tparam number actual the number expected to be in range
    -- @tparam number min the minimum (inclusive) value
    -- @tparam number max the maximum (inclusive) value
    assertInRange: (actual, min = -math.huge, max = math.huge) =>
        @checkArgTypes actual: {actual, "number"}, min: {min, "number"}, max: {max, "number"}
        @assert actual >= min, @@msgs.assert.inRange, min, max, actual, "<", min
        @assert actual <= max, @@msgs.assert.inRange, min, max, actual, ">", max

    --- Fails the assertion if a number is not lower than the specified value.
    -- @tparam number actual the number to compare
    -- @tparam number limit the lower limit (exclusive)
    assertLessThan: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @assert actual < limit, @@msgs.assert.compare, "<", limit, actual

    --- Fails the assertion if a number is not lower than or equal to the specified value.
    -- @tparam number actual the number to compare
    -- @tparam number limit the lower limit (inclusive)
    assertLessThanOrEquals: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @assert actual <= limit, @@msgs.assert.compare, "<=", limit, actual

    --- Fails the assertion if a number is not greater than the specified value.
    -- @tparam number actual the number to compare
    -- @tparam number limit the upper limit (exclusive)
    assertGreaterThan: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @assert actual > limit, @@msgs.assert.compare, ">", limit, actual

    --- Fails the assertion if a number is not greater than or equal to the specified value.
    -- @tparam number actual the number to compare
    -- @tparam number limit the upper limit (inclusive)
    assertGreaterThanOrEquals: (actual, limit) =>
        @checkArgTypes actual: {actual, "number"}, limit: {limit, "number"}
        @assert actual >= limit, @@msgs.assert.compare, ">=", limit, actual

    --- Fails the assertion if a number is not in range of an expected value +/- a specified margin.
    -- @tparam number actual the actual value
    -- @tparam number expected the expected value
    -- @tparam[opt=1e-8] number margin the maximum (inclusive) acceptable margin of error
    assertAlmostEquals: (actual, expected, margin = 1e-8) =>
        @checkArgTypes actual: {actual, "number"}, min: {expected, "number"}, max: {margin, "number"}

        margin = math.abs margin
        @assert math.abs(actual-expected) <= margin, @@msgs.assert.almostEquals,
                                                            expected, margin, actual

    --- Fails the assertion if a number differs from another value at most by a specified margin.
    -- Inverse of @{assertAlmostEquals}
    -- @tparam number actual the actual value
    -- @tparam number value the value being compared against
    -- @tparam[opt=1e-8] number margin the maximum (inclusive) margin of error for the numbers to be considered equal
    assertNotAlmostEquals: (actual, value, margin = 1e-8) =>
        @checkArgTypes actual: {actual, "number"}, value: {value, "number"}, max: {margin, "number"}

        margin = math.abs margin
        @assert math.abs(actual-value) > margin, @@msgs.assert.almostEquals, value, margin, actual

    --- Fails the assertion if a number is not equal to 0 (zero).
    -- @tparam number actual the value
    assertZero: (actual) =>
        @checkArgTypes actual: {actual, "number"}
        @assert actual == 0, @@msgs.assert.zero, actual

    --- Fails the assertion if a number is equal to 0 (zero).
    -- Inverse of @{assertZero}
    -- @tparam number actual the value
    assertNotZero: (actual) =>
        @checkArgTypes actual: {actual, "number"}
        @assert actual != 0, @@msgs.assert.notZero

    --- Fails the assertion if a specified number has a fractional component.
    -- All numbers in Lua share a common data type, which is usually a double,
    -- which is the reason this is not a type check.
    -- @tparam number actual the value
    assertInteger: (actual) =>
        @checkArgTypes actual: {actual, "number"}
        @assert math.floor(actual) == actual, @@msgs.assert.integer, actual

    --- Fails the assertion if a specified number is less than or equal 0.
    -- @tparam number actual the value
    -- @tparam[opt=false] boolean includeZero makes the assertion consider 0 to be positive
    assertPositive: (actual, includeZero = false) =>
        @checkArgTypes actual: {actual, "number"}, includeZero: {includeZero, "boolean"}
        res = includeZero and actual >= 0 or actual > 0
        @assert res, @@msgs.assert.positiveNegative, "positive",
                       includeZero and "included" or "excluded"

    --- Fails the assertion if a specified number is greater than or equal 0.
    -- @tparam number actual the value
    -- @tparam[opt=false] boolean includeZero makes the assertion not fail when a 0 is encountered
    assertNegative: (actual, includeZero = false) =>
        @checkArgTypes actual: {actual, "number"}, includeZero: {includeZero, "boolean"}
        res = includeZero and actual <= 0 or actual < 0
        @assert res, @@msgs.assert.positiveNegative, "positive",
                       includeZero and "included" or "excluded"


    -- generic asserts

    --- Fails the assertion if a the actual value is not *equal* to the expected value.
    -- On the requirements for equality see @{UnitTest:equals}
    -- @param actual the actual value
    -- @param expected the expected value
    assertEquals: (actual, expected) =>
        @assert self.equals(actual, expected), @@msgs.assert.equals, type(actual),
                       @logger\dumpToString(actual), type(expected), @logger\dumpToString expected

    --- Fails the assertion if a the actual value is *equal* to the expected value.
    -- Inverse of @{UnitTest:assertEquals}
    -- @param actual the actual value
    -- @param expected the expected value
    assertNotEquals: (actual, expected) =>
        @assert not self.equals(actual, expected), @@msgs.assert.notEquals,
                       type(actual), @logger\dumpToString expected

    --- Fails the assertion if a the actual value is not *identical* to the expected value.
    -- Uses the `==` operator, so in contrast to @{UnitTest:assertEquals},
    -- this assertion compares tables by reference.
    -- @param actual the actual value
    -- @param expected the expected value
    assertIs: (actual, expected) =>
        @assert actual == expected, @@msgs.assert.is, @format("type", expected),
                                                             @format "type", actual

    --- Fails the assertion if a the actual value is *identical* to the expected value.
    -- Inverse of @{UnitTest:assertIs}
    -- @param actual the actual value
    -- @param expected the expected value
    assertIsNot: (actual, expected) =>
        @assert actual != expected, @@msgs.assert.isNot, @format "type", expected


    -- table asserts

    --- Fails the assertion if the items of one table aren't *equal* to the items of another.
    -- Unlike @{UnitTest:assertEquals} this ignores table keys, so e.g. two numerically-keyed tables
    -- with equal items in a different order would still be considered equal.
    -- By default this assertion only compares values at numerical indexes (see @{UnitTest:itemsEqual} for details).
    -- @tparam table actual the first table
    -- @tparam table expected the second table
    -- @tparam[opt=true] boolean onlyNumericalKeys Disable this option to also compare items with non-numerical keys                                 at the expense of a performance hit.
    assertItemsEqual: (actual, expected, onlyNumKeys = true) =>
        @checkArgTypes { actual: {actual, "table"}, expected: {actual, "table"},
                         onlyNumKeys: {onlyNumKeys, "boolean"}
                       }

        @assert self.itemsEqual(actual, expected, onlyNumKeys),
                       @@msgs.assert[onlyNumKeys and "itemsEqualNumericKeys" or "itemsEqualAllKeys"],
                       @logger\dumpToString(actual), @logger\dumpToString expected


    --- Fails the assertion if the items of one table aren't *identical* to the items of another.
    -- Like @{UnitTest:assertItemsEqual} this ignores table keys, however it compares table items by reference.
    -- By default this assertion only compares values at numerical indexes (see @{UnitTest:itemsEqual} for details).
    -- @tparam table actual the first table
    -- @tparam table expected the second table
    -- @tparam[opt=true] boolean onlyNumericalKeys Disable this option to also compare items with non-numerical keys
    assertItemsAre: (actual, expected, onlyNumKeys = true) =>
        @checkArgTypes { actual: {actual, "table"}, expected: {actual, "table"},
                         onlyNumKeys: {onlyNumKeys, "boolean"}
                       }

        @assert self.itemsEqual(actual, expected, onlyNumKeys, nil, true),
                       @@msgs.assert[onlyNumKeys and "itemsEqualNumericKeys" or "itemsEqualAllKeys"],
                       @logger\dumpToString(actual), @logger\dumpToString expected

    --- Fails the assertion if the numerically-keyed items of a table aren't continuous.
    -- The rationale for this is that when iterating a table with ipairs or retrieving its length
    -- with the # operator, Lua may stop processing the table once the item at index n is nil,
    -- effectively hiding any subsequent values
    -- @tparam table tbl the table to be checked
    assertContinuous: (tbl) =>
        @checkArgTypes { tbl: {tbl, "table"} }

        realCnt, contCnt = 0, #tbl
        for _, v in pairs tbl
            if type(v) == "number" and math.floor(v) == v
                realCnt += 1

        @assert realCnt == contCnt, @@msgs.assert.continuous, contCnt+1, realCnt

    -- string asserts

    --- Fails the assertion if a string doesn't match the specified pattern.
    -- Accepts a Lua string pattern or a compiled aegisub.re pattern object.
    -- @tparam string str the input string
    -- @param pattern string|userdata Lua pattern string or compiled aegisub.re pattern
    assertMatches: (str, pattern) =>
        @checkArgTypes { str: {str, "string"} }
        isLuaPattern = type(pattern) == "string"
        match = isLuaPattern and str\match(pattern) or pattern\match str
        @assert match, @@msgs.assert.matches, str, (isLuaPattern and "Lua" or "regex"), tostring pattern

    --- Fails the assertion if a string doesn't contain a specified substring.
    -- Search is case-sensitive by default.
    -- @tparam string str the input string
    -- @tparam string needle the substring to be found
    -- @tparam[opt=true] boolean caseSensitive Disable this option to use locale-dependent case-insensitive comparison.
    -- @tparam[opt=1] number init the first byte to start the search at
    assertContains: (str, needle, caseSensitive = true, init = 1) =>
        @checkArgTypes { str: {str, "string"}, needle: {needle, "string"},
                         caseSensitive: {caseSensitive, "boolean"}, init: {init, "number"}
                       }

        _str, _needle = if caseSensitive
            str\lower!, needle\lower!
        else str, needle
        @assert str\find(needle, init, true), str, needle,
                       caseSensitive and "sensitive" or "insensitive"

    -- function asserts


    --- Fails the assertion if calling a function with the specified arguments doesn't cause it throw an error.
    -- @tparam function func the function to be called
    -- @param[opt] args any number of arguments to be passed into the function
    assertError: (func, ...) =>
        @checkArgTypes { func: {func, "function"} }

        res = table.pack pcall func, ...
        retCnt, success = res.n, table.remove res, 1
        res.n = nil
        @assert success == false, @@msgs.assert.error, retCnt, @logger\dumpToString res
        return res[1]

    --- Fails the assertion if a function call doesn't cause an error message that matches the specified pattern.
    -- Accepts a Lua string pattern or a compiled aegisub.re pattern object.
    -- @tparam function func the function to be called
    -- @tparam[opt={}] table args a table of any number of arguments to be passed into the function
    -- @param pattern string|userdata Lua pattern string or compiled aegisub.re pattern
    assertErrorMsgMatches: (func, params = {}, pattern) =>
        @checkArgTypes { func: {func, "function"}, params: {params, "table"} }
        msg = @assertError func, unpack params
        isString = type(pattern) == "string"
        match = isString and msg\match(pattern) or pattern\match msg
        @assert match, @@msgs.assert.errorMsgMatches, msg, (isString and "Lua" or "regex"), tostring pattern


--- A special case of the UnitTest class for a setup routine
-- @classmod UnitTestSetup
class UnitTestSetup extends UnitTest
    --- Runs the setup routine.
    -- Only the @{UnitTestSetup} object is passed into the function.
    -- Values returned by the setup routine are stored to be passed into the test functions later.
    -- @treturn[1] boolean true (test succeeded)
    -- @treturn[1] table retVals all values returned by the function packed into a table
    -- @treturn[2] boolean false (test failed)
    -- @treturn[2] string the error message describing how the test failed
    run: =>
        @ran = true
        @logger\logEx nil, @@msgs.run.setup, false

        startTime = os.clock!
        res = table.pack pcall @f, @
        @duration = os.clock! - startTime
        @success = table.remove res, 1
        @logResult res[1]

        if @success
            @retVals = res
            return true, @retVals

        return false, @errMsg

--- A special case of the UnitTest class for a teardown routine
-- @classmod UnitTestTeardown
class UnitTestTeardown extends UnitTest
    --- Formats and writes a "running test x" message to the log.
    -- @local
    logStart: =>
        @logger\logEx nil, @@msgs.run.teardown, false


--- Holds a unit test class, i.e. a group of unit tests with common setup and teardown routines
-- @classmod UnitTestClass
class UnitTestClass
    msgs = {
        run: {
            runningTests: "Running test class '%s' (%d tests)..."
            setupFailed: "Setup for test class '%s' FAILED, skipping tests."
            abort: "Test class '%s' FAILED after %d tests, aborting."
            testsFailed: "Done testing class '%s'. FAILED %d of %d tests."
            success: "Test class '%s' completed successfully."
            skipped: "Test class '%s' SKIPPED (%s)."
            teardownFailed: "Teardown for test class '%s' FAILED."
            testNotFound: "Couldn't find requested test '%s'."
        }
        skipReason: {
            default: "condition not met"
        }
    }

    --- Creates a new unit test class complete with a number of unit test as well as optional setup and teardown.
    -- Instead of calling this constructor directly, it is recommended to call @{UnitTestSuite:new} instead,
    -- which takes a table of test functions and creates test classes automatically.
    -- @tparam string name a descriptive name for the test class
    -- @tparam[opt={}] {[string] = function|table, ...} args a table of test functions by name;
    -- indexes starting with "_" have special meaning and are not added as regular tests:
    -- * _setup: a @{UnitTestSetup} routine
    -- * _teardown: a @{UnitTestTeardown} routine
    -- * _order: alternative syntax to the order parameter (see below)
    -- * _condition: a predicate `() -> boolean[, string reason]`. Evaluated before the class
    --   runs; if it returns a falsy value the whole class is skipped and its tests are marked
    --   as skipped (with the optional reason) in the report rather than run. Use it to gate
    --   environment-dependent tests, e.g. `_condition: -> os.getenv("DEPCTRL_INTEGRATION") == "1"`.
    -- @tparam [opt=nil (unordered)] {string, ...} A list of test names in the desired execution order.
    -- Only tests mentioned in this table will be performed when running the whole test class.
    -- If unspecified, all tests will be run in random order.
    new: (@name, args = {}, @order, @testSuite) =>
        @logger = @testSuite.logger
        @setup = UnitTestSetup "setup", args._setup, @
        @teardown = UnitTestTeardown "teardown", args._teardown, @
        @hasTeardown = args._teardown != nil
        @description = args._description
        @condition = args._condition
        @order or= args._order
        @tests = [UnitTest(name, f, @) for name, f in pairs args when "_" != name\sub 1,1]

    --- Runs all tests in the unit test class in the specified order.
    -- @param[opt=false] abortOnFail stops testing once a test fails
    -- @param[opt=(default)] overrides the default test order
    -- @treturn[1] boolean true (test class succeeded)
    -- @treturn[2] boolean false (test class failed)
    -- @treturn[2] {@{UnitTest}, ...} a list of unit test that failed
    run: (abortOnFail, order = @order) =>
        -- class-level skip condition: when the predicate returns falsy, skip the whole class
        -- and mark its tests as skipped so they still surface (as skipped) in the report.
        -- Call without `self` (plain `cond!`, not `@condition!`) so the predicate isn't handed
        -- the class as an unexpected first argument.
        if cond = @condition
            shouldRun, reason = cond!
            unless shouldRun
                @skipped, @skipReason = true, reason
                for test in *@tests
                    test.skipped, test.skipReason = true, reason
                @logger\log msgs.run.skipped, @name, reason or msgs.skipReason.default
                return true   -- a skipped class is not a failure

        tests, failed = @tests, {}
        if order
            tests, mappings = {}, {test.name, test for test in *@tests}
            for i, name in ipairs order
                @logger\assert mappings[name], msgs.run.testNotFound, name
                tests[i] = mappings[name]
        testCnt, failedCnt = #tests, 0

        @logger\log msgs.run.runningTests, @name, testCnt
        @logger.indent += 1

        success, res = @setup\run!
        -- failing the setup always aborts (no teardown: setup never completed)
        unless success
            @logger.indent -= 1
            @logger\warn msgs.run.setupFailed, @name
            return false, -1

        aborted = false
        for i, test in pairs tests
            unless test\run unpack res
                failedCnt += 1
                failed[#failed+1] = test
                if abortOnFail
                    @logger\warn msgs.run.abort, @name, i
                    aborted = true
                    break

        -- teardown runs after the tests whenever setup succeeded — including the abort path —
        -- so resource cleanup is reliable. It's best-effort: a teardown failure is logged but
        -- doesn't change the class result. Setup's return values are passed through to it.
        if @hasTeardown
            @logger\warn msgs.run.teardownFailed, @name unless @teardown\run unpack res

        @logger.indent -= 1
        @success = failedCnt == 0

        if aborted
            return false, failed
        if @success
            @logger\log msgs.run.success, @name
            return true

        @logger\log msgs.run.testsFailed, @name, failedCnt, testCnt
        return false, failed


--- A bundle of helper utilities handed to a suite's import function as its trailing argument.
-- @class UnitTestSuiteControls
class UnitTestSuiteControls
    -- @param suite UnitTestSuite the suite to expose controls for 
    new: (suite) =>
        @_suite = suite -- we don't want to encourage direct access to the suite, but will leave the option for the brave or desperate

    --- Requires one of the suite's sibling test modules by its leaf name.
    -- Resolved against the test suite identifier, so the same call works for both the Aegisub-default and custom test locations (e.g. as used in CI environments).
    -- @tparam string leaf the module name relative to the test root (e.g. "FileOps")
    -- @return the loaded test module
    requireTest: (leaf) => @_suite\requireTestLeaf leaf

--- A DependencyControl unit test suite.
-- Your test file/module must return a UnitTestSuite object in order to be recognized as a test suite.
-- @class UnitTestSuite
class UnitTestSuite
    msgs = {
        run: {
            running: "Running %d test classes for %s... "
            aborted: "Aborting after %d test classes... "
            classesFailed: "FAILED %d of %d test classes."
            success: "All tests completed successfully."
            classNotFound: "Couldn't find requested test class '%s'."
        }
        registerMacros: {
            allDesc: "Runs the whole test suite."
        }
        new: {
            badClassesType: "Test classes must be passed in either as a table or an import function, got a %s"
        }
        import: {
            noTableReturned: "The test import function must return a table of test classes, got a %s."
        }
    }

    @UnitTest = UnitTest
    @UnitTestClass = UnitTestClass
    @UnitTestSuiteControls = UnitTestSuiteControls
    @Stub = Stub

    --- Return the require specifier used to load DepCtrl test suites in Aegisub environments.
    -- In an Aegisub environment, test suites reside in '?user/automation/tests/DepUnit/(modules|macros)/<namespace>.(moon|lua)'.
    -- @param scriptType Common.ScriptType value indicating whether the test suite is for a module or an automation script.
    -- @param namespace the namespaced identifier of the package under test (e.g. 'l0.Functional').
    -- @return the require specifier used to load the test suite.
    @getDefaultTestSuiteRequireIdentifier = (scriptType, namespace) =>
        "DepUnit.#{Common.ScriptType.name.legacy[scriptType]}.#{namespace}"

    -- Returns the require specifier used to load DepCtrl test suites in the current environment.
    -- Accepts a hook via the global variable DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER to be used
    -- by CLI/CI test runners loading the test suites from the source repo or other locations.
    -- @param scriptType Common.ScriptType value indicating whether the test suite is for a module or an automation script.
    -- @param namespace the namespaced identifier of the package under test (e.g. 'l0.Functional').
    @getTestSuiteRequireIdentifier = (scriptType, namespace) =>
        DependencyControl or= require "l0.DependencyControl"

        switch type(DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER)
            when "nil" then @getDefaultTestSuiteRequireIdentifier scriptType, namespace
            when "string" then DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER
            when "function" then DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER(scriptType, namespace, DependencyControl)
            else error "DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER must be either a string or a function, got a #{type DEPCTRL_UNIT_TEST_SUITE_REQUIRE_IDENTIFIER}"

    --- Requires a test module or the entire test suite.
    -- @param requireIdentifier string the require specifier of the test suite to be loaded. Use @getTestSuiteRequireIdentifier to obtain it for Aegisub environments.
    -- @return the loaded test suite module
    @require: (suiteIdentifier) =>
        test = require suiteIdentifier
        test.suiteRequireIdentifier or= suiteIdentifier
        return test

    ---Creates a complete unit test suite for a module or automation script.
    ---Using this constructor creates all test classes and tests automatically.
    ---@param namespace string The namespace of the module or automation script to test.
    ---@param classes table<string, table>|fun(...): table The test classes by name, or a function that returns them. When a function, it receives:
    --- * the subject under test: for a module its own ref; for an automation script a map of its registered macros keyed by name, each holding the macro's process/validate/isActive (populated as macros register, so read it inside test bodies, not while building test classes)
    --- * dependencies: a numerically keyed table of all modules required by the tested script/module (in order)
    --- * extras: any further arguments passed into register/registerMacros — a module's own table, or an automation script's testExports (the internals under test)
    --- * a UnitTestSuiteControls handed in as the final argument (e.g. for requireTest)
    ---Keys starting with "_" have special meaning and aren't added as regular tests (e.g. _order).
    ---@param order? string[] Test class names in the desired execution order; only listed classes run when running the whole suite. Unordered if omitted.
    new: (@namespace, classes, @order) =>
        @logger = Logger defaultLevel: 3, fileBaseName: @namespace, fileSubName: "UnitTests", toFile: true
        @classes = {}
        switch type classes
            when "table" then @addClasses classes
            when "function" then @importFunc = classes
            else @logger\error msgs.new.badClassesType, type classes

    --- Constructs test classes and adds them to the suite.
    -- Use this if you need to add additional test classes to an existing @{UnitTestSuite} object.
    -- @tparam {[string] = table, ...} args a hashtable of @{UnitTestClass} constructor tables by name.
    addClasses: (classes) =>
        @classes[#@classes+1] = UnitTestClass(name, args, args._order, @) for name, args in pairs classes when "_" != name\sub 1,1
        if classes._order
            @order or= {}
            @order[#@order+1] = clsName for clsName in *classes._order

    --- Loads test classes from a function and adds them to the suite, passing in the specified arguments and a suite controller.
    -- Generally used for dependency injection (e.g. the DepCtrl runners pass in the module under test as well as its declared dependencies).
    -- @param ... any dependencies or other arguments to be passed to the test suite's import function
    import: (...) =>
        return false unless @importFunc
 
        controls = UnitTestSuiteControls @
        args = table.pack ...
        args.n += 1
        args[args.n] = controls
        classes = (@importFunc) unpack args, 1, args.n

        @logger\assert type(classes) == "table", msgs.import.noTableReturned, type classes
        @addClasses classes
        @importFunc = nil

    --- Registers macros for running all or specific test classes of this suite.
    -- If the test script is placed in the appropriate directory (according to module/automation script namespace),
    -- this is automatically handled by DependencyControl.
    registerMacros: =>
        return if @macrosRegistered

        menuItem = {"DependencyControl", "Run Tests", @name or @namespace, "[All]"}
        aegisub.register_macro table.concat(menuItem, "/"), msgs.registerMacros.allDesc, -> @run!
        for cls in *@classes
            menuItem[4] = cls.name
            aegisub.register_macro table.concat(menuItem, "/"), cls.description, -> cls\run!
        @macrosRegistered = true

    --- Requires a specific test leaf module. 
    -- Used by multi-file test suites to load their sibling test modules without hard-coding environment-specific paths.
    -- @tparam string leafIdentifier the module name relative to the test root (e.g. "FileOps")
    requireTestLeaf: (leafIdentifier) =>
        @logger\assert @suiteRequireIdentifier, "test suite must have a suite require identifier configured in order to resolve sibling test '#{leafIdentifier}'" 
        require "#{@suiteRequireIdentifier}.#{leafIdentifier}"

    --- Runs all test classes of this suite in the specified order.
    -- @param[opt=false] abortOnFail stops testing once a test fails
    -- @param[opt=(default)] overrides the default test order
    -- @treturn[1] boolean true (test class succeeded)
    -- @treturn[2] boolean false (test class failed)
    -- @treturn[2] {@{UnitTest}, ...} a list of unit test that failed
    run: (abortOnFail, order = @order) =>
        classes, allFailed = @classes, {}
        if order
            classes, mappings = {}, {cls.name, cls for cls in *@classes}
            for i, name in ipairs order
                @logger\assert mappings[name], msgs.run.classNotFound, name
                classes[i] = mappings[name]

        classCnt, failedCnt = #classes, 0
        @logger\log msgs.run.running, classCnt, @namespace
        @logger.indent += 1

        @startTime = os.time! * 1000   -- epoch ms, for the CTRF report summary
        for i, cls in pairs classes
            success, failed = cls\run abortOnFail
            unless success
                failedCnt += 1
                allFailed[#allFailed+1] = test for test in *failed
                if abortOnFail
                    @logger.indent -= 1
                    @logger\warn msgs.run.abort, i
                    return false, allFailed

        @endTime = os.time! * 1000
        @logger.indent -= 1
        @success = failedCnt == 0
        if @success
            @logger\log msgs.run.success
        else @logger\log msgs.run.classesFailed, failedCnt, classCnt

        return @success, failedCnt > 0 and allFailed or nil

    --- Collects the results of the most recent run into a flat, format-agnostic structure.
    -- Tests that ran or were skipped are included; a failed class setup surfaces as an errored
    -- "setup" case so aborted classes still show up in the report.
    -- @local
    -- @treturn {{name=string, cases={{name, classname, duration, failure?, error?, skipped?, skipReason?}, ...}}, ...}
    collectResults: =>
        suites = {}
        for cls in *@classes
            cases = {}
            -- a setup failure aborts the whole class; represent it as an error case
            if cls.setup and cls.setup.ran and not cls.setup.success
                cases[#cases+1] = { name: "setup", classname: cls.name,
                                    duration: cls.setup.duration or 0, error: cls.setup.errMsg }
            for test in *cls.tests
                continue unless test.ran or test.skipped
                case = { name: test.name, classname: cls.name, duration: test.duration or 0 }
                if test.skipped
                    case.skipped, case.skipReason = true, test.skipReason
                elseif not test.success
                    -- keep assertion failures and unexpected errors separate for consumers
                    -- that care; CTRF itself folds both into a single "failed" status
                    if test.assertFailed
                        case.failure = test.errMsg or "assertion failed"
                    else
                        case.error = test.errMsg or "unexpected error"
                cases[#cases+1] = case
            suites[#suites+1] = { name: cls.name, :cases }
        return suites

    --- Builds a CTRF (Common Test Report Format) report of the most recent run.
    -- CTRF is a JSON test report schema understood by ready-made CI reporters
    -- (e.g. the ctrf-io/github-test-reporter action). See https://ctrf.io.
    -- @treturn table the CTRF report as a plain Lua table, ready to be JSON-encoded
    toCtrf: =>
        tests, passed, failed, skipped = {}, 0, 0, 0
        for suite in *@collectResults!
            for c in *suite.cases
                entry = {
                    name: c.name
                    suite: c.classname
                    duration: math.floor c.duration * 1000 + 0.5   -- seconds -> ms
                }
                if c.skipped
                    skipped += 1
                    entry.status = "skipped"
                    entry.message = c.skipReason if c.skipReason
                elseif c.failure or c.error
                    failed += 1
                    entry.status = "failed"
                    entry.message = c.failure or c.error   -- CTRF folds assert/error into "failed"
                else
                    passed += 1
                    entry.status = "passed"
                tests[#tests+1] = entry

        return {
            results: {
                tool: { name: "DependencyControl.UnitTestSuite" }
                summary: {
                    tests: passed + failed + skipped
                    :passed, :failed, :skipped
                    pending: 0, other: 0
                    start: @startTime or 0
                    stop: @endTime or 0
                }
                :tests
            }
        }

    --- Writes a CTRF JSON report of the most recent run to the given path.
    -- Any missing parent directories are created; Aegisub path tokens are expanded.
    -- @tparam string path destination file path
    -- @treturn[1] boolean true on success
    -- @treturn[2] nil
    -- @treturn[2] string an error message
    writeResults: (path) =>
        FileOps = require "l0.DependencyControl.FileOps"
        json    = require "json"   -- provided by DepCtrl (bundled dkjson) once it's loaded

        dirRes, err = FileOps.mkdir path, true, true
        return nil, err if dirRes == nil

        handle, msg = io.open aegisub.decode_path(path), "wb"
        return nil, msg unless handle
        handle\write json.encode @toCtrf!, { indent: true }
        handle\close!
        return true
