SQLiteDatabase   = require "l0.DependencyControl.SQLiteDatabase"
SQLiteMapper     = require "l0.DependencyControl.SQLiteMapper"
Common           = require "l0.DependencyControl.Common"
Logger           = require "l0.DependencyControl.Logger"
ConfigHandler    = require "l0.DependencyControl.ConfigHandler"
DependencyRecord = require "l0.DependencyControl.DependencyRecord"
fileOps          = require "l0.DependencyControl.FileOps"

INSTALLED_PACKAGES_TABLE = "InstalledPackages"

recordMappings = {
    namespace: "Namespace"
    name: "Name"
    version: "Version"
    scriptType: "ScriptType"
    recordType: "RecordType"
    author: "Author"
    description: "Description"
    url: "WebURL"
    feed: "FeedURL"
    installState: "InstallState"
    timestamp: "Timestamp"
}

packageFields = {"timestamp", "installState"}
packageFieldSet = {field, true for field in *packageFields}
recordFieldSet = {field, true for field, _ in pairs recordMappings when not packageFieldSet[field]}

class Package
    msgs = {
        new: {
            badRecord: "Record must be either a namespace or a DependencyControl record, got a %s."
            syncFailed: "Couldn't sync record '%s' with package registry: %s"
            dbConnectFailed: "Failed to connect to the DependencyControl database (%s)."
            configFailed: "Couldn't get DependencyControl config for package '%s' (%s)."
        }
        find: {
            noSuchPackage: "No installed package found with name '%s'"
        }
        getAll: {
            retrieveFailed: "Failed to retrieve installed packages from database: %s"
        }
        getDatabase: {
            foundDefaultSchema: "Found schema for database '%s' at '%s'..."
        }
        getInstallState: {
            retrieveFailed: "Couldn't retrieve install state for %s from package registry: %s"
        }
        sync: {
            running: "Syncing package '%s' state: %s -> %s (Mode: %s)"
            modes: {"read-only", "prefer read", "prefer write"}
            conflicted: "Version record for '%s' is conflicted with its install information in the package registry. Resolving in '%s' mode..."
        }
        writeConfig: {
            error: "An error occured while writing the #{@@__name} config file: %s"
            writing: "Writing updated %s data to config file..."
        }
        uninstall: {
            noUnmanaged: "Can't uninstall unmanaged %s '%s'. (Only installed scripts managed by DependencyControl can be uninstalled)."
        }
        update: {
            noUnmanaged: "Can't update '%s': %s is not managed by DependencyControl."
            updaterDisabled: "Skipping update check for %s (Updater disabled)."
            runningUpdate: "Running scheduled update for %s '%s'..."
        }
    }
    DependencyControl, db = nil
    @logger = Logger fileBaseName: "DependencyControl.Package"

    @InstallState = {
        Orphaned: -1   -- Package is installed but DepCtrl hasn't seen it around in a while (not yet implemented)
        Absent: 0      -- Package is not installed (not yet implemented)
        Pending: 1     -- Package is scheduled for installation (not yet implemented)
        Downloaded: 2  -- Package has been downloaded and is waiting for a script reload to finish installation
        Installed: 3   -- Package has successfully loaded recently
    }

    @SyncMode = {
        Auto: -1
        ReadOnly: 0
        PreferRead: 1
        PreferWrite: 2
    }

    @__injectDependencyControl = (depCtrl) => 
        DependencyControl = depCtrl

    @find = (namespace, logger = @logger) =>
        pkgState, pkgInfo = @getInstallState namespace
        return nil, pkgInfo unless pkgState

        if pkgState < @InstallState.Downloaded
            return false, msgs.find.noSuchPackage, namespace

        pkg = if pkgInfo.scriptType == DependencyRecord.ScriptType.Module
            @ (DependencyRecord moduleName: namespace), logger
        else @ (DependencyRecord :namespace), logger

        pkg\sync!
        return pkg


    @getAll = (scriptType, logger = @logger) =>
        db or= SQLiteDatabase "l0.DependencyControl", nil, 200, logger
        packages, msg = db\select INSTALLED_PACKAGES_TABLE
        return nil, msgs.getAll.retrieveFailed\format msg unless packages

        return for pkg in *packages
            continue if pkg.InstallState < @InstallState.Downloaded
            continue if scriptType and pkg.ScriptType != scriptType

            pkg = if pkg.scriptType == DependencyRecord.ScriptType.Module
                @ (DependencyRecord moduleName: pkg.Namespace), logger
            else @ (DependencyRecord namespace: pkg.Namespace), logger

            pkg\sync!
            pkg


    @getInstallState = (namespace, scriptType = nil) =>
        db or= SQLiteDatabase "l0.DependencyControl", nil, 200, @logger

        constraints = Namespace: namespace
        if scriptType
            constraints.ScriptType = scriptType

        packageInfo, msg = db\selectFirst INSTALLED_PACKAGES_TABLE, nil, constraints
        return switch packageInfo
            when nil
                nil, msgs.getInstallState.retrieveFailed\format namespace, msg
            when false
                @@InstallState.Absent
            else packageInfo.InstallState, packageInfo

    
    -- connects to an exisiting database or creates and inititalizes one in case it doesn't exist  
    -- private method, as it allows unrestricted namespace choice
    getDatabase = (namespace, init = true, scriptType, logger = @logger, retryCount) =>
        if init == true
            defaultSchemaPath = fileOps.getNamespacedPath Common.automationDir[scriptType],
                                namespace, ".sql", scriptType == DependencyRecord.ScriptType.Module
            mode = fileOps.attributes defaultSchemaPath, "mode"
            if mode == "file"
                logger\trace msgs.getDatabase.foundDefaultSchema, namespace, defaultSchemaPath
                init = defaultSchemaPath
            else init = nil

        success, db = pcall SQLiteDatabase, namespace, init, retryCount, logger
        if success
            return db
        else return nil, db

    -- public version of the database provider
    -- restricts a package to database names within its own namespace
    getDatabase: (namespaceExtension = "", init = true) =>
        namespace = @namespace
        namespace ..= ".#{namespaceExtension}" if namespaceExtension
        return getDatabase @@, namespace, init, @scriptType, @logger

    new: (dependencyRecord, @logger = @@logger) =>
        db, msg = getDatabase @@, "l0.DependencyControl", true,
                                  DependencyRecord.ScriptType.Module, @logger, 200 unless db
        @logger\assert db, msgs.new.dbConnectFailed, msg

        meta = getmetatable @
        clsIdx = meta.__index
        packageFieldStore = timestamp: -1

        meta.__index = (key) => 
            if recordFieldSet[key]
                @dependencyRecord[key]
            elseif packageFieldSet[key]
                packageFieldStore[key]
            else switch type clsIdx
                when "function" then clsIdx @, key
                when "table" then clsIdx[key]

        meta.__newindex = (k, v) =>
            if recordFieldSet[k]
                @dependencyRecord[k] = v
                packageFieldStore.timestamp = os.time!
            elseif packageFieldSet[k]
                packageFieldStore[k] = v
                packageFieldStore.timestamp = os.time! if k != 'timestamp'
            else
                rawset @, k, v

        @@logger\assert DependencyRecord\isDependencyRecord(dependencyRecord), msgs.new.badRecord, 
                        Logger\describeType dependencyRecord
        @dependencyRecord = dependencyRecord

        @mapper = SQLiteMapper {
            object: @
            mappings: recordMappings
            :db
            table: INSTALLED_PACKAGES_TABLE
            name: @dependencyRecord.namespace
            selectorColumn: "Namespace"
            selectorValue: @dependencyRecord.namespace
            timestampKey: "timestamp"
            logger: @logger
        }

        packageFieldStore.installState, msg = @@getInstallState @namespace, @scriptType
        @logger\assert packageFieldStore.installState,
                       msgs.getInstallState.retrieveFailed, @namespace, msg

        @config, msg = ConfigHandler\getView Common.globalConfig.file, { DependencyRecord.ScriptType.name.canonical[@scriptType], @namespace },
                                             Common.defaultScriptConfig
        @logger\assert @config, msgs.new.configFailed, @namespace, msg


    apply: (record) =>
        @dependencyRecord[k] or= record[k] for k, _ in pairs recordFieldSet
        @timestamp = os.time!


    sync: (mode = @@SyncMode.Auto, installState) =>
        @logger\trace msgs.sync.running, @namespace, @installState, installState or "(#{@installState})", mode

        if installState
            @installState = installState

        if mode == @@SyncMode.Auto
            mode = @timestamp > -1 and @@SyncMode.PreferWrite or @@SyncMode.ReadOnly

        -- handle uninstalls and prevent absent packages from being written to the database
        if @installState == @@InstallState.Absent
            syncState, objectValues, dbValues = @mapper\refreshSyncState!
            if syncState == SQLiteMapper.SyncState.New
                return SQLiteMapper.SyncState.New
            if mode > @@SyncMode.ReadOnly and objectValues.timestamp > dbValues.timestamp
                -- TODO: delete db entry
                return SQLiteMapper.SyncState.Deleted

        reconciler = (dbValues, objectValues, keys) ->
            @logger\warn msgs.sync.conflicted, @dependencyRecord.namespace, msgs.sync.modes[mode-1]
            return mode >= @@SyncMode.PreferWrite and objectValues or dbValues, keys

        res, msg = @mapper\sync reconciler, nil, nil, 
                                @mode == @@SyncMode.ReadOnly and SQLiteMapper.SyncDirection.DbToObject or SQLiteMapper.SyncDirection.Both

        @logger\debug msgs.new.syncFailed, @dependencyRecord.namespace, msg unless res
        return res, msg


    update: (ignoreInterval) =>
        unless @config.c.updaterEnabled
            @logger\trace msgs.update.updaterDisabled, @name
            return false

        -- no regular updates for non-existing or unmanaged modules
        if @recordType == DependencyRecord.RecordType.Unmanaged
            return nil, msgs.update.noUnmanaged\format Common.terms.scriptType.singular[@scriptType], @name

        -- the update interval has not yet been passed since the last update check
        lastCheck, msg = db\selectFirst "UpdateChecks", nil, Namespace: @namespace
        return nil, msg if lastCheck == nil

        if lastCheck and lastCheck.Time + DependencyControl.config.c.updateInterval > os.time!
            return false
        elseif not lastCheck
            db\insert "UpdateChecks", Namespace: @namespace, Time: os.time!, TotalCount: 1

        else db\update "UpdateChecks", {Time: os.time!, TotalCount: lastCheck.TotalCount + 1},
                        nil, "Namespace", @namespace

        task = DependencyControl.updater\addTask @dependencyRecord -- no need to check for errors, as we've already accounted for those case
        @logger\trace msgs.update.runningUpdate,
                      Common.terms.scriptType.singular[@dependencyRecord.scriptType], @dependencyRecord.name
        return task\run!


    -- currently completely broken; TODO: rewrite
    uninstall: (config) =>
        if @recordType == DependencyRecord.RecordType.Unmanaged
            return nil, msgs.uninstall.noUnmanaged\format Common.terms.scriptType.singular[@scriptType], @name
        @loadConfig!
        @config\delete!

        subModules, mdlConfig = @getSubmodules!
        -- uninstalling a module also removes all submodules
        if subModules and #subModules > 0
            mdlConfig.c[mdl] = nil for mdl in *subModules
            mdlConfig\write!

        toRemove, pattern, dir = {}
        if @scriptType == DependencyRecord.ScriptType.Module
            nsp, name = @namespace\match "(.+)%.(.+)"
            pattern = "^#{name}"
            dir = "#{@automationDir}/#{nsp\gsub '%.', '/'}"
        else
            pattern = "^#{@namespace}"\gsub "%.", "%%."
            dir = @automationDir

        lfs.chdir dir
        for file in lfs.dir dir
            mode, path = fileOps.attributes file, "mode"
            -- parent level module files must be <last part of namespace>.ext
            currPattern = @scriptType == DependencyRecord.ScriptType.Module and mode == "file" and pattern.."%." or pattern
            -- automation scripts don't use any subdirectories
            if (@scriptType == DependencyRecord.ScriptType.Module or mode == "file") and file\match currPattern
                toRemove[#toRemove+1] = path
        return fileOps.remove toRemove, true, true

    -- loads the script configuration
    loadConfig: => @config\load!


    saveConfig: =>
        @@logger\trace msgs.writeConfig.writing, Common.terms.scriptType.singular[@scriptType]
        success, errMsg = @config\save!

        assert success, msgs.writeConfig.error\format errMsg


    [[
    writeRecord: (@record) =>
        -- creates or updates a record

    deleteRecord: (namespace) =>
        -- removes a script record

    uninstall: (namespace) =>
        -- uninstalls a script: removes files, records

    registerMacro: (name) ->
        -- checks registered macros on db, purges all oder than n seconds
        -- if macro with name already present -> return false
        -- else add row with name, @record and timestamp -> return true
    ]]