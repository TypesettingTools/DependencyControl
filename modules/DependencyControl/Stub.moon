
Common = require "l0.DependencyControl.Common"
Logger = require "l0.DependencyControl.Logger"

msgs = {
    notCalled:          "Expected stub to have been called, but it was never called."
    wasCalled:          "Expected stub not to have been called, but it was called %d time(s)."
    wrongCallCount:     "Expected stub to have been called %d time(s), but it was called %d time(s)."
    notCalledWith:      "No call matched the expected arguments (stub was called %d time(s)).\n  Expected: %s"
    noNthCall:          "Expected at least %d call(s), but stub was only called %d time(s)."
    wrongCall:          "Call #%d arguments did not match.\n  Expected: %s\n    Actual: %s"
    calledAfterRestore: "Stub for '%s' was called after being restored."
    canary: {
        notRestored: "Stub for '%s' was not restored before being garbage collected."
    }
}

_stubMatch = (call, expected) ->
    for i = 1, expected.n
        return false unless Common.equals call[i], expected[i]
    return true

--- A callable stub that records invocations and supports fluent configuration and assertions.
-- Can be used standalone or via UnitTest:stub for automatic lifecycle management.
-- @class Stub
class Stub
    @logger = Logger fileBaseName: "DependencyControl.Stub"

    --- Creates a spy on a method, recording calls while still invoking the original method.
    -- @param table table|string the table to spy into, or a module name (looked up in the module cache)
    -- @param key string the field name to spy on
    -- @param[opt] logger Logger the logger to use; when nil a default logger is used
    -- @param[opt] unitTest UnitTest the unit test instance to report assertion failures    
    -- @return Stub
    @spy = (table, key, logger, unitTest) =>
        s = @ table, key, logger, unitTest
        return s\calls (...) -> s._originalMethod ...

    --- Creates a stub, optionally replacing a key in a table.
    -- @param[opt] table table|string the table to stub into, or a module name (looked up in the module cache)
    -- @param[opt] key string the field name to replace; when nil no table is modified
    -- @param[opt] logger Logger the logger to use; when nil a default logger is used
    -- @param[opt] unitTest UnitTest the unit test instance to report assertion failures to; when nil assertion failures throw errors
    new: (table, key, logger, unitTest) =>
        @_calls = {}
        @_replacement = ->
        @unitTest = unitTest
        restored = {false}
        @_restored = restored
        @logger = logger

        if type(table) == "string"
            table = package.loaded[table]

        if table != nil and key != nil
            @_targetTable = table
            @_targetMethodKey = key
            @_originalMethod = table[key]
            table[key] = @

            -- GC canary: warn if this stub is collected without restore() being called
            keyRef, logger = key, @logger or @@logger
            canary = newproxy true
            (getmetatable canary).__gc = ->
                unless restored[1]
                    pcall logger.warn, logger, msgs.canary.notRestored, keyRef

            meta = getmetatable @
            setmetatable @, {
                __metatable: meta
                __index:     meta.__index
                __call:      meta.__call
                __canary:    canary
            }

    __call: (...) =>
        @_fail msgs.calledAfterRestore, @_targetMethodKey if @_restored[1]
        @_calls[#@_calls + 1] = table.pack ...
        repl = @_replacement
        return repl ...

    --- Sets the function to invoke when the stub is called.
    -- @tparam function impl
    -- @treturn Stub self
    calls: (impl) =>
        @_replacement = impl
        return @

    --- Sets the stub to return fixed values on every call.
    -- @treturn Stub self
    returns: (...) =>
        vals = table.pack ...
        @_replacement = -> unpack vals, 1, vals.n
        return @

    --- Restores the original value that was replaced by this stub.
    restore: =>
        if @_targetTable != nil
            @_targetTable[@_targetMethodKey] = @_originalMethod
            @_restored[1] = true

    _fail: (msg, ...) =>
        if @unitTest
            @unitTest\assert false, msg, ...
        else
            error string.format(msg, ...), 2

    _dump: (val) =>
        return @unitTest.logger\dumpToString val if @unitTest
        return tostring val

    assertCalled: =>
        @_fail msgs.notCalled unless #@_calls > 0

    assertNotCalled: =>
        @_fail msgs.wasCalled, #@_calls unless #@_calls == 0

    assertCalledTimes: (n) =>
        @_fail msgs.wrongCallCount, n, #@_calls unless #@_calls == n

    assertCalledOnce: =>
        @_fail msgs.wrongCallCount, 1, #@_calls unless #@_calls == 1

    assertCalledOnceWith: (...) =>
        @_fail msgs.wrongCallCount, 1, #@_calls unless #@_calls == 1
        expected = table.pack ...
        @_fail msgs.wrongCall, 1, @_dump(expected), @_dump(@_calls[1]) unless _stubMatch @_calls[1], expected

    assertCalledWith: (...) =>
        expected = table.pack ...
        for call in *@_calls
            return if _stubMatch call, expected
        @_fail msgs.notCalledWith, #@_calls, @_dump expected

    assertLastCalledWith: (...) =>
        expected = table.pack ...
        last = @_calls[#@_calls]
        @_fail msgs.notCalled unless last != nil
        @_fail msgs.wrongCall, #@_calls, @_dump(expected), @_dump last unless _stubMatch last, expected

    assertNthCalledWith: (n, ...) =>
        expected = table.pack ...
        call = @_calls[n]
        @_fail msgs.noNthCall, n, #@_calls unless call != nil
        @_fail msgs.wrongCall, n, @_dump(expected), @_dump call unless _stubMatch call, expected
