ffi = require "ffi"
lfs = require "lfs"
constants = require "l0.DependencyControl.Constants"
Logger = require "l0.DependencyControl.Logger"
Common = require "l0.DependencyControl.Common"
Crypto = require "l0.DependencyControl.Crypto"
Enum   = require "l0.DependencyControl.Enum"

ENOENT = 2 -- POSIX error code for "No such file or directory"
ENOTDIR = 20 -- POSIX error code for "Not a directory"
ERROR_PATH_NOT_FOUND = 3 -- Windows error code for "The system cannot find the path specified"

local ConfigView

--- Filesystem utility helpers used by DependencyControl.
-- @class FileOps
class FileOps
    msgs = {
            generic: {
                deletionRescheduled: "Another deletion attempt has been rescheduled for the next restart."
            }
            attributes: {
                badPath: "Path failed verification: %s."
                genericError: "Can't retrieve attributes: %s."
                noAttribute: "Can't find attribute with name '%s'."
            }

            createConfig: {
                handlerFailed: "Couldn't create ConfigHandler for the FileOps configuration file: %s"
            },
            createTempDir: {
                failedCreate: "Failed to create temporary directory: %s"
            }
            mkdir: {
                createError: "Error creating directory: %s."
                otherExists: "Couldn't create directory because a %s of the same name is already present."
            }
            copy: {
                genericError: "An error occurred while copying file '%s' to '%s':\n%s"
                dirCopyUnsupported: "Copying directories is currently not supported."
                missingSource: "Couldn't find source file '%s'."
                openError: "Couldn't open %s file '%s' for reading: \n%s"
            },
            exists: {
                doesntExist: "No such file or directory: '%s'."
                wrongType: "Expected %s to be a %s but found a %s."
            }
            listDir: {
                notADirectory: "Can only list directories but supplied path '%s' points to a %s."
            },
            joinPath: {
                invalidSegment: "Invalid path segment type: expected a string or pure array table, got '%s'."
            }
            move: {
                inUseTryingRename: "Target file '%s' already exists and appears to be in use. Trying to rename and delete existing file..."
                renamedDeletionFailed: "The existing file was successfully renamed to '%s', but couldn't be deleted (%s).\n%s"
                overwritingFile: "File '%s' already exists, overwriting..."
                createdDir: "Created target directory '%s'."
                exists: "Couldn't move file '%s' to '%s' because a %s of the same name is already present."
                genericError: "An error occurred while moving file '%s' to '%s':\n%s"
                createDirError: "Could not create target directory for '%s': %s"
                cantRemove: "Couldn't overwrite file '%s': %s. Attempts at renaming the existing target file failed."
                cantRenameTryingCopy: "Move operation failed to rename '%s' to '%s' (%s), trying copy+remove instead..."
                couldntRemoveFiles: "Move operation succeeded to copied the file(s) to the target location, but some of the source files couldn't be removed:\n%s\n%s"
                cantCopy: "Move operation failed to copy '%s' to '%s' (%s) after a failed rename attempt (%s)."
            }
            readFile: {
                cantOpen: "Couldn't open file '%s' for reading: %s"
                cantRead: "An error occurred while trying to read from file '%s': %s"
                notAFile: "Can only read files but supplied path '%s' points to a %s."
            }
            writeFile: {
                cantOpen: "Couldn't open file '%s' for writing: %s"
                failedWrite: "An error occurred while trying to write to file '%s': %s",
                notAFile: "Can only write to files but supplied path '%s' points to a %s.",
                targetExists: "Target file '%s' already exists."
            }
            verifyHash: {
                badHash: "Argument #2 (hash) must be a string, got '%s'."
                mismatch: "Hash mismatch. Got %s, expected %s."
            }
            remove: {
                noConfigReschedule: "Couldn't load the FileOps config file (%s) - deletions of %s cannot be rescheduled!"
            }
            rmdir: {
                emptyPath: "Argument #1 (path) must not be an empty string."
                couldntRemoveFiles: "Some of the files and folders in the specified directory couldn't be removed:\n%s"
                couldntRemoveDir: "Error removing empty directory: %s."

            }
            runScheduledRemoval: {
                noConfigReschedule: "Couldn't load the FileOps config file (%s) - rescheduled deletions will not be performed!"
            }
            getNamespacedPath: {
                badBasePath: "Provided base path '%s' is not a valid full path (%s)."
                badPath: "Could not generate a valid full path from base path '%s' and namespaced sub-path '%s': %s."
            }
            validateFullPath: {
                badType: "Argument #%s (%s) had the wrong type. Expected 'string', got '%s'."
                tooLong: "The specified path exceeded the maximum length limit (%d > %d)."
                invalidChars: "The specified path contains one or more invalid characters: '%s'."
                reservedNames: "The specified path contains reserved path or file names: '%s'."
                parentPath: "Accessing parent directories is not allowed."
                notFullPath: "The specified path is not a valid full path."
                missingExt: "The specified path is missing a file extension."
        }
    }

    windowsReservedNameSet = {n, true for n in *{
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
    }}
    @pathSep = ffi.os == "Windows" and "\\" or "/"
    @pathMatch = {
        sep: ffi.os == "Windows" and "\\" or "/"
        sepAll: ffi.os == "Windows" and "[\\/]" or "/"
        invalidChars: '[<>:"|%?%*%z%c;]'
    }
    -- supported file hash algorithms, keyed by HashType value
    HashType = Enum "FileOpsHashType", { SHA1: "sha1" }
    @HashType = HashType
    hashAlgorithms = { [HashType.SHA1]: Crypto.sha1 }
    @logger = Logger!
    @pathMaxLength = ffi.os == "Windows" and 260 or 4096

    createConfig = (noLoad, configDir) ->
        FileOps.configDir = configDir if configDir
        ConfigView or= require "#{constants.DEPCTRL_NAMESPACE}.ConfigView"
        unless FileOps.config
            FileOps.config = ConfigView\get "#{FileOps.configDir}/#{constants.DEPCTRL_NAMESPACE}.json",
                               nil, {toRemove: {}}, FileOps.logger, noLoad
            return nil, msgs.createConfig.handlerFailed\format "constructor returned nil" unless FileOps.config
        return FileOps.config

    --- Creates a unique temporary directory and returns its path.
    -- @return string? tempDirPath absolute path to the created temporary directory or nil if the directory couldn't be created
    -- @return string? err error message if the directory couldn't be created
    createTempDir: () ->
        tempDir = FileOps.getTempDir()
        res, dir = FileOps.mkdir tempDir
        return tempDir if res
        return nil, msgs.createTempDir.failedCreate\format err 

    --- Generates a unique temporary file path.
    -- @return string tempFilePath absolute path to a unique temporary directory that does not exist yet
    getTempDir: () ->
        return aegisub.decode_path "?temp/#{constants.DEPCTRL_NAMESPACE}_#{'%04X'\format math.random 0, 16^4-1}"

    --- Removes one or more files/directories and optionally reschedules failed removals.
    -- @param paths string|(string|string)[] path or paths to the files/directories to remove. If an array of paths is provided, each path can be specified as a string or an array of path segments.
    -- @param[opt] recurse boolean
    -- @param[opt] reSchedule boolean
    -- @return boolean|nil overallSuccess
    -- @return table details
    -- @return string|nil firstErr
    remove: (paths, recurse, reSchedule) ->
        config, configLoaded, overallSuccess, details, firstErr = nil, false, true, {}
        paths = {paths} unless type(paths) == "table"

        for path in *paths
            mode, path = FileOps.attributes path, "mode"
            if mode
                rmFunc = mode == "file" and os.remove or FileOps.rmdir
                res, err = rmFunc path, recurse
                unless res
                    firstErr or= err
                    unless reSchedule -- delete operation failed entirely
                        details[path] = {nil, err}
                        overallSuccess = nil
                        continue

                    -- load the FileOps configuration file and reschedule deletions
                    unless configLoaded
                        config, msg = createConfig true
                        if config
                            FileOps.config\load!
                            configLoaded = true
                        else
                            FileOps.logger\warn msgs.remove.noConfigReschedule, msg, FileOps.logger\dumpToString paths
                            details[path] = {nil, err}
                            overallSuccess = nil
                            continue

                    config.c.toRemove[path] = os.time!
                    -- mark the operations as failed "for now", indicating a second attempt has been scheduled
                    details[path] = {false, err}
                    overallSuccess = false

                -- delete operation succeeded
                else details[path] = {true}
            -- file not found or permission issue
            else details[path] = {nil, path}

        config\write! if configLoaded
        return overallSuccess, details, firstErr

    --- Replays removals previously scheduled by @{FileOps:remove}.
    -- @param[opt] configDir string
    -- @return boolean
    -- @return string|nil err
    runScheduledRemoval: (configDir) ->
        config, msg = createConfig false, configDir
        unless config
            msg = msgs.runScheduledRemoval.noConfigReschedule\format msg
            FileOps.logger\warn msg
            return nil, msg
        paths = [path for path, _ in pairs config.c.toRemove]
        if #paths > 0
            -- rescheduled removals will not be rescheduled another time
            FileOps.remove paths, true
            config.c.toRemove = {}
            config\write!
        return true

    --- Copies a file to a target path.
    -- @param source string
    -- @param target string
    -- @return boolean success
    -- @return string|nil err
    copy: ( source, target, clobber ) ->
        -- source check
        mode, sourceFullPath, _, _, fileName = FileOps.attributes source, "mode"
        switch mode
            when "directory"
                return false, msgs.copy.dirCopyUnsupported
            when nil
                return false, msgs.copy.genericError\format source, target, sourceFullPath
            when false
                return false, msgs.copy.missingSource\format source

        -- target check
        checkTarget = (target) ->
            mode, targetFullPath = FileOps.attributes target, "mode"
            switch mode
                when "file"
                    return false, msgs.writeFile.targetExists\format target unless clobber
                when nil
                    return false, msgs.copy.genericError\format source, target, targetFullPath
                when "directory"
                    target ..= "/#{fileName}"
                    return checkTarget target
            return true, targetFullPath

        success, targetFullPath = checkTarget target
        return false, targetFullPath unless success

        input, msg = io.open sourceFullPath, "rb"
        unless input
            return false, msgs.copy.openError\format "source", sourceFullPath, msg

        output, msg = io.open targetFullPath, "wb"
        unless output
            input\close!
            return false, msgs.copy.openError\format "target", targetFullPath, msg

        success, msg = output\write input\read "*a"
        input\close!
        output\close!

        if success
            return true
        else
            return false, msgs.copy.genericError\format sourceFullPath, targetFullPath, msg

    listDir: (dirPath) ->
        mode, fullPath = FileOps.attributes dirPath, "mode"
        return nil, msgs.listDir.notADirectory\format fullPath, mode if mode != "directory"
        return [entry for entry in lfs.dir(fullPath) when entry != "." and entry != ".."]

    --- Joins and resolves multiple path segments into a single path string.
    -- @param ... string|string[] one or more path segments, or arrays of path segments
    -- @return string joinedPath the path segments joined by os-specific path separators
    joinPath: (...) ->
        args = {...}
        -- detect root from the first string before splitting consumes separators
        firstStr = type(args[1]) == "table" and args[1][1] or args[1]
        return nil, msgs.joinPath.invalidSegment\format type firstStr if type(firstStr) ~= "string"
        absolutePathRoot = type(firstStr) == "string" and FileOps.getPathRoot firstStr

        invalidPathSegmentType = nil
        flatPathSegments = Common.flatten args, 3, (value, typ) ->
            if typ != "string"
                invalidPathSegmentType = typ
                return nil

            firstSegment, moreSegments = nil, nil
            for segment in FileOps.pathSegments value
                if firstSegment
                    moreSegments or= {firstSegment}
                    table.insert moreSegments, segment
                else firstSegment = segment
            return moreSegments or firstSegment, moreSegments
        return nil, msgs.joinPath.invalidSegment\format invalidPathSegmentType if invalidPathSegmentType

        -- filter extraneous '.', resolve '..', and clamp path traversal at root
        segments = {}
        for i, segment in ipairs flatPathSegments
            switch segment
                when "."  then segments[#segments + 1] = segment if i == 1 and not absolutePathRoot
                when ".."
                    if #segments > (absolutePathRoot and 1 or 0) and segments[#segments] != ".."
                        segments[#segments] = nil
                    elseif not absolutePathRoot
                        segments[#segments + 1] = segment
                else segments[#segments + 1] = segment
        -- re-add root separator for absolute paths on POSIX systems removed by splitting
        return "#{absolutePathRoot and ffi.os != "Windows" and FileOps.pathSep or ""}#{table.concat segments, FileOps.pathSep}"

    --- Returns an iterator over the non-empty components of a path, split on any separator.
    -- @tparam string path
    -- @return iterator
    pathSegments: (path) -> path\gmatch "[^/\\]+"

    --- Moves a file to a target path, optionally replacing existing targets.
    -- @param source string
    -- @param target string
    -- @param[opt] overwrite boolean
    -- @return boolean success
    -- @return string|nil err
    move: (source, target, overwrite) ->
        mode, err = FileOps.attributes target, "mode"
        if mode == "file"
            unless overwrite
                return false, msgs.move.exists\format source, target, mode
            FileOps.logger\trace msgs.move.overwritingFile, target
            res, _, err = FileOps.remove target
            unless res
                -- can't remove old target file, probably in use or lack of permissions
                -- try to rename and then delete it
                FileOps.logger\debug msgs.move.inUseTryingRename, target
                junkName = "#{target}.depCtrlRemoved"
                -- There might be an old removed file we couldn't delete before
                FileOps.remove junkName
                res = os.rename target, junkName
                unless res
                    return false, msgs.move.cantRemove\format target, err
                -- rename succeeded, now clean up after ourselves
                res, _, err = FileOps.remove junkName, false, true
                unless res
                    FileOps.logger\debug msgs.move.renamedDeletionFailed, junkName, err, msgs.generic.deletionRescheduled

        elseif mode -- a directory (or something else) of the same name as the target file is already present
            return false, msgs.move.exists\format source, target, mode
        elseif mode == nil  -- if retrieving the attributes of a file fails, something is probably wrong
            return false, msgs.move.genericError\format source, target, err

        else -- target file not found, check directory
            res, dirOrErr = FileOps.mkdir target, true, true
            if res == nil
                return false, msgs.move.createDirError\format source, target, dirOrErr
            elseif res
                FileOps.logger\trace msgs.move.createdDir, dirOrErr

        -- at this point the target directory exists and the target file doesn't, move the file
        res, err = os.rename source, target
        unless res
            -- renaming the file failed, could be because of a permission issue
            -- but me might a well be trying to rename over file system boundaries on *nix
            -- so we should try copy + remove before giving up
            FileOps.logger\debug msgs.move.cantRenameTryingCopy, source, target, err
            renErr, res, err = err, FileOps.copy source, target
            unless res
                return false, msgs.move.cantCopy\format source, target, err, renErr
            res, details = FileOps.remove source, false, true  -- TODO: also support directories/recursion, but also require copy to support it

            unless res
                fileList = table.concat ["#{path}: #{res[2]}" for path, res in pairs details when not res[1]], "\n"
                FileOps.logger\debug msgs.move.couldntRemoveFiles, fileList, msgs.generic.deletionRescheduled

        return true

    --- Reads and returns the full contents of a file.
    -- @param path string|string[] path or path segments to the file to read
    -- @return string? data the contents of the file, or nil if an error occurred
    -- @return string? err an error message if an error occurred, or nil if the file was read successfully
    readFile: (path) ->
        mode, fullPath = FileOps.attributes path, "mode"
        return nil, msgs.readFile.cantOpen\format path, fullPath unless mode
        return nil, msgs.readFile.notAFile\format path, mode if mode != "file"

        handle, msg = io.open fullPath, "rb"
        return nil, msgs.readFile.cantOpen\format fullPath, msg unless handle

        data, msg = handle\read "*a"
        handle\close!

        if data
            return data
        else return nil, msgs.readFile.cantRead\format path, msg
    
    --- Writes data to a file, creating the file if it doesn't exist and optionally overwriting existing files.
    -- @param path string|string[] path or path segments to the file to write
    -- @param data string the data to write to the file
    -- @param[opt=false] clobber boolean whether to overwrite the file if it already exists
    -- @return boolean success true if the file was written successfully
    writeFile: (path, data, clobber = false) ->
        mode, fullPath = FileOps.attributes path, "mode"
        return false, msgs.writeFile.notAFile\format path, mode if mode and mode ~= "file"
        return false, msgs.writeFile.targetExists\format path if mode == "file" and not clobber

        handle, msg = io.open fullPath, "wb"
        return false, msgs.writeFile.cantOpen\format fullPath, msg unless handle

        success, msg = handle\write data
        handle\close!
        return true if success
        return false, msgs.writeFile.failedWrite\format fullPath, msg

    --- Computes the hash of a file's contents.
    -- @param fileName string|string[] path or path segments to the file to hash
    -- @param[opt=HashType.SHA1] hashType FileOps.HashType the hash algorithm to use
    -- @return string? hexDigest the lowercase hex digest, or nil if an error occurred
    -- @return string? err an error message if an error occurred
    getHash: (fileName, hashType = HashType.SHA1) ->
        valid, err = HashType\validate hashType, "hashType"
        return nil, err unless valid
        data, readErr = FileOps.readFile fileName
        return nil, readErr unless data
        return hashAlgorithms[hashType] data

    --- Verifies that a file's contents match an expected hash.
    -- @param fileName string|string[] path or path segments to the file to verify
    -- @param hash string the expected hex digest (case-insensitive)
    -- @param[opt=HashType.SHA1] hashType FileOps.HashType the hash algorithm to use
    -- @return boolean? match true on match, false on mismatch, or nil on error
    -- @return string? err the mismatch detail or error message
    verifyHash: (fileName, hash, hashType = HashType.SHA1) ->
        return nil, msgs.verifyHash.badHash\format type hash unless type(hash) == "string"
        actual, err = FileOps.getHash fileName, hashType
        return actual, err unless actual
        return true if actual == hash\lower!
        return false, msgs.verifyHash.mismatch\format actual, hash

    rmdir: (path, recurse = true) ->
        return nil, msgs.rmdir.emptyPath if path == ""
        mode, path = FileOps.attributes path, "mode"
        return nil, msgs.rmdir.notPath unless mode == "directory"

        if recurse
            -- recursively remove contained files and directories
            toRemove = [FileOps.joinPath(path, file) for file in *FileOps.listDir path]
            res, details = FileOps.remove toRemove, true
            unless res
                fileList = table.concat ["#{path}: #{res[2]}" for path, res in pairs details when not res[1]], "\n"
                return nil, msgs.rmdir.couldntRemoveFiles\format fileList

        -- remove empty directory
        success, err = lfs.rmdir path
        unless success
            return nil, msgs.rmdir.couldntRemoveDir\format err

        return true

    -- Creates `dir` along with any missing parent directories, building the path up one
    -- segment at a time. Idempotent: levels that already exist are left untouched.
    -- @param dir string a validated, absolute directory path
    -- @return boolean|nil true on success, or nil on error
    -- @return string dirPathOrError the directory path on success, or an error message
    mkdirRecursive = (dir) ->
        -- preserve a leading separator so POSIX absolute paths keep their root
        accum, first = dir\match("^[/\\]") and FileOps.pathSep or "", true
        for segment in FileOps.pathSegments dir
            accum = first and accum .. segment or "#{accum}#{FileOps.pathSep}#{segment}"
            first = false
            continue if accum\match "^%a:$"   -- skip bare drive letters like "C:"
            unless lfs.attributes accum, "mode"
                _, err = lfs.mkdir accum
                -- tolerate races and pre-existing levels; only fail if it's still absent
                if err and not lfs.attributes accum, "mode"
                    return nil, msgs.mkdir.createError\format err
        return true, dir

    --- Creates a directory.
    -- @param path string|string[] path or path segments to the directory to create
    -- @param isFile boolean whether the path is a file path (causes the last segment to be discarded when checking/creating the directory)
    -- @param[opt=false] recurse boolean whether to also create any missing parent directories
    -- @return boolean true if the directory was created, false if it already existed, or nil if an error occurred
    -- @return string dirPathOrError the path to the existing or created directory, or an error message if an error occurred
    mkdir: (path, isFile, recurse) ->
        mode, fullPath, dev, dir, file = FileOps.attributes path, "mode"
        dir = isFile and table.concat({dev,dir or file}) or fullPath

        if mode == nil
            return nil, msgs.attributes.genericError\format fullPath
        elseif not mode
            return mkdirRecursive dir if recurse
            res, err = lfs.mkdir dir
            if err -- can't create directory (possibly a permission error)
                return nil, msgs.mkdir.createError\format err
            return true, dir
        elseif isFile and mode == "file" -- if the file already exists, so does the directory
            return false, dir
        elseif mode != "directory" -- a file of the same name as the target directory is already present
            return nil, msgs.mkdir.otherExists\format mode
        return false, dir

    --- Retrieves file or directory attributes.
    -- @param path string|string[] Either a path or an array of path segments
    -- @param key string|nil attribute name to retrieve (e.g. "mode", "size", "modification"), or nil to retrieve the full attribute table
    -- @return table|string|number|boolean|nil attr the requested attribute(s), or nil if an error occurred
    -- @return string fullPath the validated full path to the file or directory, or an error message if the path was invalid
    -- @return string? device the device component of the path, or nil if the path was invalid
    -- @return string? dir the directory component of the path, or nil if the path was invalid
    -- @return string? file the file name component of the path, or nil if the path was invalid or pointed to
    attributes: (path, key) ->
        fullPath, dev, dir, file = FileOps.validateFullPath path, false, lfs.currentdir!
        unless fullPath
            return nil, msgs.attributes.badPath\format dev

        attr, err, errCode = lfs.attributes fullPath, key
        if attr
            return attr, fullPath, dev, dir, file
        -- Aegisub's lfs implementation signals a non-existent file/dir with a bare nil, 
        -- while the stock library (https://lunarmodules.github.io/luafilesystem/; v1.7.0+)
        -- returns an error code alongside an error message
        elseif err == nil or errCode == ENOENT or errCode == ERROR_PATH_NOT_FOUND or errCode == ENOTDIR
            return false, fullPath, dev, dir, file
        else
            return nil, msgs.attributes.genericError\format err

    --- Checks whether a file or directory exists and optionally verifies its type.
    -- @param path string|string[] Either a path or an array of path segments
    -- @param expectedMode string|nil If specified, the type of the file system entry
    -- @return boolean exists true if the file or directory exists and matches the expected type, false if it doesn't exist or doesn't match the expected type, or nil if an error occurred while checking the file
    -- @return string|nil err an error message if the file doesn't exist or is of the wrong type
    exists: (path, expectedMode) ->
        mode, fullPathOrErrMsg = FileOps.attributes path, "mode"
        switch mode
            when nil then return nil, fullPathOrErrMsg
            when false then return false, msgs.exists.doesntExist\format fullPathOrErrMsg
            else
                return true if not expectedMode or mode == expectedMode                 
                return false, msgs.exists.wrongType\format fullPathOrErrMsg, expectedMode, mode
            
                
    getPathRoot: (absolutePath) ->
        return absolutePath\match "^[A-Za-z]:[/\\]" if ffi.os == "Windows"
        return absolutePath\match "^/[^/\\]+"

    --- Validates and normalizes an absolute filesystem path.
    -- @param path string|string[] Either a path or an array of path segments
    -- @param[opt] checkFileExt boolean
    -- @param[opt] basePath string|string[] Optional base path to resolve relative paths against. If not provided, relative paths will be rejected.
    -- @return string|nil normalizedPath
    -- @return string|nil err
    -- @return string|nil device
    -- @return string|nil dir
    -- @return string|nil file
    validateFullPath: (path, checkFileExt, basePath) ->
        if "table" == type path
            path, errMsg = FileOps.joinPath path
            return nil, errMsg if not path
        elseif "string" != type path
            return nil, msgs.validateFullPath.badType\format 1, "path", type(path)

        if "table" == type basePath
            basePath, errMsg = FileOps.joinPath basePath
            return nil, errMsg if not basePath
        elseif basePath and "string" != type basePath
            return nil, msgs.validateFullPath.badType\format 3, "basePath", type(basePath)
            
        -- expand aegisub path specifiers
        path = aegisub.decode_path path
        -- expand home directory on linux
        homeDir = os.getenv "HOME"
        path = path\gsub "^~", "#{homeDir}/" if homeDir
        -- use single native path separators
        path = path\gsub "[\\/]+", FileOps.pathSep
        -- check length
        if #path > FileOps.pathMaxLength
            return nil, msgs.validateFullPath.tooLong\format #path, FileOps.pathMaxLength
        -- check for invalid characters
        invChar = path\match FileOps.pathMatch.invalidChars, ffi.os == "Windows" and 3 or nil
        if invChar
            return nil, msgs.validateFullPath.invalidChars\format invChar
        -- check if path is absolute
        dev = FileOps.getPathRoot path
        unless dev
            -- make relative paths absolute if base path is provided
            if basePath
                path, errMsg = FileOps.joinPath basePath, path
                return nil, errMsg if not path
                dev = FileOps.getPathRoot path
            else return false, msgs.validateFullPath.notFullPath
        -- parse path structure
        rest = path\sub #dev + 1
        dir, file = rest\match "^(.*)[/\\]([^/\\]*)$"
        unless dir
            return false, msgs.validateFullPath.notFullPath
        for segment in FileOps.pathSegments rest
            if ffi.os == "Windows"
                segmentWithoutExt = segment\match("^[^%.]+") or segment
                if windowsReservedNameSet[segmentWithoutExt\upper!]
                    return nil, msgs.validateFullPath.reservedNames\format segmentWithoutExt
            unless segment\match "[^%.%s]$"
                return nil, msgs.validateFullPath.notFullPath
        file = file != "" and file or nil
        if checkFileExt and not (file and file\match ".+%.+")
            return false, msgs.validateFullPath.missingExt

        path = table.concat {dev, dir, file and FileOps.pathSep, file}
        return path, dev, dir, file

    --- Converts a base path and namespace into a namespaced filesystem path.
    -- Dots in the namespace are converted to path separators when nested is true.
    -- @param basePath string|string[] base path or path segments to the directory under which the namespaced path should be created
    -- @param namespace string
    -- @param ext string file extension (including dot)
    -- @param[opt=true] nested boolean
    -- @return string|nil path
    -- @return string|nil err
    getNamespacedPath: (basePath, namespace, ext, nested = true) ->
        res, msg = Common.validateNamespace namespace
        return nil, msg unless res

        fullBasePath, msg = FileOps.validateFullPath basePath
        return nil, msgs.getNamespacedPath.badBasePath\format basePath, msg unless fullBasePath

        namespacePath = "#{nested and namespace\gsub("%.", FileOps.pathSep) or namespace}#{ext}"
        normalizedFullPath, msg = FileOps.validateFullPath namespacePath, false, fullBasePath
        return nil, msgs.getNamespacedPath.badPath\format fullBasePath, namespacePath, msg unless normalizedFullPath

        return normalizedFullPath
