PreciseTimer = require "PreciseTimer.PreciseTimer"
ffi = require "ffi"

class Logger
    levels = {"fatal", "error", "warning", "hint", "debug", "trace"}
    defaultLevel: 2
    maxToFileLevel: 4
    fileBaseName: script_name
    prefix: ""
    toFile: false
    toWindow: true
    Timer, seeded = PreciseTimer!, false

    new: (args) =>
        {defaultLevel: @defaultLevel, maxToFileLevel: @maxToFileLevel,
         fileBaseName: @fileBaseName, prefix: @prefix, toFile: @toFile, toWindow: @toWindow} = args

        -- scripts are loaded simultaneously, so we need to avoid seeding the rng with the same time
        unless seeded
            Timer\sleep 10 for i=1,50
            math.randomseed(Timer\timeElapsed!*1000000)
            math.random, math.random, math.random
            seeded = true

         -- TODO: autodelete old logs

        @fileName = aegisub.decode_path "?user/log/#{os.date '%Y-%m-%d-%H-%M-%S'}-#{'%04x'\format math.random 0, 16^4-1}_#{@fileBaseName}.log"

    logEx: (level = @defaultLevel, msg = "", insertLineFeed = true, prefix = @prefix,  ...) =>
        return false if msg == ""
        lineFeed = insertLineFeed and "\n" or ""

        show = aegisub.log and @toWindow
        if @toFile and level <= @maxToFileLevel
            @handle = io.open(@fileName, "a") unless @handle
            linePre = @lastHadLineFeed and "[#{levels[level]\upper!}] #{os.date '%H:%M:%S'} #{show and '+' or '•'}" or ""
            line = table.concat({linePre, prefix, msg, lineFeed})\format ...
            @handle\write(line)\flush!

        if level<2
            error "Error: #{prefix}#{msg}"\format ...
        elseif show
            aegisub.log level, table.concat({prefix, msg, lineFeed})\format ...

        @lastHadLineFeed = insertLineFeed
        return true

    log: (level, msg, ...) =>
        return false unless level or msg

        if "number" != type level
            return @logEx @defaultLevel, level, true, msg, nil, ...
        else return @logEx level, msg, true, nil, ...

    fatal: (...) => @log 0, ...
    error: (...) => @log 1, ...
    warn: (...) => @log 2, ...
    hint: (...) => @log 3, ...
    debug: (...) => @log 4, ...
    trace: (...) => @log 5, ...

    -- taken from https://github.com/TypesettingCartel/Aegisub-Motion/blob/master/src/Log.moon
    dump: ( item, ignore, level = @defaultLevel ) ->
        if "table" != type item
            return @log level, item

        count, tablecount = 1, 1

        result = { "{ @#{tablecount}" }
        seen   = { [item]: tablecount }
        recurse = ( item, space ) ->
            for key, value in pairs item
                unless key == ignore
                    if "number" == type key
                        key = "##{key}"
                    if "table" == type value
                        unless seen[value]
                            tablecount += 1
                            seen[value] = tablecount
                            count += 1
                            result[count] = space .. "#{key}: { @#{tablecount}"
                            recurse value, space .. "    "
                            count += 1
                            result[count] = space .. "}"
                        else
                            count += 1
                            result[count] = space .. "#{key}: @#{seen[value]}"

                    else
                        if "string" == type value
                            value = ("%q")\format value

                        count += 1
                        result[count] = space .. "#{key}: #{value}"

        recurse item, "    "
        result[count+1] = "}"

        @log level, table.concat(result, "\n")

    windowError: ( errorMessage ) ->
        aegisub.dialog.display { { class: "label", label: errorMessage } }, { "&Close" }, { cancel: "&Close" }
        aegisub.cancel!
