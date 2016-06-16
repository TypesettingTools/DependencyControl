SQLiteDatabase = require "l0.DependencyControl.SQLiteDatabase"
Common         = require "l0.DependencyControl.Common"
Logger         = require "l0.DependencyControl.Logger"
VersionRecord  = require "l0.DependencyControl.VersionRecord"
ConfigHandler  = require "l0.DependencyControl.ConfigHandler"
DummyRecord    = require "l0.DependencyControl.DummyRecord"
fileOps        = require "l0.DependencyControl.FileOps"

selectPackageTemplate = "SELECT * FROM 'InstalledPackages' WHERE Namespace = '%s'"
recordMappings = {
    Namespace: "namespace"
    Name: "name"
    Version: "version"
    ScriptType: "scriptType"
    RecordType: "recordType"
    Author: "author"
    Description: "description"
    WebURL: "url"
    FeedURL: "feed"
    InstallState: "installState"
}

map = (source, target, mappings, reverse) ->
    mappings = {v, k for k, v in pairs mappings} if reverse
    target[v] = source[k] for k, v in pairs mappings
    return target

diff = (left, right, mappings, reverse) ->
    diffed, d = {}, 0
    for k, v in pairs mappings
        k, v = v, k if reverse
        if left[k] != right[v]
            d += 1
            diffed[k] = right[v]

    return diffed, d


class InstalledPackage extends VersionRecord
    msgs = {
        new: {
            noSuchPackage: "No installed package found with name '%s'"
            badRecord: "Record must be either a namespace or a DependencyControl record, got a %s."
            noDummyRecord: "Can't create #{@@__name} for '%s' because a dummy record was supplied."
            syncFailed: "Couldn't sync package record with registry: %s"
            dbConnectFailed: "Failed to connect to the DependencyControl database (%s)."
        }
        getDatabase: {
            foundDefaultSchema: "Found schema for database '%s' at '%s'..."
        }
        getInstallState: {
            retrieveFailed: "Couldn't retrieve install state for %s from package registry: %s"
        }
        sync: {
            dbRecordUpToDate: "Install record for '%s' is already up-to-date"
            writingRecord: "Writing updated install record for '%s' to the package registry (%s mode)..."
            retrievingRecord: "Retrieving updated install record for '%s' from the package registry (%s mode)..."
            creatingRecord: "Creating new install record for '%s'..."
            modes: {"auto", "read", "force read", "write", "force write"}
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
    @logger = Logger fileBaseName: "DependencyControl.InstalledPackage"

    @InstallState = {
        Orphaned: -1
        Absent: 0
        Pending: 1
        Downloaded: 2
        Installed: 3
    }

    @SyncMode = {
        Auto: 0
        Read: 1
        ForceRead: 2
        Write: 3
        ForceWrite: 4
    }

    @getInstallState = (namespace) =>
        db or= SQLiteDatabase "l0.DependencyControl", nil, 200, @logger

        packageInfo, msg = db\selectFirst "InstalledPackages", nil, "Namespace", namespace
        return switch packageInfo
            when nil
                nil, msgs.getInstallState.retrieveFailed\format namespace, msg
            when false
                @@InstallState.Absent
            else packageInfo.InstallState, packageInfo

    getDatabase = (namespace, init = true, scriptType, logger = @logger, retryCount) =>
        if init == true
            defaultSchemaPath = fileOps.getNamespacedPath @@automationDir[scriptType],
                                namespace, ".sql", scriptType == @@ScriptType.Module
            mode = fileOps.attributes defaultSchemaPath, "mode"
            if mode == "file"
                logger\trace msgs.getDatabase.foundDefaultSchema, namespace, defaultSchemaPath
                init = defaultSchemaPath
            else init = nil

        success, db = pcall SQLiteDatabase, namespace, init, retryCount, logger
        if success
            return db
        else return nil, db


    new: (record, @logger = @@logger, dummyInitState) =>
        db or= SQLiteDatabase "l0.DependencyControl", nil, 200, @logger
        @package = @
        @timestamp = os.time!

        if type(record) == "string" or @@isVersionRecord record, DummyRecord
            -- getting a package record by namespace means we have to pull it from the db
            namespace = type(record) == "string" and record or record.namespace

            installState, packageInfo = @logger\assert @@getInstallState namespace
            @logger\assert installState > @@InstallState.Absent, msgs.new.noSuchPackage, namespace

            -- import script information properties from db
            map packageInfo, @, recordMappings

        elseif @@isVersionRecord record
            DependencyControl or= record.__class if record.__class.__name == "DependencyControl"

            @logger\assert record.__class != DummyRecord or acceptDummyRecords,
                           msgs.new.noDummyRecord, record.namespace

            -- import script information properties from DependencyControl record
            @[v] = record[v] for _, v in pairs recordMappings
            res, msg = @sync nil, record.__class == DummyRecord and dummyInitState or nil
            @logger\assertNotNil res, msgs.new.syncFailed, msg

        else @logger\error msgs.new.badRecord, type record

        record.package = @ if record.__class == DummyRecord
        @loadConfig!


    getDatabase: (namespaceExtension = "", init = true) =>
        namespace = @namespace
        namespace ..= ".#{namespaceExtension}" if namespaceExtension
        return getDatabase @@, namespace, init, @scriptType, @logger


    import: (source, sourceIgnore = {"installState", "namespace"}) =>
        -- TODO: sanity checks for namespace, version rules
        sourceIgnoreSet = {v, true for v in *sourceIgnore}
        @[v] = source[v] for _, v in pairs @recordMappings when not sourceIgnoreSet[v]


    sync: (mode = @@SyncMode.Auto, installState) =>
        @installState or= installState or @@InstallState.Installed
        mode = @@SyncMode.Write if installState and mode < @@SyncMode.Write

        -- check if the package registry entry needs to be updated with current record information
        packageInfo, msg = db\selectFirst "InstalledPackages", nil, "Namespace", @namespace
        return nil, msg if packageInfo == nil

        -- sync existing records
        if packageInfo
            changes, c = diff packageInfo, @, recordMappings

            if c == 0  -- records are already in sync
                @logger\trace msgs.sync.dbRecordUpToDate, @namespace
                return false

            -- package registry entry if it is out-of-date or a write is being forced
            registryNeedsUpdate = packageInfo.SyncTime < @timestamp
            if registryNeedsUpdate and mode >= @@SyncMode.Write or mode == @@SyncMode.ForceWrite
                @logger\trace msgs.sync.writingRecord, @namespace, msgs.sync.mode[mode-1]
                @timestamp = os.time!
                changes.SyncTime = @timestamp
                db\update "InstalledPackages", changes, nil, "Namespace", @namespace -- TODO: error handling
                return true, registryNeedsUpdate and @@SyncMode.Write or @@SyncMode.ForceWrite

            -- this record is out out-of-date or a read is being forced
            recordNeedsUpdate = @timestamp < packageInfo.SyncTime
            if recordNeedsUpdate and mode < @@SyncMode.Write or mode == @@SyncMode.ForceRead
                @logger\trace msgs.sync.retrievingRecord, @namespace, msgs.sync.mode[mode-1]
                @[k] = v for k, v in pairs changes
                @timestamp = packageInfo.SyncTime
                return true, recordNeedsUpdate and @@SyncMode.Read or @@SyncMode.ForceRead

            else return false

        -- register new installed package
        @logger\trace msgs.sync.creatingRecord, @namespace
        @timestamp = os.time!
        res, msg = db\insert "InstalledPackages", map(@, {SyncTime: @timestamp}, recordMappings, true),
                              nil, "IGNORE"
        return nil, msg unless res
        return true, @@SyncMode.Write


    update: (ignoreInterval) =>
        unless @config.c.updaterEnabled
            @logger\trace msgs.update.updaterDisabled, @name
            return false

        -- no regular updates for non-existing or unmanaged modules
        if @recordType == @@RecordType.Unmanaged
            return nil, msgs.update.noUnmanaged\format @@terms.scriptType.singular[@scriptType], @name

        -- the update interval has not yet been passed since the last update check
        lastCheck, msg = db\selectFirst "UpdateChecks", nil, "Namespace", @namespace
        return nil, msg if lastCheck == nil

        if lastCheck and lastCheck.Time + DependencyControl.config.c.updateInterval > os.time!
            return false
        elseif not lastCheck
            db\insert "UpdateChecks", Namespace: @namespace, Time: os.time!, TotalCount: 1

        else db\update "UpdateChecks", {Time: os.time!, TotalCount: lastCheck.TotalCount + 1},
                        nil, "Namespace", @namespace

        task = DependencyControl.updater\addTask record -- no need to check for errors, as we've already accounted for those case
        @logger\trace msgs.update.runningUpdate,
                      @@terms.scriptType.singular[record.scriptType], record.name
        return task\run!


    -- currently completely broken; TODO: rewrite
    uninstall: (config) =>
        if @recordType == @@RecordType.Unmanaged
            return nil, msgs.uninstall.noUnmanaged\format @@terms.scriptType.singular[@scriptType], @name
        @loadConfig!
        @config\delete!

        subModules, mdlConfig = @getSubmodules!
        -- uninstalling a module also removes all submodules
        if subModules and #subModules > 0
            mdlConfig.c[mdl] = nil for mdl in *subModules
            mdlConfig\write!

        toRemove, pattern, dir = {}
        if @scriptType == @@ScriptType.Module
            nsp, name = @namespace\match "(.+)%.(.+)"
            pattern = "^#{name}"
            dir = "#{@automationDir}/#{nsp\gsub '%.', '/'}"
        else
            pattern = "^#{@namespace}"\gsub "%.", "%%."
            dir = @automationDir

        lfs.chdir dir
        for file in lfs.dir dir
            mode, path = FileOps.attributes file, "mode"
            -- parent level module files must be <last part of namespace>.ext
            currPattern = @scriptType == @@ScriptType.Module and mode == "file" and pattern.."%." or pattern
            -- automation scripts don't use any subdirectories
            if (@scriptType == @@ScriptType.Module or mode == "file") and file\match currPattern
                toRemove[#toRemove+1] = path
        return FileOps.remove toRemove, true, true

    -- loads the script configuration
    loadConfig: =>
        @config or= ConfigHandler @@globalConfig.file, {},
                                  { @@ScriptType.name.legacy[@scriptType], @namespace }, true, @logger
        return @config\load!


    writeConfig: =>
        @loadConfig! unless @config
        @@logger\trace msgs.writeConfig.writing, @@terms.scriptType.singular[@scriptType]
        success, errMsg = @config\write false

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