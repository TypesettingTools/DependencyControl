SQLiteDatabase = require "l0.DependencyControl.SQLiteDatabase"
SQLiteMapper   = require "l0.DependencyControl.SQLiteMapper"
Common         = require "l0.DependencyControl.Common"
Logger         = require "l0.DependencyControl.Logger"
VersionRecord  = require "l0.DependencyControl.VersionRecord"
ConfigHandler  = require "l0.DependencyControl.ConfigHandler"
DummyRecord    = require "l0.DependencyControl.DummyRecord"
fileOps        = require "l0.DependencyControl.FileOps"

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

class InstalledPackage extends Common
    msgs = {
        new: {
            badRecord: "Record must be either a namespace or a DependencyControl record, got a %s."
            noUninitializedDummyRecord: "Couldn't retrieve #{@@__name} for #{DummyRecord.__name} '%s' because it is not installed and no initial install state was supplied."
            syncFailed: "Couldn't sync record '%s' with package registry: %s"
            dbConnectFailed: "Failed to connect to the DependencyControl database (%s)."
        }
        getDatabase: {
            foundDefaultSchema: "Found schema for database '%s' at '%s'..."
        }
        getInstallState: {
            retrieveFailed: "Couldn't retrieve install state for %s from package registry: %s"
        }
        sync: {
            modes: {"auto", "prefer read", "force read", "prefer write", "force write"}
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
    @logger = Logger fileBaseName: "DependencyControl.InstalledPackage"

    @InstallState = {
        Orphaned: -1   -- Package is installed but DepCtrl hasn't seen it around in a while (not yet implemented)
        Absent: 0      -- Package is not installed (not yet implemented)
        Pending: 1     -- Package is scheduled for installation (not yet implemented)
        Downloaded: 2  -- Package has been downloaded and is waiting for a script reload to finish installation
        Installed: 3   -- Package has successfully loaded recently
    }

    @SyncMode = {
        Auto: 0
        PreferRead: 1
        ForceRead: 2
        PreferWrite: 3
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


    __newindex: (k, v) =>
        if recordFieldSet[k]
            @record[k] = v 
        else rawset @, k, v

    new: (record, @logger = @@logger, dummyInitState) =>
        db, msg = getDatabase @@, "l0.DependencyControl", true,
                                  @@ScriptType.Module, @logger, 200 unless db
        @logger\assert db, msgs.new.dbConnectFailed, msg

        meta = getmetatable @
        clsIdx = meta.__index
        meta.__index = (key) => 
            if recordFieldSet[key]
                @record[key]
            else switch type clsIdx
                when "function" then clsIdx @, key
                when "table" then clsIdx[key]

        @@logger\assert VersionRecord\isVersionRecord(record), msgs.new.badRecord, 
                        Logger\describeType record
        @record = record

        -- hack to allow DepCtrl to update itself
        DependencyControl or= record.__class if record.__class.__name == "DependencyControl"

        @mapper = SQLiteMapper {
            object: @
            mappings: recordMappings
            :db
            table: "InstalledPackages"
            name: @record.namespace
            selectorColumn: "Namespace"
            selectorValue: @record.namespace
            timestampKey: "timestamp"
            logger: @logger
        }

        @mapper\refreshSyncState!

        -- only allow dummy records specifically marked as downloaded to become an installed package
        if VersionRecord\isVersionRecord record, DummyRecord
            @logger\assert @mapper.syncState != SQLiteMapper.SyncState.New or dummyInitState == @@InstallState.Downloaded, 
                           msgs.new.noUninitializedDummyRecord, @record.namespace
        
            @timestamp = dummyInitState == @@InstallState.Downloaded and os.time! or -1

        else @timestamp = os.time!

        res, msg = @sync nil, record.__class == DummyRecord and dummyInitState or nil
        @logger\assertNotNil res, msgs.new.syncFailed, @record.namespace, msg

        @loadConfig!


    getDatabase: (namespaceExtension = "", init = true) =>
        namespace = @namespace
        namespace ..= ".#{namespaceExtension}" if namespaceExtension
        return getDatabase @@, namespace, init, @scriptType, @logger


    sync: (mode = @@SyncMode.Auto, installState) =>
        @installState or= installState or @@InstallState.Installed

        -- TODO: reintroduce force read and write support
        mode = @@SyncMode.Write if installState and mode < @@SyncMode.PreferWrite

        res, msg = @mapper\sync (dbValues, objectValues) ->
            mode = @@SyncMode.PreferWrite if mode == @@SyncMode.Auto
            
            @logger\warn msgs.sync.conflicted, @record.namespace, msgs.sync.modes[mode-1]
            return mode == @@SyncMode.PreferWrite and objectValues or dbValues

        @logger\debug msgs.new.syncFailed, @record.namespace, msg unless res
        return res, msg


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

        task = DependencyControl.updater\addTask @record -- no need to check for errors, as we've already accounted for those case
        @logger\trace msgs.update.runningUpdate,
                      @@terms.scriptType.singular[@record.scriptType], @record.name
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

