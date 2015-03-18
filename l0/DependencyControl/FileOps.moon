ffi = require "ffi"
re = require "aegisub.re"
Logger = require "l0.DependencyControl.Logger"

class FileOps
    msgs = {
            attributes: {
                badPath: "Path failed verification: %s."
                genericError: "Can't retrieve attributes: %s."
                noAttribute: "Can't find attriubte with name '%s'."
            }

            createDir: {
                createError: "Error creating directory: %s."
                otherExists: "Couldn't create directory because a %s of the same name is already present."
            }
            moveFile: {
                inUseTryingRename: "Target file '%s' already exists and appears to be in use. Trying to rename..."
                overwritingFile: "File '%s' already exists, overwriting..."
                createdDir: "Created target directory '%s'."
                existsNoFile: "Couldn't move file '%s' to '%s' because a %s of the same name is already present."
                genericError: "An error occured while moving file '%s' to '%s':\n%s"
                createDirError: "Moving '%s' to '%s' failed (%s)."
                cantRemove: "Couldn't overwrite file '%s': %s. Attempts at renaming the existing target file failed."
                cantRename: "Couldn't move file '%s' to '%s': %s"
            }
            validateFullPath: {
                badType: "Argument #1 (path) had the wrong type. Expected 'string', got '%s'."
                tooLong: "The specified path exceeded the maximum length limit (%d > %d)."
                invalidChars: "The specifed path contains one or more invalid characters: '%s'."
                reservedNames: "The specified path contains reserved path or file names: '%s'."
                parentPath: "Accessing parent directories is not allowed."
                notFullPath: "The specified path is not a valid full path."
                missingExt: "The specified path is missing a file extension."
        }
    }

    devPattern = ffi.os == "Windows" and "[A-Za-z]:" or "/[^\\\\/]+"
    pathMatch = {
        sep: ffi.os == "Windows" and "\\" or "/"
        pattern: re.compile "^(#{devPattern})((?:[\\\\/][^\\\\/]*[^\\\\/\\s\\.])*)[\\\\/]([^\\\\/]*[^\\\\/\\s\\.])?$"
        invalidChars: '[<>:"|%?%*%z%c;]'
        reservedNames: re.compile "[\\\\/](CON|COM[1-9]|PRN|AUX|NUL|LPT[1-9])(?:[\\\\/].*?)?$", re.ICASE
        maxLen: 255
    }
    @logger = Logger!

    moveFile: (source, target) ->
        mode, err = FileOps.attributes target, "mode"
        if mode == "file"
            FileOps.logger\trace msgs.moveFile.overwritingFile, target
            res, err = os.remove target
            unless res -- can't remove old target file, probably in use or lack of permissions
                FileOps.logger\debug msgs.moveFile.inUseTryingRename, target
                junkName = "#{target}.depCtrlRemoved"
                os.remove junkName
                res = os.rename target, junkName
                unless res
                    return false, msgs.moveFile.cantRemove\format target, err
        elseif mode -- a directory (or something else) of the same name as the target file is already present
            return false, msgs.moveFile.existsNoFile\format source, target, mode
        elseif mode == nil  -- if retrieving the attributes of a file fails, something is probably wrong
            return false, msgs.moveFile.genericError\format source, target, err

        else -- target file not found, check directory
            dir, err = FileOps.createDir target, true
            unless dir
                return false, msgs.moveFile.createDirError\format source, target, err
            FileOps.logger\trace msgs.moveFile.createdDir, dir

        -- at this point the target directory exists and the target file doesn't, move the file
        res, err = os.rename source, target
        unless res -- renaming the file failed, probably a permission issue
            return false, msgs.moveFile.cantRename, source, target, err

        return true


    createDir: (path, isFile) ->
        path, dev, dir, file = FileOps.validateFullPath path
        unless path
            return false, msgs.attributes.badPath\format dev
        dir = isFile and table.concat({dev,dir or file}) or path

        mode, err = lfs.attributes dir, "mode"
        if err
            return false, msgs.attributes.genericError\format err
        elseif not mode
            res, err = lfs.mkdir dir
            if err -- can't create directory (possibly a permission error)
                return false, msgs.createDir.createError\format err
        elseif mode != "directory" -- a file of the same name as the target directory is already present
            return false, msgs.createDir.otherExists\format mode
        return dir

    attributes: (path, key) ->
        path, dev, dir, file = FileOps.validateFullPath path
        unless path
            return nil, msgs.attributes.badPath\format dev

        attr, err = lfs.attributes path, key
        if err
            return nil, msgs.attributes.genericError\format err
        elseif not attr
            return false, path, dev, dir, file

        return attr, path, dev, dir, file

    validateFullPath: (path, checkFileExt) ->
        if type(path) != "string"
            return nil, msgs.validateFullPath.badType\format type(path)
        -- expand aegisub path specifiers
        path = aegisub.decode_path path
        -- expand home directory on linux
        homeDir = os.getenv "HOME"
        path = path\gsub "^~", "{#homeDir}/" if homeDir
        -- use single native path separators
        path = path\gsub "[\\/]+", pathMatch.sep
        -- check length
        if #path > pathMatch.maxLen
            return false, msgs.validateFullPath.tooLong\format #path, maxLen
        -- check for invalid characters
        invChar = path\match pathMatch.invalidChars, ffi.os == "Windows" and 3
        if invChar
            return false, msgs.validateFullPath.invalidChars\format invChar
        -- check for reserved file names
        reserved = pathMatch.reservedNames\match path
        if reserved
            return false, msgs.validateFullPath.reservedNames\format reserved[2].str
        -- check for path escalation
        if path\match "%.%."
            return false, msgs.validateFullPath.parentPath

        -- check if we got a valid full path
        matches = pathMatch.pattern\match path
        dev, dir, file = matches[2].str, matches[3].str, matches[4].str if matches
        unless dev
            return false, msgs.validateFullPath.notFullPath
        if checkFileExt and not (file and file\match ".+%.+")
            return false, msgs.validateFullPath.missingExt

        path = table.concat({dev, dir, file and pathMatch.sep, file})

        return path, dev, dir, file