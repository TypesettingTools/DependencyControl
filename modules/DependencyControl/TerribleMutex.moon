-- Process-scoped mutex using native OS synchronization primitives — a pure-FFI
-- stand-in for BM.BadMutex. DependencyControl registers it as a provider for the
-- "BM.BadMutex" alias (see ModuleProvider), so it is used wherever the native
-- library isn't installed; native takes precedence by default, and
-- DEPCTRL_PREFER_FFI_MUTEX=1 forces this implementation instead.
--
-- The mutex name embeds the process ID so concurrent Aegisub / test-launcher
-- instances never share the same lock.

ffi = require "ffi"

local tryLock, lock, unlock, canary

if ffi.os == "Windows"
    -- Named mutex (CreateMutexA) is thread-reentrant on Windows — the same thread can
    -- acquire it again without blocking, unlike std::mutex. Use a binary semaphore
    -- (initial=1, max=1) instead: WaitForSingleObject on a semaphore at count 0
    -- returns WAIT_TIMEOUT regardless of which thread holds it.
    pcall ffi.cdef, "unsigned int GetCurrentProcessId(void);"
    pcall ffi.cdef, "void *CreateSemaphoreA(void *attr, long initialCount, long maximumCount, const char *name);"
    pcall ffi.cdef, "unsigned long WaitForSingleObject(void *hHandle, unsigned long dwMilliseconds);"
    pcall ffi.cdef, "bool ReleaseSemaphore(void *hSemaphore, long lReleaseCount, long *lpPreviousCount);"
    pcall ffi.cdef, "bool CloseHandle(void *hObject);"

    pid    = ffi.C.GetCurrentProcessId!
    name   = ("DepCtrl_%d")\format pid
    handle = ffi.C.CreateSemaphoreA nil, 1, 1, name

    WAIT_OBJECT_0 = 0
    INFINITE      = 0xFFFFFFFF

    tryLock = -> ffi.C.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0
    lock    = -> ffi.C.WaitForSingleObject handle, INFINITE
    unlock  = -> ffi.C.ReleaseSemaphore handle, 1, nil

    canary = newproxy true
    (getmetatable canary).__gc = -> ffi.C.CloseHandle handle

else
    O_CREAT = ffi.os == "OSX" and 0x200 or 0x40 -- open syscall flag: create a file if it doesn't exist
    FILE_MODE_664 = 0x1a4
    BINARY_SEMAPHORE_INITIAL_VALUE = 1

    pcall ffi.cdef, [[
        int getpid(void);
        void *sem_open(const char *name, int oflag, unsigned int mode, unsigned int value);
        int sem_wait(void *sem);
        int sem_trywait(void *sem);
        int sem_post(void *sem);
        int sem_close(void *sem);
        int sem_unlink(const char *name);
    ]]

    pid  = ffi.C.getpid!
    name = ("/depctrl_%d")\format pid
    sem  = ffi.C.sem_open name, O_CREAT, FILE_MODE_664, BINARY_SEMAPHORE_INITIAL_VALUE

    tryLock = -> ffi.C.sem_trywait(sem) == 0
    lock    = -> ffi.C.sem_wait sem
    unlock  = -> ffi.C.sem_post sem

    -- sem_unlink removes the name; the semaphore lives until all sem_close calls complete,
    -- so other states' handles remain valid after unlink. Repeated unlink calls fail silently.
    canary = newproxy true
    (getmetatable canary).__gc = ->
        ffi.C.sem_close sem
        ffi.C.sem_unlink name


mutex = {
    :tryLock, :lock, :unlock
    __canary: canary  -- keeps canary alive for this module's lifetime
    -- mirrors the BM.BadMutex version this stands in for
    version: "0.1.3"
}

return mutex
