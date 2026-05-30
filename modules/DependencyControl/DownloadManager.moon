-- DM.DownloadManager-compatible download manager: a class that wraps DepCtrl's own
-- Downloader engine to replicate the native DM.DownloadManager API.
-- DependencyControl registers it as a provider for the "DM.DownloadManager" alias (see
-- ModuleProvider), so it's used wherever the native library isn't installed; native takes
-- precedence by default, and DEPCTRL_PREFER_FFI_DOWNLOADER=1 forces this implementation.

Downloader = require "l0.DependencyControl.Downloader"
FileOps    = require "l0.DependencyControl.FileOps"
Crypto     = require "l0.DependencyControl.Crypto"

msgs = {
    checkMissingArgs: "Required arguments had the wrong type. Expected string, got '%s' and '%s'."
    hashMismatch:     "Hash mismatch. Got %s, expected %s."
}

--- A download manager replicating the DM.DownloadManager API on top of the
-- DepCtrl Downloader engine.
-- @class DownloadManager
class DownloadManager
    -- Matches the DM.DownloadManager dependency version declared in DependencyControl.moon
    -- so DepCtrl accepts this implementation without a full managed record.
    @version = "0.3.1"

    --- @param[opt] etagCacheDir string accepted for API compatibility; ETag caching is not implemented
    new: (etagCacheDir) =>
        @downloader = Downloader!
        -- the native API exposes .downloads directly; Downloader.clear empties it in
        -- place, so this reference stays valid. .failedDownloads is rebuilt per run.
        @downloads       = @downloader.downloads
        @failedDownloads = {}

    --- Queues a download, optionally verifying its SHA-1 once complete.
    -- @param url string
    -- @param outfile string full output path
    -- @param[opt] sha1 string expected SHA-1 hash
    -- @param[opt] etag string accepted for API compatibility; ignored
    -- @return table|nil download
    -- @return string|nil err
    addDownload: (url, outfile, sha1, etag) =>
        @downloader\addDownload url, outfile, sha1

    --- Performs all queued downloads (DM.DownloadManager-compatible).
    -- @param[opt] callback function(progress) called with 0-100; returning a falsy
    --   value cancels remaining downloads. Bridged to the engine's Progress event.
    waitForFinish: (callback) =>
        if callback
            -- bridge the DM-style cancel-capable callback onto the Progress event
            onProgress = (_, percent) -> @downloader\cancel! unless callback percent
            @downloader\on Downloader.Event.Progress, onProgress
            @downloader\await!
            @downloader\off Downloader.Event.Progress, onProgress
            callback 100 unless @downloader.cancelled
        else
            @downloader\await!
        -- rebuild the native-style failedDownloads list from each download's status
        failed = Downloader.Download.Status.Failed
        @failedDownloads = [dl for dl in *@downloads when dl.status == failed]
        return

    --- @return number current aggregate progress (0-100)
    progress: => @downloader\progress!

    cancel: => @downloader\cancel!
    clear:  => @downloader\clear!

    --- @return boolean whether an internet connection appears to be available
    isInternetConnected: => @downloader\isInternetConnected!

    --- Computes the SHA-1 of a file's contents.
    -- @return string|nil hexDigest
    -- @return string|nil err
    getFileSHA1: (filename) => FileOps.getHash filename, "sha1"

    --- Verifies a file against an expected SHA-1 hash.
    -- @return boolean|nil match
    -- @return string|nil err
    checkFileSHA1: (filename, expected) => FileOps.verifyHash filename, expected, "sha1"

    --- Verifies a string against an expected SHA-1 hash.
    -- @return boolean|nil match
    -- @return string|nil err
    checkStringSHA1: (str, expected) =>
        return nil, msgs.checkMissingArgs\format type(str), type(expected) unless type(expected) == "string"
        actual, err = Crypto.sha1 str   -- Crypto validates the payload type
        return actual, err unless actual
        return true if actual == expected\lower!
        false, msgs.hashMismatch\format actual, expected

return DownloadManager
