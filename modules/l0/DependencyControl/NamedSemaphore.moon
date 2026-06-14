ffi = require "ffi"

local formatName, openImpl, isOpenImpl, tryLockImpl, lockImpl, unlockImpl, closeImpl
local pid, isAvailable

msgs = {
    noImplementation: "No named semaphore implementation is available on this platform/build configuration."
}

if ffi.os == "Windows"
    -- On Windows, the kernel object is ref-counted and destroyed once the last handle closes,
    -- so it self-heals after a holder process exits

    ffiWin = require "l0.DependencyControl.helpers.ffi-windows"  -- registers the shared CloseHandle cdef

    pcall ffi.cdef, "unsigned int GetCurrentProcessId(void);"
    pcall ffi.cdef, "void *CreateSemaphoreA(void *attr, long initialCount, long maximumCount, const char *name);"
    pcall ffi.cdef, "unsigned long WaitForSingleObject(void *hHandle, unsigned long dwMilliseconds);"
    pcall ffi.cdef, "bool ReleaseSemaphore(void *hSemaphore, long lReleaseCount, long *lpPreviousCount);"

    WAIT_OBJECT_0 = 0
    INFINITE      = 0xFFFFFFFF

    okPid, p = pcall -> tonumber ffi.C.GetCurrentProcessId!
    pid = okPid and p or 0
    isAvailable = true

    formatName  = (token) -> token
    openImpl    = (name) -> ffi.C.CreateSemaphoreA nil, 1, 1, name
    isOpenImpl  = (handle) -> handle != nil
    tryLockImpl = (handle) -> ffi.C.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0
    lockImpl    = (handle) -> ffi.C.WaitForSingleObject handle, INFINITE
    unlockImpl  = (handle) -> ffi.C.ReleaseSemaphore handle, 1, nil
    closeImpl   = (name, handle, unlink) -> ffiWin.kernel32.CloseHandle handle

else
    -- POSIX named semaphore. Unlike Windows, the name persists in the kernel namespace
    -- until it is unlinked or reboot, so it does not self-heal after a holder process dies.

    ffiPosix = require "l0.DependencyControl.helpers.ffi-posix"
    -- Aegisub runs per-user, so semaphores don't need to be shared with others.
    SEMAPHORE_FILE_MODE = ffiPosix.getFileMode "rw" 
    BINARY_SEMAPHORE_INITIAL_VALUE = 1
    SEM_FAILED    = ffi.cast "void *", -1  -- sem_open's failure sentinel ((void*)-1)

    pcall ffi.cdef, [[
        int getpid(void);
        void *sem_open(const char *name, int oflag, unsigned int mode, unsigned int value);
        int sem_wait(void *sem);
        int sem_trywait(void *sem);
        int sem_post(void *sem);
        int sem_close(void *sem);
        int sem_unlink(const char *name);
    ]]

    okPid, p = pcall -> tonumber ffi.C.getpid!
    pid = okPid and p or 0
    isAvailable = true

    -- POSIX names must start with a single '/' and contain no other slashes.
    formatName  = (token) -> "/#{token}"
    openImpl    = (name) -> ffi.C.sem_open name, ffiPosix.FileCreationFlags.Create, SEMAPHORE_FILE_MODE, BINARY_SEMAPHORE_INITIAL_VALUE
    isOpenImpl  = (handle) -> handle != nil and handle != SEM_FAILED
    tryLockImpl = (handle) -> ffi.C.sem_trywait(handle) == 0
    lockImpl    = (handle) -> ffi.C.sem_wait handle
    unlockImpl  = (handle) -> ffi.C.sem_post handle
    closeImpl   = (name, handle, unlink) ->
        ffi.C.sem_close handle
        -- Other process's already-open handles keep working after an unlink
        -- but a subsequent *new* open with the same name would create a new
        -- semaphore with a value entirely separate from the old one, resulting
        -- in multiple handles thinking they hold the lock.
        ffi.C.sem_unlink name if unlink


---A non-reentrant binary semaphore identified by a name.
---Usable as a per-process or cross-process lock primitive.
---@class NamedSemaphore
class NamedSemaphore
    -- whether the OS semaphore FFI is isAvailable at all on this platform/build
    @isAvailable = isAvailable

    -- this process's id, exposed so callers can build process-scoped names and holder records
    @pid = pid

    ---Gets a handle to the named semaphore for the given token, creating it if it doesn't exist.
    ---@param token string A name token restricted to [A-Za-z0-9_].
    ---@param unlinkOnClose? boolean POSIX-only: remove the OS name when this instance is garbage-collected.
    ---Use true for process-private names so a reused PID can't inherit a stale semaphore.
    ---Use false for cross-process usage to prevent an exiting process from removing a name others still hold.
    ---No effect on Windows, where names are cleaned up automatically when the last handle closes.
    new: (token, unlinkOnClose = false) =>
        assert isAvailable, msgs.noImplementation

        @name   = formatName token
        @handle = openImpl @name
        @isOpen = isOpenImpl @handle
        return unless @isOpen

        -- close the OS handle when this object is garbage-collected.
        name, handle, unlink = @name, @handle, unlinkOnClose
        canary = newproxy true
        (getmetatable canary).__gc = -> pcall closeImpl, name, handle, unlink
        @_canary = canary

    ---Attempts to acquire without blocking.
    ---@return boolean acquired True if the semaphore was acquired.
    tryLock: => @isOpen and tryLockImpl(@handle) or false

    ---Blocks until the semaphore is acquired.
    ---@return boolean issued True if a wait was issued (false only when unavailable).
    lock: =>
        return false unless @isOpen
        lockImpl @handle
        true

    ---Releases one unit of the semaphore. Safe to call only by the current holder.
    ---@return boolean issued True if a release was issued.
    unlock: =>
        return false unless @isOpen
        unlockImpl @handle
        true

return NamedSemaphore
