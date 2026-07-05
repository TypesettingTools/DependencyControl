-- We ship dkjson, so depend on it directly: it guarantees the `null` sentinel, dkjson's encode
-- options, and our `indentMode: "prettier"` extension used for feed write-back.
dkjson = require "l0.dkjson"
constants = require "l0.DependencyControl.Constants"
Logger = require "l0.DependencyControl.Logger"
Common = require "l0.DependencyControl.Common"
Enum = require "l0.DependencyControl.Enum"
FileOps = require "l0.DependencyControl.FileOps"
Downloader = require "l0.DependencyControl.Downloader"
ModuleProvider = require "l0.DependencyControl.ModuleProvider"
SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
ScriptUpdateRecord = require "l0.DependencyControl.ScriptUpdateRecord"
ScriptTargetFilter = require "l0.DependencyControl.ScriptTargetFilter"
JsonSchema = nil

defaultLogger = Logger fileBaseName: "DepCtrl.UpdateFeed"

ScriptType = Common.ScriptType

-- Iterates the real packages of a loaded feed that pass the given filter, yielding
-- (pkgProxy, scriptType, section). pkgProxy exposes the package's `namespace` alongside its
-- raw fields. Rolling-template keys the expander writes into a section container (e.g.
-- fileBaseUrl/localFileBasePath) are skipped: real packages are tables carrying `channels`.
walkPackages = (feed, filter) ->
    coroutine.wrap ->
        for scriptType in *filter\scriptTypes!
            section = Common.ScriptTypeSection[scriptType]
            packages = feed.data[section]
            continue unless packages

            for namespace, pkg in pairs packages
                continue unless type(pkg) == "table" and pkg.channels
                continue unless filter\matches scriptType, namespace
                pkgProxy = setmetatable {}, __index: (_, k) -> k == "namespace" and namespace or pkg[k]
                coroutine.yield pkgProxy, scriptType, section

---Gives an expanded file record a lazily-resolved `localFilePath` property
---by appending the file `name` to `localFileBasePath` and resolving that against the feed directory.
---@param file table The file record to attach the accessor to.
---@param feedDirPath string The feed directory to resolve against.
---@param localFileBasePath string The resolved local base path for this file (captured from the rolling template state).
attachLocalFilePath = (file, feedDirPath, localFileBasePath) ->
    setmetatable file, __index: (self, key) ->
        return unless key == "localFilePath"
        name = rawget self, "name"
        return unless localFileBasePath and name
        path = FileOps.validateFullPath localFileBasePath .. name, false, feedDirPath
        return path

-- Deep-copies a decoded feed table while dropping any field whose value is the dkjson.null
-- sentinel, turning a round-tripped JSON null back into an absent key. Used for the expanded
-- working copy so consumers see plain nil where the raw feed has an explicit null.
stripNulls = (tbl) ->
    {k, (type(v) == "table" and stripNulls(v) or v) for k, v in pairs tbl when v != dkjson.null}

---Downloaded and expanded update feed data source.
---@class UpdateFeed
class UpdateFeed
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
                default: "./",

                -- keyBy/keyAt/keyDefault: the JSON value may be a keyed object (e.g.
                -- {script:…, test:…}) instead of a plain string. If the object selected
                -- by keyAt doesn't have an entry for keyBy, entry[keyDefault] is used as a fallback.
                keyBy: "type",
                keyAt: "files",
                keyDefault: "script"
            }
            fileBaseUrl: {
                key: "fileBaseUrl",
                rolling: true,
                keyBy: "type",
                keyAt: "files",
                keyDefault: "script"
            }
        }
        sourceAt: {}
    }

    msgs = {
        trace: {
            usingCached: "Using cached feed."
            downloaded:  "Downloaded feed to %s."
        }
        warn: {
            usingStale: "Couldn't refresh feed %s (%s); using the cached copy."
        }
        errors: {
            urlOrFilePathRequired: "Either a URL or a file path must be provided."
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
            deleted:      "removed from dist (marked for deletion): %s"
            removeFailed: "couldn't remove %s from dist (%s)"
        }
        ensureLoaded: {
            noLocalPath: "Local expansion mode require a local feed file path to resolve local path templates against."
        }
        __refreshFiles: {
            noLocalPath: "Feed has no local path required to check file '%s' for changes."
            sha1Failed: "Couldn't compute SHA-1 for file '%s' to check for changes: %s"
        }
        __refreshVersionRecord: {
            loadFailed: "Failed to load %s '%s' for getting a fresh DependencyControl version record: %s"
            missingDepctrlRecord: "No DependencyControl version record exposed by %s '%s'."
        }
        __updatePackage: {
            failedRefreshVersionRecord: "Failed to refresh version/dependencies: %s"
        }
        update: {
            notInRaw:      "%s: not found in the feed data, skipping."
            channelError:  "%s: %s"
            noRecord:      "%s: no DependencyControl record (%s), skipping version/dependency refresh."
            sha1Failed:    "  '%s': couldn't compute SHA-1 — %s"
            schemaValid:   "Feed conforms to schema (format v%s)."
            schemaInvalid: "Feed fails schema validation (format v%s) — continuing anyway."
            wrote:         "Wrote %d updated package(s) to %s."
            noRawData:     "No raw feed data loaded — call loadFile or updateFeed first."
        }
    }

    -- Stable key order for serializing a feed back to JSON. Keys absent from this list are
    -- appended afterwards in pairs() order (undefined, but stable for unchanged subtrees).
    feedKeyOrder = {
        "dependencyControlFeedFormatVersion",
        "name", "description", "author",
        "baseUrl", "url", "fileBaseUrl", "localFileBasePath",
        "maintainer", "knownFeeds",
        "moduleName",
        "version", "released", "default",
        "optional",
        "channels", "changelog",
        "files", "requiredModules", "provides", "platforms",
        "sha1", "delete", "type", "platform",
        "macros", "modules",
        "feed",
    }

    @defaultConfig = {
        dumpExpanded: false
    }

    ---Variable-expansion modes for expand().
    ---@alias UpdateFeedExpansionMode
    ---| "remote" # Remote (default): expand `fileBaseUrl`/`url` to their download URLs.
    ---| "local" # Local: additionally resolve the `localFileBasePath`/`localFilePath` sister fields to on-disk paths (used by the bundler), leaving the remote fields intact.
    @ExpansionMode = Enum "UpdateFeedExpansionMode", {
        Remote: "remote"
        Local:  "local"
    }

    ---Resolves the install path of a packaged file from its owning script's namespace,
    ---mirroring the layout the Updater installs into: automation scripts go to the
    ---autoload dir, modules to the include dir (under their namespace path), and test
    ---files to the matching DepUnit test dir.
    ---@param namespace string
    ---@param scriptType ScriptType A ScriptType value.
    ---@param fileName string The file's feed name (e.g. ".moon", "/Common.moon").
    ---@param fileType? string "script" or "test" (default "script").
    ---@param rootDir? string The root directory for deployment.
    ---@return string? path
    ---@return string? err
    @getFileDeployPath = (namespace, scriptType, fileName, fileType = "script", rootDir) =>
        subDir = scriptType == ScriptType.Module and (namespace\gsub "%.", "/") or namespace
        baseDir = fileType == "test" and Common\getTestDir(scriptType, rootDir) or Common\getAutomationDir scriptType, rootDir
        return FileOps.validateFullPath "#{subDir}#{fileName}", false, baseDir

    fileBaseName = "#{constants.DEPCTRL_NAMESPACE}_"
    fileMatchTemplate = "#{constants.DEPCTRL_NAMESPACE}_%x%x%x%x.*%.json"
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

    ---Creates an update feed wrapper and optionally fetches feed data.
    ---@param _url? string Feed URL (or nil when loading from a local file via fileName).
    ---@param autoLoad? boolean Fetch/load the feed immediately (default true).
    ---@param fileName? string Local feed file path.
    ---@param config? table Feed-fetch settings, normally supplied by `FeedLoader`: `cache` (the on-disk `FileCache`) and `blockPrivateHosts`.
    ---@param logger? Logger
    new: (@_url, autoLoad = true, @fileName, @config = {}, @logger = defaultLogger) =>
        error msgs.errors.urlOrFilePathRequired if not @_url and not fileName
    
        meta = getmetatable @
        setmetatable @, {
            __index: (self, key) ->
                rawValue = meta[key]
                return rawValue if rawValue != nil
                if key == 'url'
                    return self._url if self._url
                    return "file://#{self.fileName}" if self.fileName
        }

        Common.addDefaults @config, @@defaultConfig

        @ensureLoaded! if autoLoad

    ---Returns URLs of all feeds referenced in the knownFeeds section of this feed.
    ---@return string[] urls
    getKnownFeeds: =>
        return {} unless @data
        return [url for _, url in pairs @data.knownFeeds]
        -- TODO: maybe also search all requirements for feed URLs

    ---Decodes a feed's JSON into its unexpanded working data — null sentinels stripped and the macros/modules/
    ---knownFeeds sections ensured present — alongside the raw null-preserving decode kept for write-back. Shared
    ---by loadFile and the feed cache's L1 layer so both agree on the shape.
    ---@param content string The raw feed JSON.
    ---@return table? unexpandedData The working feed data, before template expansion (nil on a JSON parse error).
    ---@return table? raw The pristine decode with `dkjson.null` sentinels intact, for write-back.
    @deserialize = (content) ->
        ok, raw = pcall dkjson.decode, content, nil, dkjson.null
        return nil unless ok and raw
        unexpandedData = stripNulls raw
        for section in *{ Common.ScriptTypeSection[ScriptType.Automation],
                          Common.ScriptTypeSection[ScriptType.Module], "knownFeeds" }
            unexpandedData[section] or= {}
        return unexpandedData, raw

    ---Downloads feed to a temporary JSON file and sets the .fileName property for subsequent loading.
    ---@param fileName? string Destination path (defaults to a generated temp path).
    ---@param expansionMode? UpdateFeedExpansionMode
    ---@return table|boolean dataOrSuccess
    ---@return string? err
    fetch: (fileName, expansionMode) =>
        -- Initialize download infrastructure lazily on first fetch.
        unless @downloader
            @config.downloadPath or= aegisub.decode_path "?temp/#{constants.DEPCTRL_NAMESPACE}_feedCache"
            feedsHaveBeenTrimmed or= Logger(fileMatchTemplate: fileMatchTemplate, logDir: @config.downloadPath, maxFiles: 20)\trimFiles!
            @fileName or= table.concat {@config.downloadPath, fileBaseName, "%04X"\format(math.random 0, 16^4-1), ".json"}
            @downloader = Downloader nil, {blockPrivateHosts: @config.blockPrivateHosts}
        @fileName = fileName if fileName

        dl, err = @downloader\addDownload @url, @fileName
        unless dl
            return false, msgs.errors.downloadAdd\format @url, @fileName, err

        @downloader\await!
        if dl.error
            return false, msgs.errors.downloadFailed\format @url, @fileName, dl.error

        @logger\trace msgs.trace.downloaded, @fileName
        result, loadErr = @loadFile @fileName, expansionMode
        -- persist the freshly fetched feed to the on-disk cache (best-effort; a failure just skips caching)
        if result and @_url
            rawJson = FileOps.readFile @fileName
            if rawJson
                cacheMeta = @config.cache\put @_url, rawJson, @data.name
                @lastFetchedAt = cacheMeta and cacheMeta.cachedAt or @lastFetchedAt
        return result, loadErr

    ---Loads and parses a local feed JSON file, expanding all template variables in-place.
    ---Use this to load a feed already on disk without going through the network.
    ---@param srcPath? string Local filesystem path to the feed JSON file.
    ---Defaults to the .fileName property, which was either provided in the
    ---constructor, or set to a temporary path when the feed is fetched.
    ---@param expansionMode? UpdateFeedExpansionMode Expansion mode. Defaults to remote if the feed
    ---was loaded from a URL; otherwise local, which resolves the rolling localFileBasePath template
    ---variables and exposes the `localFilePath` property on file records for build tooling such as the bundler.
    ---@return table|boolean dataOrSuccess The expanded feed data, or false on failure.
    ---@return string? err Error message on failure.
    loadFile: (srcPath = @fileName, expansionMode) =>
        content, err = FileOps.readFile srcPath
        return false, msgs.errors.cantOpen\format err unless content

        unexpandedData, raw = @@.deserialize content
        -- luajson errors are useless dumps of whatever, no use to pass them on to the user
        return false, msgs.errors.parse unless unexpandedData

        -- keep the pristine null-preserving decode for write-back (see deserialize)
        @rawFeedData = raw
        @unexpandedData = unexpandedData
        @feedPath = srcPath
        @feedDir = srcPath\match("^(.*)[/\\][^/\\]*$") or "."

        return @expand expansionMode

    ---Fetches the feed (or loads it from disk if local) in case it hasn't been loaded yet.
    ---@param expansionMode? UpdateFeedExpansionMode The expansion mode required for the operation.
    ---@return table|boolean|nil feedData The expanded feed data, false on failure, or nil on a local-path error.
    ---@return string? err An error message in case of failure.
    ensureLoaded: (expansionMode) =>
        if expansionMode == @@ExpansionMode.Local and not @fileName
            return nil, msgs.ensureLoaded.noLocalPath\format @url

        -- when already loaded, reuse as-is if the expansion mode matches, otherwise re-expand
        if @data
            return @data if not expansionMode or expansionMode == @expansionMode
            return @expand expansionMode

        -- when not yet loaded, fetch a remote feed by its real URL, otherwise load the local file
        if @_url
            -- the feed cache serves the unexpanded data from its in-memory L1, else the on-disk snapshot.
            -- expand copies it into @data for the requested mode
            unexpandedData, meta, fresh = @config.cache\get @_url
            if unexpandedData and fresh
                @unexpandedData = unexpandedData
                @lastFetchedAt = meta.cachedAt
                @logger\trace msgs.trace.usingCached
                return @expand expansionMode

            -- fetch; on failure, fall back to the stale cached data when one exists (offline resilience)
            data, err = @fetch nil, expansionMode
            return data if data
            if unexpandedData
                @unexpandedData = unexpandedData
                @stale, @lastFetchedAt = true, meta.cachedAt
                @logger\warn msgs.warn.usingStale, @_url, err
                return @expand expansionMode
            return data, err

        return @loadFile @fileName, expansionMode

    ---Expands and returns @data for the requested mode, rebuilt each call from a fresh deep copy of
    ---@unexpandedData, so the shared source (the feed cache's L1 memo for this URL) is never mutated by
    ---another consumer's expansion. The feed must be loaded (@unexpandedData set) first.
    ---@param mode? UpdateFeedExpansionMode Expansion mode; local mode additionally resolves rolling templates for local source file paths.
    ---@return table data
    expand: (mode = @expansionMode or (@_url and @@ExpansionMode.Remote or @@ExpansionMode.Local)) =>
        @data = Common.deepCopy @unexpandedData
        {:templates, :maxDepth, :sourceAt, :rolling, :sourceKeys} = templateData
        isLocalMode = mode == @@ExpansionMode.Local
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

                -- Collapse a keyed rolling object to its plain string once it reaches an
                -- object under the template's `keyAt` key (see template declaration).
                with templates[name]
                    if .keyBy and upKey == .keyAt and type(rvars[depth][name]) == "table"
                        keyValue = obj[.keyBy] or .keyDefault
                        resolved = rvars[depth][name][keyValue] if keyValue
                        rvars[depth][name] = resolved if resolved
                -- Only write back when the key is already present
                obj[templates[name].key] = rvars[depth][name] if obj[templates[name].key] != nil

            -- file records (array entries under a `files` key) get a lazy localFilePath accessor
            attachLocalFilePath obj, @feedDir, rvars[depth]["localFileBasePath"] if isLocalMode and upKey == "files"

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
        @expansionMode = mode

        if @dumpExpanded
            handle = io.open @fileName\gsub(".json$", ".exp.json"), "w"
            handle\write(dkjson.encode @data, indentMode: "prettier")\close!

        return @data

    ---Retrieves a script update record by namespace and type.
    ---@param namespace string
    ---@param scriptType ScriptType|boolean A ScriptType value (true/false accepted for legacy module/automation).
    ---@param config? table
    ---@param autoChannel? boolean Select the default channel automatically.
    ---@return ScriptUpdateRecord|boolean|nil record False when not found, nil on error.
    ---@return string? err
    getScript: (namespace, scriptType, config, autoChannel) =>
        -- legacy compatibility for <= 0.6.3
        if scriptType == true then scriptType = ScriptType.Module
        elseif scriptType == false then scriptType = ScriptType.Automation

        haveSection, section = Common.ScriptTypeSection\test scriptType
        unless haveSection
            return nil, msgs.errors.invalidScriptType\format scriptType,
                ScriptType\describe nil, (_, v) -> v
            
        scriptData = @data[section][namespace]
        return false unless scriptData
        ScriptUpdateRecord namespace, scriptData, config, scriptType, autoChannel, @logger

    ---Retrieves an automation script update record by namespace.
    ---@param namespace string
    ---@param config? table
    ---@param autoChannel? boolean Select the default channel automatically.
    ---@return ScriptUpdateRecord|boolean|nil record False when not found, nil on error.
    ---@return string? err
    getMacro: (namespace, config, autoChannel) =>
        @getScript namespace, ScriptType.Automation, config, autoChannel

    ---Retrieves a module update record by namespace.
    ---@param namespace string
    ---@param config? table
    ---@param autoChannel? boolean Select the default channel automatically.
    ---@return ScriptUpdateRecord|boolean|nil record False when not found, nil on error.
    ---@return string? err
    getModule: (namespace, config, autoChannel) =>
        @getScript namespace, ScriptType.Module, config, autoChannel

    ---Returns the default channel's version for a module namespace, or nil.
    ---"Default" means the channel with default:true; falls back to the first channel found.
    ---@param namespace string
    ---@return string? version
    getModuleVersion: (namespace) =>
        pkg = @data.modules and @data.modules[namespace]
        return nil unless pkg
        fallback = nil
        for _, ch in pairs pkg.channels or {}
            fallback or= ch.version
            return ch.version if ch.default
        fallback

    ---Returns the modules in this feed whose default channel `provides` the given name. Only the
    ---`modules` section is searched (automation scripts can't be `require`d). The feed must be loaded.
    ---@param alias string The required module name to find providers for.
    ---@return ScriptUpdateRecord[] providers Update records (default channel selected) whose `provides` lists the name.
    getProviders: (alias) =>
        providers = {}
        return providers unless @data and @data.modules
        for namespace, pkg in pairs @data.modules
            continue unless type(pkg) == "table" and pkg.channels
            record = ScriptUpdateRecord namespace, pkg, nil, ScriptType.Module, false, @logger
            continue unless (record\setChannel!) and record.provides
            for entry in *record.provides
                name = type(entry) == "table" and entry.name or entry
                if name == alias
                    providers[#providers + 1] = record
                    break
        return providers

    ---Resolves which channel of a package to operate on.
    ---With an explicit name, that channel must exist; otherwise the channel flagged `default: true`
    ---is used.
    ---@private
    ---@param channels? table The package's `channels` map.
    ---@param channelName? string An explicit channel name to select.
    ---@return string? name The resolved channel name, or nil if none matched.
    ---@return string? err Error message on failure.
    @__resolveChannel = (channels = {}, channelName) =>
        if channelName
            return channelName if channels[channelName]
            return nil, "channel '#{channelName}' not found"
        for name, channel in pairs channels
            return name if channel.default
        return nil, "no default channel — specify one explicitly"

    ---Writes the raw (unexpanded) feed data back to disk.
    ---@private
    ---@param path? string Destination path (defaults to the source path of the loaded feed).
    ---@return boolean success Whether the write succeeded.
    ---@return string? err Error message on failure.
    __writeRawFeed: (path) =>
        loaded, err = @ensureLoaded!
        return false, err unless loaded
        path or= @feedPath
        encoded = dkjson.encode @rawFeedData, {indentMode: "prettier", keyorder: feedKeyOrder}
        FileOps.writeFile path, "#{encoded}\n", true

    ---Validates @rawFeedData against the feed schema matching its declared format version.
    ---Best-effort: warns through @logger but never raises, so an unavailable schema rock or a
    ---non-conforming feed doesn't block an update.
    ---@param schemaDir string|string[] Directory holding the feed schemas (named `v<version>.json`).
    ---@return boolean? valid Whether the feed is valid, or nil if validation couldn't be performed.
    ---@return string? schemaVersion The feed format version validated against, if any.
    ---@return string? message A success or error message.
    validateAgainstSchema: (schemaDir) =>
        JsonSchema or= require "l0.DependencyControl.JsonSchema"

        schemaPathsByVersion, schemasErr = JsonSchema\getSchemasInDirectory schemaDir
        unless schemaPathsByVersion
            return nil, nil, schemasErr

        -- strip dkjson null sentinels before validation as lua-schema trips over them
        validationData = stripNulls @rawFeedData
        isValid, validationVersion, validationErr = JsonSchema\validateAny validationData,
            schemaPathsByVersion, @rawFeedData.dependencyControlFeedFormatVersion

        if isValid
            return true, validationVersion, msgs.update.schemaValid\format validationVersion
        return isValid, validationVersion, validationErr

    -- Fields a feed `ModuleAlias` may carry (per v0.4.0 of the feed schema).
    moduleAliasFields = {"name", "version"}

    ---Projects a list of `provides` entries to feed ModuleAlias tables, keeping only the
    ---schema-permissible fields (`name`, `version`).
    ---@private
    ---@param provides? (string|ModuleAlias)[]
    ---@return ModuleAlias[] aliases The normalized alias tables, each carrying `name` plus optional `version`.
    @__normalizeModuleAliases = (provides) =>
        aliases = {}
        for entry in *(provides or {})
            aliases[#aliases + 1] = if type(entry) == "table"
                {field, entry[field] for field in *moduleAliasFields when entry[field] != nil}
            else {name: entry}
        return aliases

    ---Updates a package channel's version and dependencies in the raw feed data by loading
    ---the package's script and reading its DependencyControl record.
    ---@private
    ---@param scriptType ScriptType The script type of the package to refresh (ScriptType.Automation or .Module).
    ---@param packageNamespace string The package namespace.
    ---@param rawChannel table The raw channel entry to update in place.
    ---@return boolean? changed Whether anything was modified, or nil on error.
    ---@return string? err Error message on failure.
    __refreshVersionRecord: (scriptType, packageNamespace, rawChannel) =>
        -- Require the script so it registers its DependencyControl record by namespace: macros do
        -- so simply by running, modules by constructing their record at load. Modules that defer to
        -- a lazy __depCtrlInit (e.g. dkjson) are initialized explicitly below. The record is then
        -- looked up from the registry — the only place a macro's record (and its deps) is reachable.
        DependencyControl = require "l0.DependencyControl"
        success, mod = xpcall require, ModuleProvider.fullTraceback, packageNamespace
        ModuleProvider.runInitializer mod, DependencyControl if success

        record = DependencyControl\getRegisteredRecord packageNamespace
        unless record
            return nil, success and msgs.__refreshVersionRecord.missingDepctrlRecord\format(scriptType, packageNamespace) or
                msgs.__refreshVersionRecord.loadFailed\format scriptType, packageNamespace, mod

        changed = false
        newVer, verErr = SemanticVersioning\toString record.version
        return nil, verErr unless newVer
        if newVer != rawChannel.version
            rawChannel.version = newVer
            changed = true

        existingDepsByName = {dep.moduleName, dep for dep in *rawChannel.requiredModules or {}}
        newDeps = {}
        for dep in *record.requiredModules or {}
            existing = existingDepsByName[dep.moduleName]
            entry = moduleName: dep.moduleName
            entry.version  = dep.version  if dep.version  != nil
            entry.optional = dep.optional if dep.optional != nil
            if existing
                entry.feed = existing.feed if existing.feed != nil
                entry.url  = existing.url  if existing.url  != nil
                entry.name = existing.name if existing.name != nil
            else
                entry.feed = dep.feed if dep.feed != nil
                entry.url  = dep.url  if dep.url  != nil
                entry.name = dep.name if dep.name != nil
            newDeps[#newDeps + 1] = entry

        -- Compare only the semantically relevant fields, ignoring order: a moduleName-keyed
        -- digest of each dep's version/optional. Template fields (feed/url/name) are carried over
        -- verbatim, so they never count as a change on their own. version/optional are normalized
        -- (absent version == "", absent/false optional == false) so that purely representational
        -- differences don't register as changes.
        getDepSignature = (deps) ->
            Common.getObjectHash {d.moduleName, {version: d.version or "", optional: d.optional and true or false} for d in *deps or {}}
        if getDepSignature(newDeps) != getDepSignature rawChannel.requiredModules
            rawChannel.requiredModules = #newDeps > 0 and newDeps or nil
            changed = true

        -- Mirror the record's provided aliases onto the channel as ModuleAlias tables.
        -- A mere reordering or switching between string and table forms doesn't count as a change.
        providesSignature = (aliases) ->
            Common.getObjectHash {a.name, {k, v for k, v in pairs a when k != "name"} for a in *aliases when a.name}
        newProvides = @@__normalizeModuleAliases record.provides
        if providesSignature(newProvides) != providesSignature @@__normalizeModuleAliases rawChannel.provides
            rawChannel.provides = #newProvides > 0 and newProvides or nil
            changed = true

        return changed

    ---Refreshes the SHA-1 hashes of a channel's files from their local sources and flags any
    ---file that has vanished locally with `delete: true` so the Updater removes it from users'
    ---installations on their next update. Files already flagged for deletion are left untouched.
    ---@private
    ---@param rawChannel table The raw channel entry to update in place.
    ---@param expandedChannel table The matching expanded channel.
    ---@return boolean changed Whether anything was modified.
    ---@return string[] errors Per-file error messages encountered while refreshing.
    __refreshFiles: (rawChannel, expandedChannel) =>
        return false, {} unless rawChannel.files

        changed, errors = false, {}
        for i, rawFile in ipairs rawChannel.files
            expFile   = expandedChannel and expandedChannel.files and expandedChannel.files[i]
            localPath = expFile and expFile.localFilePath
            continue if rawFile.delete
            if not localPath
                errors[#errors + 1] = msgs.__refreshFiles.noLocalPath\format rawFile.name
            elseif FileOps.exists localPath, "file"
                newHash, err = FileOps.getHash localPath
                unless newHash
                    errors[#errors + 1] = msgs.__refreshFiles.sha1Failed\format rawFile.name, tostring err
                else if newHash\upper! != (rawFile.sha1 or "")\upper!
                    rawFile.sha1 = newHash\upper!
                    changed = true
            else
                rawFile.delete = true
                changed = true

        return changed, errors

    ---Applies all in-place updates to a single package's selected channel and, if anything
    ---changed, resets its `released` date to null to mark the build as pending/unreleased.
    ---Collects this package's own outcome rather than mutating shared state, so the caller can
    ---present results per package.
    ---@private
    ---@param scriptType ScriptType The package's script type (ScriptType.Automation or .Module).
    ---@param packageNamespace string The namespaced identifier of the package to update (e.g. "l0.Functional").
    ---@param channel? string The channel to update (default: the package's default channel).
    ---@return { namespace: string, scriptType: integer, channel?: string, changed: boolean, errors: string[] } result
    __updatePackage: (scriptType, packageNamespace, channel) =>
        result = {namespace: packageNamespace, :scriptType, changed: false, errors: {}}
        errors = result.errors

        section = Common.ScriptTypeSection[scriptType]

        rawPkg = @rawFeedData[section] and @rawFeedData[section][packageNamespace]
        unless rawPkg
            errors[#errors + 1] = msgs.update.notInRaw\format packageNamespace
            return result

        channelName, err = @@__resolveChannel rawPkg.channels, channel
        unless channelName
            errors[#errors + 1] = msgs.update.channelError\format packageNamespace, err
            return result
        result.channel = channelName

        rawChannel = rawPkg.channels[channelName]
        expandedSection = @data[section] and @data[section][packageNamespace]
        expandedChannel = expandedSection and expandedSection.channels[channelName]

        depsChanged, depErr = @__refreshVersionRecord scriptType, packageNamespace, rawChannel
        errors[#errors + 1] = msgs.__updatePackage.failedRefreshVersionRecord\format depErr if depErr

        filesChanged, fileErrors = @__refreshFiles rawChannel, expandedChannel
        errors[#errors + 1] = e for e in *fileErrors

        if depsChanged or filesChanged
            rawChannel.released = dkjson.null
            result.changed = true

        return result

    ---Loads the feed (unless already loaded), optionally validates it, refreshes the targeted
    ---packages in place and writes the result back to disk. The feed path is the one supplied to
    ---the constructor; pre-load with loadFile() if you need to act on the feed before refresh.
    ---@param opts? { channel?: string, filter?: ScriptTargetFilter, schemaDir?: string|string[], outPath?: string|boolean } Options. `outPath` false performs a dry run; nil/true defaults to the loaded feed's source path.
    ---@return { changed: integer, errored: integer, packages: table[] }|nil stats Per-run statistics, or nil on a fatal load/write error.
    ---@return string? err
    updateFeed: (opts = {}) =>
        -- Loads lazily in Local mode; a prior walkFiles/walkPackages (e.g. from registering a
        -- module searcher) may already have loaded the feed, in which case this is a no-op.
        loaded, err = @ensureLoaded @@ExpansionMode.Local
        return nil, err unless loaded

        dryRun = opts.outPath == false
        outPath = (opts.outPath == true or opts.outPath == nil) and @feedPath or opts.outPath

        if opts.schemaDir
            schemaValid, _, schemaMsg = @validateAgainstSchema opts.schemaDir
            if schemaValid
                @logger\trace schemaMsg if schemaMsg
            elseif schemaMsg
                @logger\warn schemaMsg

        filter = opts.filter or ScriptTargetFilter!\includeAll!
        stats = changed: 0, errored: 0, packages: {}
        for pkg, scriptType in @walkPackages filter
            -- isolate per-package processing so one package's failure doesn't abort the whole run
            ok, result = pcall @__updatePackage, @, scriptType, pkg.namespace, opts.channel
            result = {namespace: pkg.namespace, :scriptType, changed: false, errors: {tostring result}} unless ok
            stats.packages[#stats.packages + 1] = result
            stats.changed += 1 if result.changed
            stats.errored += 1 if #result.errors > 0

        if stats.changed > 0 and not dryRun
            wrote, writeErr = @__writeRawFeed outPath
            return nil, writeErr unless wrote
            @logger\hint msgs.update.wrote, stats.changed, outPath

        return stats

    ---Copies every file listed in the feed to distDir using the Updater's install layout. A file the feed marks
    ---for deletion (`delete: true`) is removed from distDir if present, rather than deployed.
    ---The feed must have been loaded with ExpansionMode.Local so localFileBasePath is populated.
    ---@param distDir string Absolute path of the output dist directory.
    ---@param filter? ScriptTargetFilter Restricts which packages are deployed (default: all).
    ---@param clobber? boolean Overwrite existing destination files (default false).
    ---@return number fileCount Number of files successfully copied.
    ---@return number errCount Number of files that failed to deploy — a missing source, a copy error, or a deletion that couldn't be performed.
    deployFiles: (distDir, filter, clobber = false) =>
        fileCount, errCount = 0, 0

        for file, channel, pkg, _, scriptType in @walkFiles filter
            if file.delete
                dstPath, errMsg = @@getFileDeployPath pkg.namespace, scriptType, file.name, file.type or "script", distDir
                unless dstPath
                    @logger\warn msgs.bundle.invalidDeployPath, pkg.namespace, channel.name, file.name, distDir, tostring errMsg
                    errCount += 1
                    continue
                if FileOps.exists dstPath, "file"
                    removed, _, remErr = FileOps.remove dstPath
                    if removed
                        @logger\hint msgs.bundle.deleted, dstPath
                    else
                        @logger\warn msgs.bundle.removeFailed, dstPath, tostring remErr
                        errCount += 1
                continue
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

    ---Returns a coroutine-based iterator over the packages of this feed that pass the filter.
    ---The feed must have been loaded before calling this method.
    ---Each iteration yields three values:
    ---  pkg        – the package object; the package key is accessible via `.namespace`
    ---  scriptType – the script type (ScriptType.Module / .Automation)
    ---  section    – the section name (e.g. "macros" or "modules")
    ---@param filter? ScriptTargetFilter Restricts which packages are walked (default: all).
    ---@return function iterator
    walkPackages: (filter = ScriptTargetFilter!\includeAll!) =>
        @ensureLoaded!
        walkPackages @, filter

    ---Returns a coroutine-based iterator over every file entry of the packages passing the filter.
    ---The feed must have been loaded before calling this method.
    ---Each iteration yields five values:
    ---  file    – the file object; `.localFilePath` resolves localFileBasePath+name against @feedDir
    ---  channel – the channel object; the channel key is accessible via `.name`
    ---  pkg     – the package object; the package key is accessible via `.namespace`
    ---  section – the section name (e.g. "macros" or "modules")
    ---  scriptType – the script type (ScriptType.Module / .Automation)
    ---@param filter? ScriptTargetFilter Restricts which packages are walked (default: all).
    ---@return function iterator
    walkFiles: (filter = ScriptTargetFilter!\includeAll!) =>
        @ensureLoaded @@ExpansionMode.Local
        coroutine.wrap ->
            for pkg, scriptType, section in walkPackages @, filter
                for channelName, channel in pairs pkg.channels or {}
                    chanProxy = setmetatable {}, __index: (_, k) -> k == "name" and channelName or channel[k]

                    -- file records carry their own lazy `.localFilePath` (attached during local-mode
                    -- expansion), so they can be yielded directly without a wrapping proxy.
                    for file in *channel.files or {}
                        coroutine.yield file, chanProxy, pkg, section, scriptType
