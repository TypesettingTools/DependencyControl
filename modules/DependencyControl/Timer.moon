-- Monotonic timer with millisecond sleep.
-- DepCtrl always uses this FFI-based implementation for consistent behavior.
-- If PT.PreciseTimer has not been loaded by the time this module runs, it is
-- registered under that name so other scripts requiring it get a working timer.

ffi = require "ffi"

local getTime, sleep

if ffi.os == "Windows"
    -- Separate pcalls: a Sleep redeclaration conflict must not block QPC/QPF.
    pcall ffi.cdef, "int QueryPerformanceCounter(long long *lpPerformanceCount);"
    pcall ffi.cdef, "int QueryPerformanceFrequency(long long *lpFrequency);"
    pcall ffi.cdef, "unsigned int Sleep(unsigned int dwMilliseconds);"

    freq = ffi.new "long long[1]"
    ffi.C.QueryPerformanceFrequency freq
    freq = tonumber freq[0]

    counter = ffi.new "long long[1]"
    getTime = ->
        ffi.C.QueryPerformanceCounter counter
        tonumber(counter[0]) / freq

    sleep = (ms) -> ffi.C.Sleep ms

else
    -- CLOCK_MONOTONIC: 1 on Linux, 6 on macOS
    CLOCK_MONOTONIC = ffi.os == "OSX" and 6 or 1

    pcall ffi.cdef, [[
        struct timespec { long tv_sec; long tv_nsec; };
        int clock_gettime(int clk_id, struct timespec *tp);
        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
    ]]

    ts = ffi.new "struct timespec"
    getTime = ->
        ffi.C.clock_gettime CLOCK_MONOTONIC, ts
        tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9

    sleep = (ms) -> ffi.C.poll nil, 0, ms


class Timer
    --- Creates a new timer, capturing the current time as the start point.
    new: =>
        @startTime = getTime!

    --- Returns wall-clock seconds elapsed since construction.
    ---@return number seconds
    timeElapsed: =>
        getTime! - @startTime

    --- Sleeps for the given number of milliseconds.
    ---@param ms number
    sleep: sleep

    @sleep = sleep


-- Try loading the real PT.PreciseTimer so other scripts can use it if available.
-- If it's unavailable (no native build, missing dependencies), inject our
-- Timer as a fallback so those scripts still get a working implementation.
if not pcall require, "PT.PreciseTimer"
    package.loaded["PT.PreciseTimer"] = Timer

return Timer
