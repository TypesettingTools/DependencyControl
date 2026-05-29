-- Non-blocking download manager with SHA-1 verification (pure FFI implementation).
-- This is DepCtrl's own downloader; the l0.DependencyControl.DownloadManager wrapper
-- decides whether to use this or the native DM.DownloadManager library.
--
--   macOS/Linux: libcurl multi interface — parallel, scheduled by libcurl
--   Windows:     WinINet driver multiplexed by our round-robin scheduler (parallel)
--
-- The round-robin scheduler (`multiplex`) is decoupled from the transfer mechanism
-- via a driver interface {start, step, finish, shutdown}, so our scheduling and
-- orchestration logic can be unit-tested with a fake driver (no network).
--
-- Downloads are queued with addDownload and run by await. Subscribe to progress
-- and completion via the Download / Downloader event APIs (on/off). ETag caching
-- is not implemented.

ffi = require "ffi"
lfs = require "lfs"
Enum    = require "l0.DependencyControl.Enum"
FileOps = require "l0.DependencyControl.FileOps"

msgs = {
    addMissingArgs:  "Required arguments #1 (url) and #2 (outfile) had the wrong type. Expected string, got '%s' and '%s'."
    failedToOpen:    "Could not open file '%s'."
    noBackend:       "No download backend available."
    httpStatus:      "Server returned HTTP status %d."
    readFailed:      "Connection error while reading response."
    openUrlFailed:   "Could not open URL '%s'."
    curlInit:        "Failed to initialize curl."
}

-- Lifecycle state of a single download.
DownloadStatus = Enum "DownloadStatus", {
    Queued:    "queued"     -- created, not yet started
    Active:    "active"     -- transfer in progress
    Finished:  "finished"   -- completed successfully
    Failed:    "failed"     -- completed with an error
    Cancelled: "cancelled"  -- cancelled before completion
}
-- statuses representing a download that is no longer in flight
isTerminalStatus = {
    [DownloadStatus.Finished]:  true
    [DownloadStatus.Failed]:    true
    [DownloadStatus.Cancelled]: true
}

-- Reports progress by emitting the downloader's Progress event, then returns
-- whether to keep going (a Progress listener may call cancel! to stop).
report = (manager, progress) ->
    manager\_reportProgress progress
    not manager.cancelled

-- Backend-agnostic aggregate progress (0-100) from per-download state.
-- Relies on dl.bytesReceived / dl.totalBytes / dl.status, which every runner maintains.
computeProgress = (downloads) ->
    total, now, allKnown, done = 0, 0, true, 0
    for dl in *downloads
        if isTerminalStatus[dl.status]
            done += 1
            total += dl.bytesReceived or 0
            now   += dl.bytesReceived or 0
        else
            if dl.totalBytes and dl.totalBytes > 0
                total += dl.totalBytes
                now   += dl.bytesReceived or 0
            else
                allKnown = false
    if total > 0 and allKnown
        math.floor 100 * now / total
    else
        math.floor 100 * done / math.max #downloads, 1

-- Generic round-robin scheduler over a driver. This is the core scheduling logic
-- (the Windows production path, and the unit-tested path via a fake driver).
-- driver = {
--   start(dl)  -> true | (false, errString)  -- begin one transfer; set dl.totalBytes if known
--   step(dl)   -> "more" | "done" | errString -- advance one chunk; update dl.bytesReceived
--   finish(dl) ->                             -- release one transfer's resources (idempotent)
--   shutdown() ->                             -- optional: release shared resources
-- }
multiplex = (manager, driver) ->
    downloads = manager.downloads
    active = {}
    for dl in *downloads
        dl.bytesReceived = 0
        ok, err = driver.start dl
        if ok
            dl.status = DownloadStatus.Active
            active[#active + 1] = dl
        else
            dl\_complete err or "failed to start download"

    -- one pass per loop iteration steps every still-active transfer exactly once
    while #active > 0 and not manager.cancelled
        remaining = {}
        for dl in *active
            if dl._cancelRequested
                driver.finish dl
                dl\_cancel!
            else
                status = driver.step dl
                if status == "more"
                    dl\_notifyProgress!
                    remaining[#remaining + 1] = dl
                elseif status == "done"
                    driver.finish dl
                    dl\_complete!
                else
                    driver.finish dl
                    dl\_complete status
        active = remaining
        break unless report manager, computeProgress downloads

    -- finalize any survivors as cancelled (whole-downloader cancellation)
    for dl in *active
        driver.finish dl
        dl\_cancel!
    driver.shutdown! if driver.shutdown

-- Platform backend selection: sets defaultRunner(manager) and isInternetConnected().
local defaultRunner, isInternetConnected

if ffi.os != "Windows"
    pcall ffi.cdef, "void* fopen(const char* path, const char* mode);"
    pcall ffi.cdef, "int fclose(void* stream);"
    pcall ffi.cdef, "int usleep(unsigned int usec);"
    pcall ffi.cdef, [[
        void* curl_easy_init(void);
        int curl_easy_setopt(void* handle, int option, ...);
        void curl_easy_cleanup(void* handle);
        int curl_easy_getinfo(void* handle, int info, ...);
        const char* curl_easy_strerror(int errornum);
        void* curl_multi_init(void);
        int curl_multi_add_handle(void* multi, void* easy);
        int curl_multi_remove_handle(void* multi, void* easy);
        int curl_multi_perform(void* multi, int* running);
        int curl_multi_wait(void* multi, void* extra_fds, unsigned int extra_nfds, int timeout_ms, int* numfds);
        void curl_multi_cleanup(void* multi);
        typedef struct CURLMsg {
            int msg;
            void* easy_handle;
            union { void* whatever; int result; } data;
        } CURLMsg;
        CURLMsg* curl_multi_info_read(void* multi, int* msgs_in_queue);
    ]]

    curlNames = ffi.os == "OSX" and {"libcurl.4.dylib", "libcurl.dylib", "curl"} or
                {"libcurl.so.4", "libcurl.so", "curl"}
    local curl
    for name in *curlNames
        loaded, lib = pcall ffi.load, name
        if loaded
            curl = lib
            break

    if curl
        CURLOPT_WRITEDATA      = 10001
        CURLOPT_URL            = 10002
        CURLOPT_USERAGENT      = 10018
        CURLOPT_FOLLOWLOCATION = 52
        CURLOPT_FAILONERROR    = 45
        CURLOPT_NOPROGRESS     = 43
        CURLOPT_CONNECTTIMEOUT = 78
        CURLINFO_SIZE_DOWNLOAD           = 0x300008
        CURLINFO_CONTENT_LENGTH_DOWNLOAD = 0x30000F
        CURLMSG_DONE = 1

        -- libcurl's varargs expect a C long for integer options; a bare Lua number
        -- would be passed as a double, so cast explicitly.
        setLong = (h, opt, v) -> curl.curl_easy_setopt h, opt, ffi.cast "long", v
        -- cdata pointers can't be table keys reliably; key by address string instead.
        key = (h) -> tostring ffi.cast "void *", h

        getDouble = (h, info) ->
            out = ffi.new "double[1]"
            curl.curl_easy_getinfo h, info, out
            tonumber out[0]

        -- Unix uses curl's own multi scheduler rather than our round-robin loop.
        defaultRunner = (manager) ->
            downloads = manager.downloads
            multi = curl.curl_multi_init!
            handleMap = {}

            for dl in *downloads
                dl.bytesReceived = 0
                file = ffi.C.fopen dl.outfile, "wb"
                if file == nil
                    dl\_complete msgs.failedToOpen\format dl.outfile
                    continue
                handle = curl.curl_easy_init!
                if handle == nil
                    ffi.C.fclose file
                    dl\_complete msgs.curlInit
                    continue
                curl.curl_easy_setopt handle, CURLOPT_URL, dl.url
                curl.curl_easy_setopt handle, CURLOPT_USERAGENT, "DependencyControl"
                curl.curl_easy_setopt handle, CURLOPT_WRITEDATA, file
                setLong handle, CURLOPT_FOLLOWLOCATION, 1
                setLong handle, CURLOPT_FAILONERROR, 1
                setLong handle, CURLOPT_NOPROGRESS, 1
                setLong handle, CURLOPT_CONNECTTIMEOUT, 30
                dl._handle, dl._file = handle, file
                dl.status = DownloadStatus.Active
                handleMap[key handle] = dl
                curl.curl_multi_add_handle multi, handle

            drain = ->
                pending = ffi.new "int[1]"
                while true
                    m = curl.curl_multi_info_read multi, pending
                    break if m == nil
                    continue unless m.msg == CURLMSG_DONE
                    dl = handleMap[key m.easy_handle]
                    continue unless dl
                    res = m.data.result
                    dl.bytesReceived = getDouble dl._handle, CURLINFO_SIZE_DOWNLOAD
                    ffi.C.fclose dl._file
                    curl.curl_multi_remove_handle multi, dl._handle
                    curl.curl_easy_cleanup dl._handle
                    dl._file, dl._handle = nil
                    transportError = res != 0 and ffi.string(curl.curl_easy_strerror res) or nil
                    dl\_complete transportError  -- fires finish callbacks (e.g. hash verification)

            -- releases an easy handle + its output file (idempotent)
            releaseHandle = (dl) ->
                ffi.C.fclose dl._file if dl._file
                curl.curl_multi_remove_handle multi, dl._handle
                curl.curl_easy_cleanup dl._handle
                dl._file, dl._handle = nil

            running = ffi.new "int[1]"
            running[0] = 1
            numfds = ffi.new "int[1]"
            while running[0] > 0
                curl.curl_multi_perform multi, running
                drain!
                for dl in *downloads
                    continue unless dl._handle
                    if dl._cancelRequested
                        releaseHandle dl
                        dl\_cancel!
                    else
                        dl.bytesReceived = getDouble dl._handle, CURLINFO_SIZE_DOWNLOAD
                        contentLen = getDouble dl._handle, CURLINFO_CONTENT_LENGTH_DOWNLOAD
                        dl.totalBytes = contentLen if contentLen > 0
                        dl\_notifyProgress!
                break unless report manager, computeProgress downloads
                if running[0] > 0
                    curl.curl_multi_wait multi, nil, 0, 100, numfds
                    ffi.C.usleep 10000 if numfds[0] == 0
            drain!

            -- finalize any survivors as cancelled (whole-downloader cancellation)
            for dl in *downloads
                if dl._handle
                    releaseHandle dl
                    dl\_cancel!
            curl.curl_multi_cleanup multi

    else
        defaultRunner = (manager) ->
            dl\_complete msgs.noBackend for dl in *manager.downloads

    isInternetConnected = -> true  -- best-effort: assume connected, let downloads report real errors

else
    pcall ffi.cdef, "int MultiByteToWideChar(unsigned int cp, unsigned long flags, const char* str, int cbMulti, wchar_t* wide, int cchWide);"
    pcall ffi.cdef, [[
        void* InternetOpenW(const wchar_t* agent, unsigned long accessType, const wchar_t* proxy, const wchar_t* proxyBypass, unsigned long flags);
        void* InternetOpenUrlW(void* session, const wchar_t* url, const wchar_t* headers, unsigned long headersLen, unsigned long flags, uintptr_t context);
        int InternetReadFile(void* hFile, void* buffer, unsigned long toRead, unsigned long* read);
        int InternetCloseHandle(void* h);
        int HttpQueryInfoW(void* hRequest, unsigned long infoLevel, void* buffer, unsigned long* bufferLen, unsigned long* index);
        int InternetGetConnectedState(unsigned long* flags, unsigned long reserved);
    ]]

    haveKernel32, kernel32 = pcall ffi.load, "kernel32"
    haveWinInet, winInet   = pcall ffi.load, "winInet"

    CP_UTF8 = 65001
    toWide = (s) ->
        n = kernel32.MultiByteToWideChar CP_UTF8, 0, s, -1, nil, 0
        buf = ffi.new "wchar_t[?]", n
        kernel32.MultiByteToWideChar CP_UTF8, 0, s, -1, buf, n
        buf

    INTERNET_FLAG_RELOAD         = 0x80000000
    INTERNET_FLAG_NO_CACHE_WRITE = 0x04000000
    HTTP_QUERY_STATUS_CODE       = 19
    HTTP_QUERY_CONTENT_LENGTH    = 5
    HTTP_QUERY_FLAG_NUMBER       = 0x20000000
    CHUNK = 16384

    queryNumber = (request, info) ->
        out = ffi.new "unsigned long[1]"
        len = ffi.new "unsigned long[1]"
        len[0] = 4
        ok = winInet.HttpQueryInfoW request, bit.bor(info, HTTP_QUERY_FLAG_NUMBER), out, len, nil
        ok != 0 and tonumber(out[0]) or nil

    if haveKernel32 and haveWinInet
        -- A WinINet driver for `multiplex`: one request + output file per download,
        -- advanced one chunk per step. The scheduler round-robins across them.
        makeWinINetDriver = ->
            session = winInet.InternetOpenW toWide("DependencyControl"), 0, nil, nil, 0
            buffer  = ffi.new "char[?]", CHUNK
            read    = ffi.new "unsigned long[1]"
            {
                start: (dl) ->
                    out, err = io.open dl.outfile, "wb"
                    return false, (err or msgs.failedToOpen\format dl.outfile) unless out
                    request = winInet.InternetOpenUrlW session, toWide(dl.url), nil, 0,
                        bit.bor(INTERNET_FLAG_RELOAD, INTERNET_FLAG_NO_CACHE_WRITE), 0
                    if request == nil
                        out\close!
                        return false, msgs.openUrlFailed\format dl.url
                    status = queryNumber request, HTTP_QUERY_STATUS_CODE
                    if status and status >= 400
                        winInet.InternetCloseHandle request
                        out\close!
                        return false, msgs.httpStatus\format status
                    dl._request, dl._out = request, out
                    dl.totalBytes = queryNumber request, HTTP_QUERY_CONTENT_LENGTH
                    true

                step: (dl) ->
                    return msgs.readFailed if 0 == winInet.InternetReadFile dl._request, buffer, CHUNK, read
                    n = tonumber read[0]
                    return "done" if n == 0
                    dl._out\write ffi.string buffer, n
                    dl.bytesReceived += n
                    "more"

                finish: (dl) ->
                    winInet.InternetCloseHandle dl._request if dl._request
                    dl._out\close! if dl._out
                    dl._request, dl._out = nil

                shutdown: ->
                    winInet.InternetCloseHandle session
            }

        defaultRunner = (manager) ->
            multiplex manager, makeWinINetDriver!

    else
        defaultRunner = (manager) ->
            dl\_complete msgs.noBackend for dl in *manager.downloads

    isInternetConnected = ->
        return true unless haveWinInet
        flags = ffi.new "unsigned long[1]"
        winInet.InternetGetConnectedState(flags, 0) != 0


--- Minimal event registration mixin: on(event, cb) / off(event, cb) / _emit(event, ...).
-- Subclasses provide an `@Event` Enum that defines the valid event values.
-- @class EventEmitter
class EventEmitter
    new: =>
        @_listeners = {}

    --- Registers a callback for an event.
    -- @param event the event value (a member of the subclass's @Event enum)
    -- @param callback function called with the emitter instance (plus any event args)
    -- @return self (for chaining)
    on: (event, callback) =>
        valid, err = @@Event\validate event, "event"
        error err unless valid
        listeners = @_listeners[event]
        unless listeners
            listeners = {}
            @_listeners[event] = listeners
        listeners[#listeners + 1] = callback
        return @

    --- Unregisters a previously-registered callback for an event.
    -- @param event the event value
    -- @param callback the exact callback passed to on
    -- @return self (for chaining)
    off: (event, callback) =>
        listeners = @_listeners[event]
        return @ unless listeners
        for i = #listeners, 1, -1
            table.remove listeners, i if listeners[i] == callback
        return @

    -- Invokes all listeners for an event with (self, ...). Iterates a snapshot so
    -- a listener may safely on/off during dispatch.
    _emit: (event, ...) =>
        listeners = @_listeners[event]
        return unless listeners
        cb @, ... for cb in *[l for l in *listeners]


--- A single download: its URL, output path, transfer state, and event callbacks.
-- Events (see Download.Event): Progress (data arrived), Finish (reached a terminal
-- status). A Finish listener may downgrade the status via markFailed (e.g. for a
-- failed hash verification). The current state is exposed via @status (Download.Status).
-- @class Download
class Download extends EventEmitter
    @Status = DownloadStatus
    @Event  = Enum "DownloadEvent", { Progress: "progress", Finish: "finish" }

    --- @param url string
    -- @param outfile string full output path
    -- @param[opt] id number an identifier assigned by the Downloader
    new: (@url, @outfile, @id) =>
        super!
        @bytesReceived = 0
        @totalBytes    = nil
        @status        = DownloadStatus.Queued
        @error         = nil

    --- Requests cancellation of this download. The downloader releases its
    -- resources and sets the status to Cancelled on its next scheduling pass.
    cancel: => @_cancelRequested = true

    --- Marks the download as failed (e.g. from a Finish listener performing
    -- hash verification).
    -- @param err string the failure reason
    markFailed: (err) =>
        @error = err
        @status = @@Status.Failed

    -- Runner-internal: fire Progress listeners.
    _notifyProgress: => @_emit @@Event.Progress

    -- Runner-internal: finalize the transfer (success or transport error) and fire
    -- Finish listeners (which may downgrade the status via markFailed).
    -- @param[opt] transportError string a transport-level error, if any
    _complete: (transportError) =>
        return if @_finalized
        @_finalized = true
        if transportError
            @error  = transportError
            @status = @@Status.Failed
        else
            @status = @@Status.Finished
        @_emit @@Event.Finish

    -- Runner-internal: finalize as cancelled and fire Finish listeners.
    _cancel: =>
        return if @_finalized
        @_finalized = true
        @status = @@Status.Cancelled
        @_emit @@Event.Finish


--- Manages a set of concurrent downloads. This is DepCtrl's own engine; the
-- DM.DownloadManager-compatible API lives in l0.DependencyControl.DownloadManager.
-- Events (see Downloader.Event): Progress (overall %), Finished (await completed).
-- @class Downloader
class Downloader extends EventEmitter
    @Download = Download
    @Event = Enum "DownloaderEvent", { Progress: "progress", Finished: "finished" }
    -- Exposed so tests (and custom runners) can drive the round-robin scheduler
    -- with an injected driver.
    @multiplex = multiplex

    --- Creates a downloader.
    -- @param[opt] runner function(downloader, callback) overrides the transfer implementation
    new: (runner) =>
        super!
        @downloads = {}
        @cancelled = false
        @_runner   = runner or defaultRunner

    --- Queues a download. Transfers happen later, in await.
    -- Register progress/finish listeners on the returned Download as needed.
    -- @param url string
    -- @param outfile string full output path (relative paths unsupported)
    -- @param[opt] sha1 string expected SHA-1 hash; verified automatically on finish
    -- @return Download|nil download
    -- @return string|nil err
    addDownload: (url, outfile, sha1) =>
        unless type(url) == "string" and type(outfile) == "string"
            return nil, msgs.addMissingArgs\format type(url), type(outfile)

        dir = outfile\match "^(.*[/\\])"
        lfs.mkdir dir if dir and lfs.attributes(dir, "mode") != "directory"

        @_lastId = (@_lastId or 0) + 1
        download = Download url, outfile, @_lastId

        if type(sha1) == "string"
            expected = sha1\lower!
            -- piggyback on the finish event to verify the downloaded file's hash
            download\on Download.Event.Finish, (dl) ->
                return unless dl.status == Download.Status.Finished  -- only verify successful transfers
                ok, msg = FileOps.verifyHash dl.outfile, expected, FileOps.HashType.SHA1
                dl\markFailed msg unless ok

        @downloads[#@downloads + 1] = download
        download

    --- Performs all queued downloads, blocking until they finish or are cancelled.
    -- Subscribe to Progress/Finished via on; a Progress listener may call cancel!.
    -- Inspect each download's final state via its @status (Download.Status).
    -- @return Downloader self (for chaining)
    await: =>
        @_runner @
        @_emit @@Event.Finished
        return @

    --- @return number current aggregate progress (0-100)
    progress: => computeProgress @downloads

    -- Runner-internal: emit the Progress event with the current overall percentage.
    _reportProgress: (percent) => @_emit @@Event.Progress, percent

    --- Cancels all remaining downloads (e.g. from within a Progress listener).
    cancel: => @cancelled = true

    --- Removes all downloads and resets state.
    -- Empties the array in place so external references stay valid.
    clear: =>
        @downloads[i] = nil for i = #@downloads, 1, -1
        @cancelled = false

    --- @return boolean whether an internet connection appears to be available
    isInternetConnected: => isInternetConnected!

return Downloader
