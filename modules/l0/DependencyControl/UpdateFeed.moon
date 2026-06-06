json = require "json"

Logger            = require "l0.DependencyControl.Logger"
Common            = require "l0.DependencyControl.Common"
Enum              = require "l0.DependencyControl.Enum"
FileOps            = require "l0.DependencyControl.FileOps"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"

defaultLogger = Logger fileBaseName: "DepCtrl.UpdateFeed"
ScriptUpdateRecord = require "l0.DependencyControl.ScriptUpdateRecord"
ScriptTargetFilter = require "l0.DependencyControl.ScriptTargetFilter"

-- Iterates the real packages of a loaded feed that pass the given filter, yielding
-- (pkgProxy, scriptType, section). pkgProxy exposes the package's `namespace` alongside its
-- raw fields. Rolling-template keys the expander writes into a section container (e.g.
-- fileBaseUrl/localFileBasePath) are skipped: real packages are tables carrying `channels`.
walkPackages = (feed, filter) ->
    coroutine.wrap ->
        for scriptType in *filter\scriptTypes!
            section = Common.ScriptType.name.legacy[scriptType]
            packages = feed.data[section]
            continue unless packages

            for namespace, pkg in pairs packages
                continue unless type(pkg) == "table" and pkg.channels
                continue unless filter\matches scriptType, namespace
                pkgProxy = setmetatable {}, __index: (_, k) -> k == "namespace" and namespace or pkg[k]
                coroutine.yield pkgProxy, scriptType, section

--- Downloaded and expanded update feed data source.
    -- @class UpdateFeed
class UpdateFeed extends Common
    templateData = {
        maxDepth: 7
        templates: {
            feedName:      {depth: 1, order: 1, key: "name"                                                  }
            baseUrl:       {depth: 1, order: 2, key: "baseUrl"                                               }
            feed:          {depth: 1, order: 3, key: "knownFeeds", isHashTable: true                         }
            namespace:     {depth: 3, order: 1, parentKeys: {macros:true, modules:true}                      }
            namespacePath: {depth: 3, order: 2, parentKeys: {macros:true, modules:true}, repl:"%.", to: "/"  }
            scriptName:    {depth: 3, order: 3, key: "name"                                                  }
            channel:       {depth: 5, order: 1, parentKeys: {channels:true}                                  }
            version:       {depth: 5, order: 2, key: "version"                                               }
            platform:      {depth: 7, order: 1, key: "platform"                                              }
            fileName:      {depth: 7, order: 2, key: "name"                                                  }
            -- rolling templates
            localFileBasePath: {
                key: "localFileBasePath", 
                rolling: true, 
                expansionModes: {local: true},
                default: "./"
            }
            fileBaseUrl: {
                key: "fileBaseUrl", 
                rolling: true
            }
        }
        sourceAt: {}
    }

    msgs = {
        trace: {
            usingCached: "Using cached feed."
            downloaded:  "Downloaded feed to %s."
        }
        errors: {
            downloadAdd:     "Couldn't initiate download of %s to %s (%s)."
            downloadFailed:  "Download of feed %s to %s failed (%s)."
            cantOpen:        "Can't open downloaded feed for reading (%s)."
            parse:           "Error parsing feed."
            invalidScriptType: "Invalid or unsupported script type: '%s'. Supported types: %s."
        }
        bundle: {
            invalidSourcePath: "invalid source path for %s (%s): %s"
            invalidDeployPath: "couldn't generate a valid deploy path for %s (channel %s) file '%s' with root dir '%s': %s"
            srcNotFound: "source not found: %s"
            copyFailed:  "error copying %s: %s"
            copied:      "%s -> %s"
            skipped:     "skipped (already exists): %s"
        }
    }

    @defaultConfig = {
        dumpExpanded: false
    }
    @cache = {}

    --- Variable-expansion modes for @{expand}.
    -- Remote (default): expand `fileBaseUrl`/`url` to their download URLs.
    -- Local: additionally resolve the `localFileBasePath`/`localFilePath` sister fields to
    -- on-disk paths (used by tooling such as the bundler). The remote fields are left intact.
    @ExpansionMode = Enum "UpdateFeedExpansionMode", {
        Remote: "remote"
        Local:  "local"
    }

    --- Resolves the install path of a packaged file from its owning script's namespace,
    -- mirroring the layout the Updater installs into: automation scripts go to the
    -- autoload dir, modules to the include dir (under their namespace path), and test
    -- files to the matching DepUnit test dir.
    -- @param namespace string
    -- @param scriptType number a ScriptType value
    -- @param fileName string the file's feed name (e.g. ".moon", "/Common.moon")
    -- @param[opt="script"] fileType string "script" or "test"
    -- @param[opt] rootDir string the root directory for deployment
    -- @return string path
    @getFileDeployPath = (namespace, scriptType, fileName, fileType = "script", rootDir) =>
        subDir = scriptType == Common.ScriptType.Module and (namespace\gsub "%.", "/") or namespace
        baseDir = fileType == "test" and Common\getTestDir(scriptType, rootDir) or Common\getAutomationDir scriptType, rootDir
        return FileOps.validateFullPath "#{subDir}#{fileName}", false, baseDir

    fileBaseName = "l0.#{@@__name}_"
    fileMatchTemplate = "l0.#{@@__name}_%x%x%x%x.*%.json"
    feedsHaveBeenTrimmed = false

    -- precalculate some tables for the templater
    templateData.rolling = {n, true for n,t in pairs templateData.templates when t.rolling}
    templateData.sourceKeys = {t.key, t.depth for n,t in pairs templateData.templates when t.key}
    with templateData
        for i=1,.maxDepth
            .sourceAt[i], j = {}, 1
            for name, tmpl in pairs .templates
                if tmpl.depth==i and not tmpl.rolling
                    .sourceAt[i][j] = name
                    j += 1
            table.sort .sourceAt[i], (a,b) -> return .templates[a].order < .templates[b].order

    --- Creates an update feed wrapper and optionally fetches feed data.
    -- @param url string
    -- @param[opt=true] autoFetch boolean
    -- @param[opt] fileName string
    -- @param[opt] config table
    -- @param[opt] logger Logger
    new: (@url, autoFetch = true, fileName, @config = {}, @logger = defaultLogger) =>
        meta = getmetatable @
        setmetatable @, {
            __index: (self, key) ->
                rawValue = meta[key]
                return rawValue if rawValue != nil
                if key == 'url' then return self.fileName and "file://#{self.fileName}" or nil
        }

        -- fill in missing config values
        @config[k] = v for k, v in pairs @@defaultConfig when @config[k] == nil
        @fileName = fileName
        if @@cache[@url]
            @logger\trace msgs.trace.usingCached
            @data = @@cache[@url]
        elseif autoFetch
            @fetch!

    --- Returns URLs of all feeds referenced in the knownFeeds section of this feed.
    -- @return string[] urls
    getKnownFeeds: =>
        return {} unless @data
        return [url for _, url in pairs @data.knownFeeds]
        -- TODO: maybe also search all requirements for feed URLs

    --- Downloads and parses feed JSON data.
    -- @param[opt] fileName string
    -- @return table|boolean dataOrSuccess
    -- @return string|nil err
    fetch: (fileName) =>
        -- Initialize download infrastructure lazily on first fetch.
        unless @downloadManager
            @config.downloadPath or= aegisub.decode_path "?temp/l0.#{@@__name}_feedCache"
            feedsHaveBeenTrimmed or= Logger(fileMatchTemplate: fileMatchTemplate, logDir: @config.downloadPath, maxFiles: 20)\trimFiles!
            @fileName or= table.concat {@config.downloadPath, fileBaseName, "%04X"\format(math.random 0, 16^4-1), ".json"}
            @downloadManager = (require "DM.DownloadManager") aegisub.decode_path @config.downloadPath
        @fileName = fileName if fileName

        dl, err = @downloadManager\addDownload @url, @fileName
        unless dl
            return false, msgs.errors.downloadAdd\format @url, @fileName, err

        @downloadManager\waitForFinish -> true
        if dl.error
            return false, msgs.errors.downloadFailed\format @url, @fileName, dl.error

        @logger\trace msgs.trace.downloaded, @fileName
        return @loadFile @fileName

    --- Loads and parses a local feed JSON file, expanding all template variables in-place.
    -- Use this to load a feed already on disk without going through the network.
    ---@param path string Local filesystem path to the feed JSON file.
    ---@param[opt] mode UpdateFeedExpansionMode expansion mode (Remote by default; Local also
    --             resolves the localFileBasePath/localFilePath fields against the feed's directory).
    ---@return table|boolean
    ---@return string|nil err
    loadFile: (path, mode = @@ExpansionMode.Remote) =>
        handle, err = io.open path
        unless handle
            return false, msgs.errors.cantOpen\format err

        decoded, data = pcall json.decode, handle\read "*a"
        handle\close!
        unless decoded and data
            -- luajson errors are useless dumps of whatever, no use to pass them on to the user
            return false, msgs.errors.parse

        data[key] = {} for key in *{ @@ScriptType.name.legacy[@@ScriptType.Automation],
                                     @@ScriptType.name.legacy[@@ScriptType.Module],
                                     "knownFeeds"} when not data[key]
        @data, @@cache[@url] = data, data
        @feedDir = path\match("^(.*)[/\\][^/\\]*$") or "."

        @expand mode
        return @data

    --- Walks the parsed feed JSON and expands @{template} variables in-place.
    -- @param mode UpdateFeedExpansionMode expansion mode local mode resolves addition rolling templates for local source file paths
    -- @return table data
    expand: (mode = @@ExpansionMode.Remote) =>
        {:templates, :maxDepth, :sourceAt, :rolling, :sourceKeys} = templateData
        localMode = mode == @@ExpansionMode.Local
        vars, rvars = {}, {i, {} for i=0, maxDepth}

        expandTemplates = (val, depth, rOff=0) ->
            return switch type val
                when "string"
                    val = val\gsub "@{(.-):(.-)}", (name, key) ->
                        if type(vars[name]) == "table" or type(rvars[depth+rOff]) == "table"
                            vars[name] and vars[name][key] or rvars[depth+rOff][name] and rvars[depth+rOff][name][key]
                    val\gsub "@{(.-)}", (name) -> vars[name] or rvars[depth+rOff][name]
                when "table"
                    {k, expandTemplates v, depth, rOff for k, v in pairs val}
                else val


        recurse = (obj, depth = 1, parentKey = "", upKey = "") ->
            -- collect regular template variables first
            for name in *sourceAt[depth]
                with templates[name]
                    if not .key
                         -- template variables are not expanded if they are keys
                        vars[name] = parentKey if .parentKeys[upKey]
                    elseif .key and obj[.key]
                        -- expand other templates used in template variable
                        obj[.key] = expandTemplates obj[.key], depth
                        vars[name] = obj[.key]
                    vars[name] = vars[name]\gsub(.repl, .to) if .repl

            -- update rolling template variables last
            for name,_ in pairs rolling
                continue if templates[name].expansionModes and not templates[name].expansionModes[mode]
                default = templates[name].default
                rvars[depth][name] = obj[templates[name].key] or rvars[depth-1][name] or default
                rvars[depth][name] = expandTemplates rvars[depth][name], depth, -1
                obj[templates[name].key] = rvars[depth][name]

            -- expand variables in non-template strings and recurse tables
            for k,v in pairs obj
                if sourceKeys[k] ~= depth and not rolling[k]
                    switch type v
                        when "string"
                            obj[k] = expandTemplates obj[k], depth
                        when "table"
                            recurse v, depth+1, k, parentKey
                            -- invalidate template variables created at depth+1
                            vars[name] = nil for name in *sourceAt[depth+1]
                            rvars[depth+1] = {}

        recurse @data

        if @dumpExpanded
            handle = io.open @fileName\gsub(".json$", ".exp.json"), "w"
            handle\write(json.encode @data)\close!

        return @data

    --- Retrieves a script update record by namespace and type.
    -- @param namespace string
    -- @param scriptType number|boolean
    -- @param[opt] config table
    -- @param[opt] autoChannel boolean
    -- @return ScriptUpdateRecord|boolean|nil
    -- @return string|nil err
    getScript: (namespace, scriptType, config, autoChannel) =>
        -- legacy compatibility for <= 0.6.3
        if scriptType == true then scriptType = @@ScriptType.Module
        elseif scriptType == false then scriptType = @@ScriptType.Automation

        section = @@ScriptType.name.legacy[scriptType]
        unless section
            err = msgs.errors.invalidScriptType\format scriptType, 
                table.concat ["#{v} (#{@@ScriptType.name.canonical[v]})" for k, v in pairs @@ScriptType when k != "name"], ", "
            return nil, err
        
        scriptData = @data[section][namespace]
        return false unless scriptData
        ScriptUpdateRecord namespace, scriptData, config, scriptType, autoChannel, @logger

    --- Retrieves an automation script update record by namespace.
    -- @param namespace string
    -- @param[opt] config table
    -- @param[opt] autoChannel boolean
    -- @return ScriptUpdateRecord|boolean|nil
    -- @return string|nil err
    getMacro: (namespace, config, autoChannel) =>
        @getScript namespace, @@ScriptType.Automation, config, autoChannel

    --- Retrieves a module update record by namespace.
    -- @param namespace string
    -- @param[opt] config table
    -- @param[opt] autoChannel boolean
    -- @return ScriptUpdateRecord|boolean|nil
    -- @return string|nil err
    getModule: (namespace, config, autoChannel) =>
        @getScript namespace, @@ScriptType.Module, config, autoChannel

    --- Returns the default channel's version for a module namespace, or nil.
    -- "Default" means the channel with default:true; falls back to the first channel found.
    -- @param namespace string
    -- @return string|nil version
    getModuleVersion: (namespace) =>
        pkg = @data.modules and @data.modules[namespace]
        return nil unless pkg
        fallback = nil
        for _, ch in pairs pkg.channels or {}
            fallback or= ch.version
            return ch.version if ch.default
        fallback

    --- Copies every file listed in the feed to distDir using the Updater's install layout.
    -- The feed must have been loaded with ExpansionMode.Local so localFileBasePath is populated.
    -- @param distDir string absolute path of the output dist directory
    -- @param scriptTypes? table list of script types to deploy (by default goes over automation scripts and modules)
    -- @param clobber? boolean overwrite existing destination files (defaults to false)
    -- @return number fileCount number of files successfully copied
    -- @return number errCount number of files that failed to copy (e.g. due to missing source file or copy error)
    -- @param filter? ScriptTargetFilter restricts which packages are deployed (by default deploys all)
    deployFiles: (distDir, filter, clobber = false) =>
        fileCount, errCount = 0, 0

        for file, channel, pkg, _, scriptType in @walkFiles filter
            unless file.localFilePath
                @logger\warn msgs.bundle.invalidSourcePath, pkg.namespace, channel.name, tostring file.name
                errCount += 1
                continue

            fileExists, errMsg = FileOps.exists file.localFilePath, "file"
            unless fileExists
                @logger\warn errMsg
                errCount += 1
                continue

            dstPath, errMsg = @@getFileDeployPath pkg.namespace, scriptType, file.name, file.type or "script", distDir
            unless dstPath
                @logger\warn msgs.bundle.invalidDeployPath, pkg.namespace, channel.name, file.name, distDir, tostring errMsg
                errCount += 1
                continue

            unless clobber
                if FileOps.exists dstPath, "file"
                    @logger\hint msgs.bundle.skipped, dstPath
                    continue

            FileOps.mkdir dstPath, true, true
            copied, copyErr = FileOps.copy file.localFilePath, dstPath, true
            if copied
                @logger\hint msgs.bundle.copied, file.localFilePath, dstPath
                fileCount += 1
            else
                @logger\warn msgs.bundle.copyFailed, file.localFilePath, tostring copyErr
                errCount += 1

        return fileCount, errCount

    --- Returns a coroutine-based iterator over the packages of this feed that pass the filter.
    -- The feed must have been loaded before calling this method.
    -- Each iteration yields three values:
    --   pkg        – the package object; the package key is accessible via `.namespace`
    --   scriptType – the script type (Common.ScriptType.Module / .Automation)
    --   section    – the section name (e.g. "macros" or "modules")
    -- @param filter? ScriptTargetFilter restricts which packages are walked (default: all)
    -- @return function iterator
    walkPackages: (filter = ScriptTargetFilter!\includeAll!) =>
        walkPackages @, filter

    --- Returns a coroutine-based iterator over every file entry of the packages passing the filter.
    -- The feed must have been loaded before calling this method.
    -- Each iteration yields five values:
    --   file    – the file object; `.localFilePath` resolves localFileBasePath+name against @feedDir
    --   channel – the channel object; the channel key is accessible via `.name`
    --   pkg     – the package object; the package key is accessible via `.namespace`
    --   section – the section name (e.g. "macros" or "modules")
    --   scriptType – the script type (Common.ScriptType.Module / .Automation)
    -- @param filter? ScriptTargetFilter restricts which packages are walked (default: all)
    -- @return function iterator
    walkFiles: (filter = ScriptTargetFilter!\includeAll!) =>
        FileOps = require "l0.DependencyControl.FileOps"
        feedDir = @feedDir

        coroutine.wrap ->
            for pkg, scriptType, section in walkPackages @, filter
                for channelName, channel in pairs pkg.channels or {}
                    chanProxy = setmetatable {}, __index: (_, k) -> k == "name" and channelName or channel[k]

                    for file in *channel.files or {}
                        fileProxy = setmetatable {}, {
                            __index: (_, k) ->
                                return (FileOps.validateFullPath file.localFileBasePath .. file.name, false, feedDir) if k == "localFilePath"
                                file[k]
                        }
                        coroutine.yield fileProxy, chanProxy, pkg, section, scriptType
