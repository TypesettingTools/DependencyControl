json = require "json"
constants = require "l0.DependencyControl.Constants"
fileOps = require "l0.DependencyControl.FileOps"
Logger = require "l0.DependencyControl.Logger"
Lock = require "l0.DependencyControl.Lock"
ConfigView = require "l0.DependencyControl.ConfigView"
Common = require "l0.DependencyControl.Common"
JsonSchema = require "l0.DependencyControl.JsonSchema"

defaultLogger = Logger fileBaseName: "#{constants.DEPCTRL_SHORT_NAME}.ConfigHandler", fileSubName: script_namespace

---JSON-backed configuration manager with cooperative cross-script locking.
---Manages one JSON file per instance. Use ConfigView (via getView or ConfigView.get)
---to access specific hives (nested sections) of the config.
---@class ConfigHandler
class ConfigHandler
  msgs = {
    get: {
      failedLoad: "Could not provide a ConfigHandler because there was an issue loading the configuration file: %s"
      failedCreate: "Failed to create ConfigHandler for file '%s': %s"
    }
    getHive: {
      unexpected: "An unexpected error occurred while trying to create hive '%s' on ConfigHandler for file '%s'"
    }
    __getOverlappingViews: {
      differentHandler: "Other view on config file '%s' does not belong to this config handler of config file '%s'."
    }
    getView: {
      failedView: "Failed to get #{ConfigView.__name} '%s' on ConfigHandler for file '%s': %s"
      failedHandler: "Failed to get ConfigHandler for file '%s' while trying to acquire a view on #{ConfigView.__name}: %s"
    }
    mergeHive: {
      badKey: "Can't merge hive because the path key #%d (%s) points to a %s."
    }
    new: {
      badPath: "Couldn't validate specified config file path '%s': %s"
      failedLoad: "Failed to load config file '%s': %s"
    }
    readFile: {
      failedLock: "Failed to lock config file for reading: %s"
      fileNotFound: "Couldn't find config file '%s'."
      jsonDecodeError: "JSON parse error: %s"
      configCorrupted: [[An error occurred while parsing the JSON config file.
A backup of the corrupted configuration has been written to '%s'.
Reload your automation scripts to generate a new configuration file.]]
      failedHandle: "Failed to acquire a handle for reading the config file: %s"
      badJsonRoot: "JSON root element must be an array or a hashtable, got a %s."
    }
    load: {
      noFilePath: "Can't load because no config file is set."
      noFile: "Starting with a fresh config because the config file '%s' is missing (%s)..."
      migrationSaveFailed: "Migrated config '%s' to the current schema, but couldn't save it (%s); will retry on next load."
    }
    save: {
      failedWhole: "Failed to save complete config to file '%s': %s"
      failedHives: "Failed to save hives %s into config file '%s': %s"
      failedMerge: "Failed to merge config hive %s into file '%s': %s"
      failedClean: "Failed to clean config hive %s in file '%s': %s"
      failedLock: "Failed to lock config file for saving: %s"
      failedRead: "Failed to read config file '%s': %s."
      noFile: "Can't save because no config file is set."
      fileCreate: "Config file '%s' doesn't exist, will write a fresh one..."
    }
    traverseHive: {
      badKey: "Can't retrieve hive because the path key #%d (%s) points to a %s."
    }
    writeFile: {
      writing: "Writing config file '%s'..."
      failedLock: "Failed to lock config file for writing: %s"
      failedSerialize: "Failed to serialize configuration to JSON: %s"
      failedHandle: "Failed to acquire a handle for writing the config file: %s"
    }
  }

  -- make references to provided handlers weak to allow for gc
  @handlers = setmetatable {}, {__mode: 'v'}

  ---Returns an existing handler for filePath, or creates and optionally loads one.
  ---@param filePath string
  ---@param logger? Logger
  ---@param noLoad? boolean Don't load the file immediately (default false).
  ---@param schemaOpts? { schemaId: string, migrate: fun(config: table, current?: string, target: string): boolean } Schema id this handler targets and the migration callback run when a loaded file's `$schema` differs. Applied on first creation; a cached handler keeps the opts it was created with.
  ---@return ConfigHandler? handler
  ---@return string? err
  @get = (filePath, logger = defaultLogger, noLoad = false, schemaOpts) =>
    -- normalize first, then look up by the canonical path: the cache is keyed by the validated path,
    -- so comparing against the raw filePath would miss and construct a duplicate handler for one file
    path, msg = fileOps.validateFullPath filePath, true
    return nil, msgs.new.badPath\format filePath, msg unless path

    return @@handlers[path] if @@handlers[path]

    success, handler = pcall ConfigHandler, path, logger, schemaOpts
    unless success
      return nil, msgs.get.failedCreate\format filePath, handler

    @@handlers[path] = handler

    unless noLoad
      success, msg = handler\load!
      return nil, msgs.get.failedLoad\format filePath, msg unless success

    return handler


  ---Returns a ConfigView for the given file and hive path, creating a handler if needed.
  ---@param filePath string
  ---@param hivePath string|string[]
  ---@param defaults? table Default values for the hive.
  ---@param logger? Logger
  ---@return ConfigView? view
  ---@return string? err
  @getView = (filePath, hivePath, defaults, logger) =>
    handler, msg = @get filePath, logger
    return nil, msgs.getView.failedHandler\format filePath, msg unless handler

    return handler\getView hivePath, defaults


  ---Creates a ConfigHandler for the given file. Does not load from disk.
  ---@param filePath? string
  ---@param logger? Logger
  ---@param schemaOpts? { schemaId: string, migrate: fun(config: table, current?: string, target: string): boolean } The `$schema` this handler targets and the migration callback invoked on load when a file's `$schema` differs.
  new: (filePath, @logger = Logger(fileBaseName: "#{constants.DEPCTRL_SHORT_NAME}.#{@@__name}"), schemaOpts = {}) =>
    @views = setmetatable {}, {__mode: 'k'}
    @config = {}
    -- the loaded file's `$schema`, exposed so views can see which schema their values conform to
    @schemaId = nil
    @__targetSchemaId = schemaOpts.schemaId
    @__migrate = schemaOpts.migrate
    if filePath
      path, msg = fileOps.validateFullPath filePath, true
      @logger\assert path, msgs.new.badPath, filePath, msg
      @filePath = path
      -- config files are shared across concurrent Aegisub instances, so the lock
      -- must exclude across processes, not just within this one
      @lock = Lock {
        namespace: "l0.DependencyControl.ConfigHandler", resource: @filePath
        holderName: @@__name, logger: @logger, scope: Lock.Scope.Global
      }


  readFile = (waitLockTime, useLock = true) =>
    info, err = fileOps.getAttributes @filePath, "mode"
    unless info
      return nil, err

    unless info.attr
      @logger\trace msgs.readFile.fileNotFound, @filePath
      return false, msgs.readFile.fileNotFound\format @filePath

    file = info.path
    if useLock
      lockState, msg = @lock\lock waitLockTime
      if lockState != Lock.LockState.Held
        return nil, msgs.readFile.failedLock\format msg

    handle, msg = io.open file, "r"
    unless handle
      @lock\release! if useLock
      return nil, msgs.readFile.failedHandle\format msg

    data = handle\read "*a"
    handle\close!

    @lock\release! if useLock

    success, res = pcall json.decode, data
    unless success
      -- JSON parse error usually points to a corrupted config file
      -- Rename the broken file to allow generating a new one
      -- so the user can continue their work
      @logger\debug msgs.readFile.jsonDecodeError, res
      backup = @filePath .. ".corrupted"
      fileOps.copy @filePath, backup
      fileOps.remove @filePath, false, true

      @logger\warn msgs.readFile.configCorrupted, backup
      return false, msgs.readFile.configCorrupted\format backup

    if "table" != type res
      return nil, msgs.readFile.badJsonRoot\format type res

    return res


  writeFile = (config, waitLockTime, haveLock = false) =>
    success, res = pcall json.encode, ConfigHandler\getSerializableCopy config
    unless success
      return nil, msgs.writeFile.failedSerialize\format res

    unless haveLock
      lockState, msg = @lock\lock waitLockTime
      if lockState != Lock.LockState.Held
        return nil, msgs.writeFile.failedLock\format msg

    handle, msg = io.open(@filePath, "w")
    unless handle
      @lock\release! unless haveLock
      return nil, msgs.writeFile.failedHandle\format msg

    @logger\trace msgs.writeFile.writing, @filePath
    handle\setvbuf "full", 10e6
    handle\write res
    handle\flush!
    handle\close!

    @lock\release! unless haveLock
    return true


  hasNonPrivateFields = (tbl) ->
    for k, _ in pairs tbl
      if k\sub(1, 1) == "_"
        continue
      else return true

    return false


  makeHive = (path, config) ->
    return config if #path == 0
    recurse = (path, hive, depth, config) ->
      return if depth > #path
      hive[path[depth]] = depth == #path and config or {}
      return recurse path, hive[path[depth]], depth + 1, config

    hive = {}
    recurse path, hive, 1, config
    return hive


  traverseHive = (path, config, depth = #path) ->
    for i, key in ipairs path
      break if i > depth
      switch type config
        when "nil"
          return false
        when "table"
          config = config[key]
        else
          return nil, msgs.traverseHive.badKey\format i, key, type config

    return config or false


  mergeHive = (path, source, target, depth = 1) ->
    -- merging in a root hive overwrites target with source
    if #path == 0
      target[k] = nil for k, _ in pairs target
      target[k] = source[k] for k, _ in pairs source
      return true

    key = path[depth]

    if depth == #path
      target[key] = source[key]
      return true

    if target[key] != nil and "table" != type target[key]
      return nil, msgs.mergeHive.badKey\format depth, key, type target[key]

    target[key] or= {}
    return mergeHive path, source[key], target[key], depth + 1


  purgeHive = (path, config) ->
    if #path == 0
      config[k] = nil for k, _ in pairs config

    for i = #path, 1, -1
      parent, msg = traverseHive path, config, i-1
      switch parent
        when nil then return nil, msg
        when false then continue

      parent[path[i]] = nil
      break if hasNonPrivateFields parent

    return true


  cleanHive = (path, config) ->
    hive, msg = traverseHive path, config
    return hive, msg if hive == nil
    return true if hive == false -- path absent in file config; nothing to purge

    return false if hasNonPrivateFields hive
    return purgeHive path, config


  -- copied from Aegisub util.moon, adjusted to skip private keys
  ---Deep-copies a value while skipping private keys prefixed with "_".
  ---@param val any
  ---@return any copy
  @getSerializableCopy = (val) =>
    seen = {}
    copy = (val) ->
      return val if type(val) != 'table'
      return {} if seen[val] -- nuke circular references which JSON doesn't support
      seen[val] = val
      {k, copy(v) for k, v in pairs val when type(k) != "string" or k\sub(1,1) != "_"}
    copy val


  ---Returns the config table at the given hive path, creating it if missing.
  ---@param path string[]
  ---@return table? hive
  ---@return string? err
  getHive: (path) =>
    hive, msg = traverseHive path, @config
    switch hive
      when nil
        return nil, msg
      when false
        res, msg = mergeHive path, makeHive(path), @config
        return nil, msg unless res

        hive, msg = traverseHive path, @config
        unless hive
          @logger\warn msgs.getHive.unexpected, path, @filePath
          return nil, msgs.getHive.unexpected\format path, @filePath

    return hive


  ---Returns views on the same handler whose hive paths overlap with targetView.
  ---@param targetView ConfigView
  ---@return ConfigView[]? views nil when targetView belongs to a different handler.
  ---@return string? err
  ---@private
  __getOverlappingViews: (targetView) =>
    if targetView.__configHandler != @
      return nil, msgs.__getOverlappingViews.differentHandler\format targetView.__configHandler.filePath, @filePath

    return for view, _ in pairs @views
      continue if view == targetView or not targetView\isOverlappingView view
      view


  ---Creates and registers a ConfigView for the given hive path.
  ---@param hivePath string|string[]
  ---@param defaults? table Default values for the hive.
  ---@return ConfigView? view
  ---@return string? err
  getView: (hivePath, defaults) =>
    success, view = pcall ConfigView, @, hivePath, defaults

    unless success
      return nil, msgs.getView.failedView\format hivePath, @filePath, view

    @views[view] = true
    return view


  ---Reads the config file and refreshes the in-memory config and all (or specified) views.
  ---@param views? ConfigView|ConfigView[] Views to refresh (default: all registered views).
  ---@param waitLockTime? number Seconds to wait for the config lock.
  ---@return boolean? success
  ---@return string? err
  load: (views, waitLockTime) =>
    return nil, msgs.load.noFilePath unless @filePath
    if type(views) == "table" and views.__class == ConfigView
      views = {views}

    config, msg = readFile @, waitLockTime
    return nil, msg if config == nil

    @logger\debug msgs.load.noFile, @filePath, msg unless config
    -- config file may not yet exist or have been reset due to corruption
    config or= {}

    if views == nil or @config == nil
      -- bring a pre-target config up to the handler's schema, then persist the one-time change
      migrated = false
      if @__migrate and @__targetSchemaId
        currentSchema = config[JsonSchema.JSON_SCHEMA_ID_KEYWORD]
        if currentSchema != @__targetSchemaId and @.__migrate config, currentSchema, @__targetSchemaId
          config[JsonSchema.JSON_SCHEMA_ID_KEYWORD] = @__targetSchemaId
          migrated = true
      @schemaId = config[JsonSchema.JSON_SCHEMA_ID_KEYWORD]

      @config = config
      view\refresh! for view, _ in pairs @views

      if migrated
        ok, msg = @save!
        @logger\warn msgs.load.migrationSaveFailed, @filePath, msg unless ok
      return true

    viewsToRefresh = Common.makeSet views

    for view in *views
      hiveConfig, msg = traverseHive view.__hivePath, config
      switch hiveConfig
        when nil
          return nil, msg
        when false
          mergeHive view.__hivePath, makeHive(view.__hivePath), @config
        else mergeHive view.__hivePath, makeHive(view.__hivePath, hiveConfig), @config

      Common.makeSet @__getOverlappingViews(view), viewsToRefresh, false

    view\refresh! for view, _ in pairs viewsToRefresh

    return true


  ---Writes the config file, merging only the specified views (or the full config if nil).
  ---@param views? ConfigView|ConfigView[] Views to merge (default: the whole config).
  ---@param waitLockTime? number Seconds to wait for the config lock.
  ---@return boolean? success
  ---@return string? err
  save: (views, waitLockTime) =>
    return nil, msgs.save.noFile unless @filePath
    if type(views) == "table" and views.__class == ConfigView
      views = {views}

    -- get a lock to avoid concurrent config file access
    lockState, msg = @lock\lock waitLockTime
    if lockState != Lock.LockState.Held
      return nil, msgs.save.failedLock\format msg

    -- read the config file under the lock we already hold (useLock false, or readFile would release it)
    config, err = readFile @, waitLockTime, false
    if config == nil
      @lock\release!
      return nil, msgs.save.failedRead\format @filePath, err

    @logger\trace msgs.save.fileCreate, @filePath unless config
    config or= {}

    -- save the whole config file if desired
    if views == nil
      success, msg = writeFile @, @config, nil, true
      @lock\release!
      return if success
        true
      else nil, msgs.save.failedWhole\format @filePath, msg

    -- otherwise only merge in the specified views
    for view in *views
      success, msg = mergeHive view.__hivePath, @config, config
      unless success
        @lock\release!
        return nil, msgs.save.failedMerge\format view.__hivePath, @filePath, msg

      success, msg = cleanHive view.__hivePath, config
      if success == nil
        @lock\release!
        return nil, msgs.save.failedClean\format view.__hivePath, @filePath, msg

    success, msg = writeFile @, config, nil, true
    @lock\release!
    return if success
      true
    else nil, msgs.save.failedHives\format views, @filePath, msg


  ---Removes a view's hive from the in-memory config and returns the fresh (empty) hive.
  ---@param hive ConfigView
  ---@return table? hive
  ---@return string? err
  purgeHive: (hive) =>
    purgeHive hive.__hivePath, @config
    return @getHive hive.__hivePath
