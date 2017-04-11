----
-- Lightweight autosync ORM for the SQLite database interface
-- @classmod SQLiteMapper

Logger = require "l0.DependencyControl.Logger"

class SQLiteMapper
  @SyncState = {
    New: 0
    Even: 1,
    ObjectAhead: 2
    DbAhead: 3
    Conflicted: 4
  }

  msgs = {
    new: {
      missingTimestampMapping: "Timestamp object key '%s' is missing its mapping to a table column."
    }
    getDescription: {
      template: "'%s' (%s:%s=%s)"
    }
    insertIntoDb: {
      creating: "Creating a database record for object %s..."
    }
    refreshSyncState: {
      refreshing: "Refreshing sync state for object %s ..."
      even: "SyncState: %s is even between object and database."
      new: "SyncState: object %s has not yet been synced to the database"
      conflicted: "SyncState: Changes between object and database state for %s are conflicted due to timestamps being unavailable.\nObject state: %s\nDB state: %s"
      conflictedTimestamp: "SyncState: Changes between object and database state for %s are conflicted due to timestamps being identical.\nObject state: %s\nDB state: %s"
      objectAhead: "SyncState: Database is ahead of object %s." 
      dbAhead: "SyncState: Object %s is ahead of database."
    }
    sync: {
      started: "Started sync for object %s ..."
      created: "SyncState: successfully created a database record for object %s."
      dbWritten: "SyncState: object changes have been successfully written to the database."
      objectWritten: "SyncState: object has been updated with database changes. "
      reconciled: "SyncState: object and database changes for %s have been successfully reconciled."
      failedReconcilation: "SyncState: failed to reconcile changes between object %s and database (Reason given by reconciler: %s)."
      conflicted: "SyncState: Reconciling conflicted changes beteen object %s and database...\nObject state: %s\nDB state: %s"
    }
  }

  new: (args) =>
    {object: @object, mappings: @mappings, db: @db, table: @table, name: @name,
     selectorColumn: @selectorColumn, selectorValue: @selectorValue,
     dbToObjectTransforms: @dbToObjectTransforms, objectToDbTransforms: @objectToDbTransforms,
     timestampKey: @timestampKey, :logger} = args

    @logger = logger or Logger fileBaseName: @@__name, fileSubName: "#{@table}_#{@selectorColumn}_@{selectorValue}"
    @name or= "(unnamed)"

    if @timestampKey
       @logger\assert @mappings[@timestampKey], msgs.new.missingTimestampMapping, @timestampKey

  getDescription = =>
    return msgs.getDescription.template\format @name, @table, @selectorColumn, @selectorValue

  getDiff: (dbState, objectState, countTimestamp) =>
    dbState, msg = @getDbState! unless dbState
    if dbState == nil
      return nil, msg
    else dbState or= {}

    objectState or= @getObjectState!

    objectValues, dbValues = {}, {}
    diffCount = 0

    for o, _ in pairs @mappings
      if dbState[o] != objectState[o]
        objectValues[o] = objectState[o]
        dbValues[o] = dbState[o]
        diffCount += 1 if o != @timestampKey or countTimestamp

    return diffCount, dbValues, objectValues


  refreshSyncState: (dbState, objectState) =>
    @logger\trace msgs.refreshSyncState.refreshing, getDescription @
    objectState or= @getObjectState!

    dbState, msg = @getDbState! unless dbState
    if dbState == nil
      return nil, msg
    elseif dbState == false
      @syncState, @dbTimestamp = @@SyncState.New
      @logger\debug msgs.refreshSyncState.new, getDescription @
      return @syncState

    if @timestampKey
      @dbTimestamp = dbState[@timestampKey]

    diffCount, dbValues, objectValues = @getDiff dbState, objectState
    if diffCount == 0
      @syncState = @@SyncState.Even
      @logger\debug msgs.refreshSyncState.even, getDescription @
      return @syncState

    objectTimestamp = @object[@timestampKey] if @timestampKey

    if not @timestampKey or not @dbTimestamp and not objectTimestamp
      @syncState = @@SyncState.Conflicted
      @logger\debug msgs.refreshSyncState.conflicted, getDescription(@),
                    @logger\dumpToString(objectState), @logger\dumpToString dbState 
      return @syncState, objectValues, dbValues


    if @dbTimestamp == objectTimestamp
      @syncState = @@SyncState.Conflicted
      @logger\debug msgs.refreshSyncState.conflictedTimestamp, getDescription(@),
                    @logger\dumpToString(objectState), @logger\dumpToString dbState 
      return @syncState, objectValues, dbValues

    @syncState = (@dbTimestamp or 0) < (objectTimestamp or 0) and @@SyncState.ObjectAhead or @@SyncState.DbAhead
    @logger\debug msgs.refreshSyncState[@syncState == @@SyncState.ObjectAhead and "objectAhead" or "dbAhead"],
                  getDescription @
    return @syncState, objectValues, dbValues


  getDbState: =>
    fields, msg = @db\selectFirst @table, nil, @selectorColumn, @selectorValue
    return fields, msg unless fields

    if @dbToObjectTransforms
      for o, d in pairs @mappings
        transform = @dbToObjectTransforms[o]
        fields[d] = transform fields[d], o if transform

    return {o, fields[d] for o, d in pairs @mappings}


  getObjectState: =>
    return {o, @object[o] for o, _ in pairs @mappings}


  sync: (reconciler, preprocessor, postprocessor) =>
    syncState, objectValues, dbValues = @refreshSyncState!
    @logger\trace msgs.sync.started, getDescription @

    switch syncState
      when @@SyncState.New
        res, msg = @insertIntoDb preprocessor
        if res
          @logger\debug msgs.sync.created, getDescription @
          @syncState = @@SyncState.Even
        else return nil, msg

      when @@SyncState.ObjectAhead
        if res = @updateDb objectValues, preprocessor
          @logger\debug msgs.sync.dbWritten, getDescription @
          @syncState = @@SyncState.Even
        else return nil

      when @@SyncState.DbAhead
        if res = @updateObject dbValues, postprocessor
          @logger\debug msgs.sync.objectWritten, getDescription @
          @syncState = @@SyncState.Even
        else return nil

      when @@SyncState.Conflicted
        @logger\debug msgs.sync.conflicted, getDescription(@),
                      @logger\dumpToString(objectValues), @logger\dumpToString dbValues

        reconciledValues, msg = reconciler dbValues, objectValues
        unless reconciledValues
          @logger\debug msgs.sync.failedReconcilation, getDescription @
        return nil, msg unless reconciledValues  -- todo add own msg part

        reconciledValues[@timestampKey] = os.time!

        res = @updateDb reconciledValues, preprocessor
        return nil unless res

        if res = @updateObject reconciledValues, postprocessor
          @logger\debug msgs.sync.reconciled, getDescription @
          @syncState = @@SyncState.Even
        else return nil

    return @syncState


  transformObjectValuesToDbFields = (objectValues) =>
    dbFields = {}
    for o, d in pairs @mappings
      dbFields[d] = if @objectToDbTransforms
        @objectToDbTransforms[o] objectValues[o], o
      else objectValues[o] 
    return dbFields


  updateDb: (objectValues, preprocessor) =>
    objectValues = objectValues and {o, objectValues[o] for o, _ in pairs @mappings} or @getObjectState!

    if @timestampKey
      objectValues[@timestampKey] or= @object[@timestampKey] 

    if preprocessor
      objectValues = preprocessor objectValues

    res, msg = @db\update @table, transformObjectValuesToDbFields(@, objectValues), 
                         nil, @selectorColumn, @selectorValue
    
    return res, msg unless res

    if @timestampKey
      @dbTimestamp = objectValues[@timestampKey]

    return true


  updateObject: (dbValues, postprocessor) => 
    dbValues = dbValues and {o, dbValues[o] for o, _ in pairs @mappings} or @getDbState!

    if @timestampKey
      dbValues[@timestampKey] or= @dbTimestamp

    if postprocessor
      dbValues = postprocessor dbValues


    @object[o] = dbValues[o] for o, _ in pairs @mappings
    
    return true


  insertIntoDb: (preprocessor) =>
    objectValues = @getObjectState!

    if @timestampKey
      objectValues[@timestampKey] or= @object[@timestampKey]

    if preprocessor
      objectValues = preprocessor objectValues

    res, msg = @db\insert @table, transformObjectValuesToDbFields @, objectValues

    return res, msg unless res
    return true