----
-- SQLite database interface with some helper methods to craft statements
-- @classmod SQLiteDatabase

lfs = require "lfs"
lsqlite3 =     require "lsqlite3"
Logger =       require "l0.DependencyControl.Logger"
fileOps =      require "l0.DependencyControl.FileOps"
PreciseTimer = require "PT.PreciseTimer"
Enum =         require "l0.DependencyControl.Enum"

-- TODO: implement default, overridable progress callback
class SQLiteDatabase
    dbPath = "?user/db"
    msgs = {
        busyHandler: {
            retry: "Database '%s' is busy, retrying (%d/%d)..."
            abort: "Aborted transaction to database '%s': retry limit (%d) reached."
        }
        decodeResult: {
            results: {
                [lsqlite3.OK]: "The operation completed successfully."
                [lsqlite3.ERROR]: "An error occured while processing the query."
                [lsqlite3.INTERNAL]: "An internal error occured in the SQLite engine."
                [lsqlite3.PERM]: "The requested access mode for the created database could not be provided."
                [lsqlite3.ABORT]: "The operation was aborted prior to completion."
                [lsqlite3.BUSY]: "The database file could not be accessed due to concurrent activity by another database connection."
                [lsqlite3.LOCKED]: "A write operation could not continue because of a conflict within the same database connection."
                [lsqlite3.NOMEM]: "SQLite was unable to allocate the memory required to complete the operation."
                [lsqlite3.READONLY]: "Could not perform write operation: database connection is read-only."
                [lsqlite3.INTERRUPT]: "The operation was interrupted."
                [lsqlite3.IOERR]: "The operation could not finish because the operating system reported an I/O error. "
                [lsqlite3.CORRUPT]: "The database file has been corrupted."
                [lsqlite3.NOTFOUND]: "The provided file control opcode could not be recognized by the VFS."
                [lsqlite3.FULL]: "The write operation could not complete: disk is full."
                [lsqlite3.CANTOPEN]: "Could not open the database file."
                [lsqlite3.PROTOCOL]: "Could not perform the WAL transaction due to excessive contention between database connections."
                [lsqlite3.EMPTY]: "(unused)"
                [lsqlite3.SCHEMA]: "A prepared statement couldn't be updated after the database schema changed."
                [lsqlite3.TOOBIG]: "Couldn't perform operation: maximum string or blob size exceeded."
                [lsqlite3.CONSTRAINT]: "An SQL constraint violation occurred while trying to process the SQL statement."
                [lsqlite3.MISMATCH]: "Couldn't perform operation: type mismatch."
                [lsqlite3.MISUSE]: "Unsupported SQLite interface use detected."
                [lsqlite3.NOLFS]: "Couldn't perform operation: maxium file size exceeded."
                [lsqlite3.FORMAT]: "(unused)"
                [lsqlite3.RANGE]: "Couldn't bind value to prepared statemnt: parameter number out of range."
                [lsqlite3.NOTADB]: "Couldn't open database: file is not an SQLite database."
                [lsqlite3.ROW]: "A new row of data is ready for processing."
                [lsqlite3.DONE]: "The statement or operation has finished executing successfully."
                unknownDetail: "An unknown error (%d) occured: %s"
                unknown: "An unknown error (%d) occured."
            }
        }
        exec: {
            errorDetail: "In statement '%s': %s"
        }
        getSchemaUpgrades: {
            noSchemaDirectory: "No such schema directory: %s"
            unrecognizedFile: "Skipped unrecognized schema file '%s'..."
            failedReadFile: "Failed to read schema file '%s' (%s)."
        }
        getInitializerType: {
            cantStatPath: "Can't access path to database initializer '%s': %s"
            badPathMode: "Expected path to database initializer '%s' to be a file or directory, got a %s."
        }
        init: {
            execFailed: "Could not initialize database: SQL execution failed with code %d (%s)."
            noInitializer: "No database intializer specified."
        }
        insert: {
            unsupportedType: "Could not insert Lua table into database table '%s': value '%s' of field '%s' with type '%s' is not supported."
        }
        exists: {
            cantStatPath: "Can't access path to database '%s' (%s): %s"
            notAFile: "Path to database '%s' (%s) must point to a file, got a %s."
        }
        open: {
            initFailed: "Failed to initialize database structure: %s"
        }
        select: {
            conditionColumnValueCountMismatch: "Select conditions must have the sumber number of columns as "
        }
        traceCallback: {
            runningStatement: "Running statement \"%s\" on database \"%s\"..."
        }
        common: {
            notOpen: "No open database connection."
            execFailed: "SQL execution failed with code %d (%s)."
        }
        upgradeSchema: {
            currentVersion: "Database '%s' is at schema version %d"
            noPathToNewerVersion: "An upgrade to database '%s' schema version %d exists, but no path to reach prerequisite version %d is available from highest reachable version %d."
            targetNotReached: "Could not find an upgrade path to target schema version %d (current version: %d; highest reachable: %d)"
            upgradeFailed: "Could not perform database upgrade from schema version %d to version %d: SQL execution failed with code %d (%s)."
            noSchemaDirectory: "Could not find or access default or specified schema directory %s."
        }
    }

    --- SQLite status code constants
    @Result = Enum "Result", {
        OK: lsqlite3.OK
        ERROR: lsqlite3.ERROR
        INTERNAL: lsqlite3.INTERNAL
        PERM: lsqlite3.PERM
        ABORT: lsqlite3.ABORT
        BUSY: lsqlite3.BUSY
        LOCKED: lsqlite3.LOCKED
        NOMEM: lsqlite3.NOMEM
        READONLY: lsqlite3.READONLY
        INTERRUPT: lsqlite3.INTERRUPT
        IOERR: lsqlite3.IOERR
        CORRUPT: lsqlite3.CORRUPT
        NOTFOUND: lsqlite3.NOTFOUND
        FULL: lsqlite3.FULL
        CANTOPEN: lsqlite3.CANTOPEN
        PROTOCOL: lsqlite3.PROTOCOL
        EMPTY: lsqlite3.EMPTY
        SCHEMA: lsqlite3.SCHEMA
        TOOBIG: lsqlite3.TOOBIG
        CONSTRAINT: lsqlite3.CONSTRAINT
        MISMATCH: lsqlite3.MISMATCH
        MISUSE: lsqlite3.MISUSE
        NOLFS: lsqlite3.NOLFS
        FORMAT: lsqlite3.FORMAT
        RANGE: lsqlite3.RANGE
        NOTADB: lsqlite3.NOTADB
        ROW: lsqlite3.ROW
        DONE: lsqlite3.DONE
    }

    @Operators = Enum "Operators", {
        AND: 0
        OR: 1
    }

    @InitializerType = Enum "InitializerType", {
        None: 0,
        SchemaFile: 1,
        SchemaDirectory: 2,
        SqlSequence: 3,
        Function: 4
    }

    --- Translates an SQLite error code into a descriptive message.
    -- @static
    -- @tparam number code an error code returneed by @{SQLiteDatabase:exec}, @{SQLiteDatabase:init},
    --                     @{SQLiteDatabase:open} or @{SQLiteDatabase:close}
    -- @tparam[opt] string msg a detailed error description to append to the generic message
    -- @treturn string errMsg the error message
    -- @treturn number code the error code this method was called with (for convenience purposes)
    @decodeResult = (code = -1, msg = "") =>
        if #msg > 0
            if msgs.decodeResult.results[code]
                return "#{msgs.decodeResult.results[code]} (#{msg})"
            else return msgs.decodeResult.results.unknownDetail\format(code, msg)
        else return msgs.decodeResult.results[code] or msgs.decodeResult.results.unknown\format(code)

    --- Checks whether or not a given comprises one or more complete SQL statements.
    -- @static
    -- @tparam string sql a sequence of SQL statements
    -- @treturn[1] boolean true the provided string contains at least one complete SQL statement
    -- @treturn[2] boolean false no complete SQL statement was found in the provided string
    @isComplete = (sql) =>
        return lsqlite3.complete sql

    getInitializerType = (initializer) ->
        switch type initializer
            when "string" -- use schema file or directory path
                path, errMsg = fileOps.validateFullPath initializer
                return nil, errMsg unless path

                mode, errMsg = fileOps.attributes path, "mode"
                if mode == nil
                    return nil, msgs.getInitializerType.cantStatPath\format errMsg, @name, path, errMsg

                if mode == "directory"
                   return SQLiteDatabase.InitializerType.SchemaDirectory
                else if mode != "file"
                    return nil, msgs.getInitializerType.badPathMode\format path, mode

                return SQLiteDatabase.InitializerType.SchemaFile

            when "table" -- run a sequence of SQL statements
                return SQLiteDatabase.InitializerType.SqlSequence
            when "function" -- run a custom init function, passing in the db connection
                return SQLiteDatabase.InitializerType.Function
            when "nil"
                return SQLiteDatabase.InitializerType.None

    -- name must be a valid namespace
    new: (@name, @initializer, @maxRetries = 20, @logger = Logger fileBaseName: @@__name, fileSubName: @name) =>
        @path, errMsg = fileOps.getNamespacedPath dbPath, @name, ".sqlite"
        assert @path, errMsg

        res, errMsg = fileOps.mkdir @path, true
        assert res != nil, errMsg

        @initializerType, errMsg = getInitializerType @initializer
        assert @initializerType != nil, errMsg

        res, errMsg = @open @initializer
        assert res != nil, errMsg

    --- Closes the database connection.
    -- This is usually not required as the connection is closed automatically
    -- as soon as the @{SQLiteDatabase} object is garbage-collected.
    -- @treturn[1] boolean true the database connection was closed successfully
    -- @treturn[2] boolean false the database connection as already closed or not yet open
    -- @treturn[3] nil an error occured while trying to close the database connection
    -- @treturn[3] string an error message
    -- @treturn[3] number an accompanying SQLite error code
    close: =>
        return false unless @isOpen!
        code = @db\close!
        if code == @@Result.OK
            return true
        else return nil, @@decodeResult(code), code

    --- Creates a callback function that can be called by SQLite3 once for every row in a query.
    -- This is a straight wrapper around the LuaSQLite3 `db:create_function` interface.
    -- See http://lua.sqlite.org/index.cgi/doc/tip/doc/lsqlite3.wiki#db_create_function for details.
    createFunction: (name, argCnt, func) =>
        return @db\create_function name, argCnt, func

    --- Creates a collation callback for string comparisons or sorting purposes.
    -- This is a straight wrapper around the LuaSQLite3 `db:create_collation` interface.
    -- See http://lua.sqlite.org/index.cgi/doc/tip/doc/lsqlite3.wiki#db_create_collation for details.
    createCollation: (name, collator) =>
        return @db\create_collation name, collator

    --- Creates an aggregate callback function for performing an operation over all rows in a query.
    -- This is a straight wrapper around the LuaSQLite3 `db:create_aggregate` interface.
    -- See http://lua.sqlite.org/index.cgi/doc/tip/doc/lsqlite3.wiki#db_create_aggregate for details.
    createAggregate: (name, argCnt, rowCallback, finalCallback) =>
        return @db\create_aggregate name, argCnt, rowCallback, finalCallback

    --- Deletes the database file.
    -- @tparam string reSchedule Reschedule deletion on next script reload in case it failed due to the database file being locked by the Aegisub process
    drop: (reSchedule) =>
        res, errMsg = @close!
        if res == nil
            return nil, errMsg
        else return fileOps.remove @path, false, reSchedule



    --- Runs an SQL query against the database request and calls the supplied callback for every row returned.
    -- A row is represented as hash table of columen values keyed by column names
    -- If no callback is specified, all rows will be collected and returned in a list.
    -- @tparam string sql a sequence of sql statements
    -- @tparam[opt] function queryCallback(row, rowNumber) an optional callback to process every matching row
    -- @treturn[1] boolean true The query was executed successfully
    -- @treturn[1] {table, ...} An array of rows in case no queryCallback was specified
    -- @treturn[2] boolean false The query was aborted while it was running
    -- @treturn[2] string a message describing the abort reason
    -- @treturn[3] nil an error occured while trying to run the query
    -- @treturn[3] string an error message
    exec: (sql, queryCallback) =>
        rows = {n: 0} unless queryCallback

        queryCallback or= (row, r) ->
            rows[r], rows.n = row, r
            return true

        r = 0
        result = @db\exec sql, (udata, colCnt, values, colNames) ->
            row = {colNames[i], values[i] for i = 1, colCnt}
            r += 1
            return 0 if false != queryCallback row, r

        return switch result
            when @@Result.OK
                true, rows
            when @@Result.ABORT
                false, @@decodeResult(result, msgs.exec.errorDetail\format @lastStatement, @db\errmsg!), result
            else nil, @@decodeResult(result, msgs.exec.errorDetail\format @lastStatement, @db\errmsg!), result

    getRows: (sql) =>
        rows, r = {}, 0
        for row in @db\nrows sql -- TODO: figure out how error handling works in this
            r += 1
            rows[r] = row

        return rows, r


    rows: (sql) => @db\rows sql
    nrows: (sql) => @db\nrows sql
    urows: (sql) => @db\urows sql

    formatValue = (value) ->
        return switch type value
            when "string"
                "'#{value\gsub "'", "''"}'"  --"
            when "number"
                tostring value
            when "boolean"
                value and "0" or "1"
            when "nil"
                "NULL"
            else nil, msgs.insert.unsupportedType\format tblName, value, field, type value -- TODO: fix this

    formatCondition = (column, value) ->
        sqlValue, msg = formatValue value
        return nil, msg unless sqlValue
        return "%s=%s"\format column, sqlValue

    conditionalTemplate = "WHERE %s"
    operatorStatements = {
        [@@Operators.AND]: " AND "
        [@@Operators.OR]: " OR "
    }

    craftWhereStatement = (conditions, conditionOperator = @Operators.AND) =>
        return "" unless conditions
        fragments = [formatCondition col, val for col, val in pairs conditions]
        return if #fragments > 0
            conditionalTemplate\format table.concat fragments, operatorStatements[conditionOperator]
        else ""


    selectTemplate = "SELECT %s from '%s' %s"
    select: (tblName, fields, conditions, conditionOperator) =>
        fieldNames = fields == nil and "*" or table.concat fields, ","

        return @getRows selectTemplate\format fieldNames, tblName,
                        craftWhereStatement @@, conditions, conditionOperator


    selectFirst: (...) =>
        rows, r = @select ...
        return nil, r if rows == nil -- TODO: make this happen
        return rows[1] or false


    insertTemplate = "INSERT%s INTO '%s' (%s) VALUES (%s);"
    insert: (tblName, tbl, fields, altAction) =>
        fields or= [k for k, v in pairs tbl]
        values, v = {}, 1

        for field in *fields
            value, msg = formatValue tbl[field]
            return nil, msg unless value
            values[v] = value
            v += 1

        altClause = altAction and " OR #{altAction}" or ""
        query = insertTemplate\format altClause, tblName, table.concat(fields, ","),
                                      table.concat values, ","
        return @exec query

    updateTemplate = "UPDATE '%s' SET %s %s"
    update: (tblName, tbl, fields, conditions, conditionOperator) =>
        fields or= [k for k, v in pairs tbl]

        keyValuePairs = ["#{field}=#{formatValue tbl[field]}" for field in *fields]
        query = updateTemplate\format tblName, table.concat(keyValuePairs, ","),
                craftWhereStatement @@, conditions, conditionOperator
        return @exec query


    deleteTemplate = "DELETE FROM '%s' %s"
    delete: (tblName, conditions, conditionOperator = @@Operators.AND) =>
        @exec deleteTemplate\format tblName, craftWhereStatement @@, conditions, conditionOperator

    init: (initializer = @initializer) =>
        initializerType = getInitializerType @initializer

        local data
        switch type initializerType
            when @@InitializerType.SchemaFile
                data, errMsg = fileOps.readFile initializer
                unless data
                    return nil, errMsg

            when @@InitializerType.SchemaDirectory
                data, errMsg = fileOps.readFile "#{initializer}/base.sql"
                unless data
                    return nil, errMsg

            when @@InitializerType.SqlSequence
                data = table.concat initializer, "\n"
            when @@InitializerType.Function
                return initializer @db
            when @@InitializerType.None
                return nil, msgs.init.noInitializer

        res, errMsg, code = @exec data
        if res
            return true
        else return nil, msgs.init.execFailed\format(code, errMsg), code

    getSchemaVersion: =>
        return nil, msgs.common.notOpen unless @isOpen!

        res, rows, code = @exec "PRAGMA user_version"
        return nil, msgs.common.execFailed\format(code, rows), code unless res

        return tonumber rows[1].user_version

    getSchemaUpgradeCandidates: (schemaPath = @initializerType == @@InitializerType.SchemaDirectory and @initializer or nil) =>
        if schemaPath == nil
            return false

        if "directory" != fileOps.attributes schemaPath, "mode"
            return nil, msgs.getSchemaUpgrades.noSchemaDirectory, schemaPath

        upgrades = {}
        for fileName in lfs.dir schemaPath
            fromVer, toVer = fileName\match "(%d+)%-(%d+).sql"
            if not fromVer or not toVer
                @logger\warn msgs.getSchemaUpgrades.unrecognizedFile, fileName unless fileName == "base.sql"
                continue

            filePath = "#{schemaPath}/#{fileName}"
            sql, err = fileOps.readFile filePath
            return nil, msgs.getSchemaUpgrades.failedReadFile\format filePath, err unless sql

            table.insert upgrades, {
                fromVer: tonumber fromVer,
                toVer: tonumber toVer,
                :sql
            }

        return upgrades

    upgradeSchema: (targetVersion, candidates) =>
        if candidates == nil or "string" == type candidates
            candidates, errMsg = @getSchemaUpgradeCandidates candidates
            unless candidates
                return nil, msgs.upgradeSchema.noSchemaDirectory\format errMsg and "(#{errMsg})" or ""

        return nil, msgs.common.notOpen unless @isOpen!
        currentVersion = @getSchemaVersion!
        @logger\trace msgs.upgradeSchema.currentVersion, @name, currentVersion

        trimCandidates = (minVer, maxVer = math.huge) ->
            candidates = [cnd for cnd in *candidates when cnd.fromVer >= minVer and cnd.toVer <= maxVer]

        trimCandidates currentVersion, targetVersion
        table.sort candidates, (a, b) -> a.fromVer < b.fromVer or a.toVer > b.toVer

        upgrades, upgradeVersion = {}, currentVersion
        while #candidates > 0 do with candidates[1]
            if .fromVer > upgradeVersion
                @logger\warn msgs.upgradeSchema.noPathToNewerVersion, @name, .toVer, .fromVer, upgradeVersion
                break

            table.insert upgrades, candidates[1]
            upgradeVersion = .toVer
            trimCandidates upgradeVersion

        if targetVersion and targetVersion > upgradeVersion
            return nil, msgs.upgradeSchema.targetNotReached\format targetVersion, currentVersion, upgradeVersion

        -- TODO: create a db backup and roll back if things go south here
        for upgrade in *upgrades
            res, errMsg, code = @exec upgrade.sql
            if res
                -- TODO: check whether or not user_version has actually been incremented as advertised because developers can't be trusted with anything
                return true
            else return nil, msgs.upgradeSchema.upgradeFailed\format(upgrade.fromVer, upgrade.toVer, code, errMsg), code

        return upgradeVersion, upgrades

    exists: =>
        -- check if the db path is accessible and points to a file
        mode, errMsg = fileOps.attributes @path, "mode"
        switch mode
            when nil
                return nil, msgs.exists.cantStatPath\format errMsg, @name, @path, errMsg
            when false
                return false
            when "file"
                return true
            else return nil, msgs.exists.notAFile\format @name, @path, mode


    isOpen: =>
        return @db and @db\isopen!

    busyHandler = (retries) =>
        if retries <= @maxRetries
            @logger\trace msgs.busyHandler.retry\format @name, retries, @maxRetries
            PreciseTimer.sleep 50
            return true
        else
            @logger\trace msgs.busyHandler.abort\format @name, @maxRetries
            return false

    traceCallback = (statement) =>
        @lastStatement = statement
        @logger\trace msgs.traceCallback.runningStatement\format statement, @name

    open: (initializer = @initializer) =>
        return false if @isOpen!

        dbExists, errMsg = @exists!
        return nil, errMsg if dbExists == nil

        -- open the database connection, will create db file automatically
        @db, errCode, errMsg = lsqlite3.open @path
        return nil, errMsg, errCode unless @db

        initializerType, errMsg = getInitializerType initializer
        return nil, errMsg unless initializerType

        -- initialize database on db file creation or when schema version is zero
        if initializerType != @@InitializerType.None and (not dbExists or 0 == @getSchemaVersion!)
            res, errMsg = @init initializer
            unless res
                @drop! -- delete the db if init failed, so we can try again later
                return nil, msgs.open.initFailed\format errMsg

        -- register callbacks
        @db\busy_handler busyHandler, @
        @db\trace traceCallback, @

        return true

    prepare: (sql) =>
        return @db\prepare sql

    rows: (sql) =>
        rows, errMsg = @exec sql
        assert rows, errMsg
        r = 0
        return ->
            r += 1
            return rows[r], r