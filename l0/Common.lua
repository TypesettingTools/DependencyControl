local util = require("aegisub.util")

math.isInt = function(num)
    return type(num) == "number" and math.floor(num) == num
end

math.toStrings = function(...)
    local strings, args = {}, {...}
    for i=1, #args do
        strings[i] = tostring(args[i])
    end
    return unpack(strings)
end

math.round = function(num,idp)
  local mult = 10^(idp or 0)
  return math.floor(num * mult + 0.5) / mult
end

string.formatFancy = function(fmtStr,...)
    local i, args = 0, {...}
    local outStr=fmtStr:gsub("(%%[%+%- 0]*%d*.?%d*[hlLzjtI]*)([aAcedEfFgGcnNopiuAsuxX])", function(opts,type_)
        i=i+1
        return type_=="N" and tonumber(string.format(opts.."f", args[i])) or string.format(opts..type_, args[i])
    end)
    return outStr
end

string.patternEscape = function(str)
    return str:gsub("([%%%(%)%[%]%.%*%-%+%?%$%^])","%%%1")
end

function string:split(sep)
    local sep, fields = sep or "", {}
    self:gsub(string.format("([^%s]+)", sep), function(field) 
        fields[#fields+1] = field
    end)
    return fields
end

string.toNumbers = function(base, ...)
    local numbers, args = {}, {...}
    for i=1, #args do
        numbers[i] = tonumber(args[i], base)
    end
    return unpack(numbers)
end

table.length = function(tbl) -- currently unused
    local n = 0
    for _, _ in pairs(tbl) do n = n + 1 end
    return n
end

table.isArray = function(tbl)
    return table.length(tbl)==#tbl
end

table.filter = function(tbl, callback)
    local fltTbl = {}
    for key, val in pairs(tbl) do
        if callback(val, key, tbl) then
            fltTbl[key] = val
        end
    end
    return fltTbl
end

table.find = function(tbl,findVal)
    for key,val in pairs(tbl) do
        if val==findVal then return key end
    end
end

table.join = function(...)
    local arr, arrN = {}, 0
    for _, arg in ipairs({...}) do
        for _, val in ipairs(arg) do
            arrN = arrN + 1
            arr[arrN] = val
        end
    end
    return arr
end

table.keys = function(tbl)
    local keys, keysN = {}, 0
    for key,_ in pairs(tbl) do
        keysN = keysN + 1
        keys[keysN] = key
    end
    return keys
end

table.merge = function(...)
    local tbl = {}
    for _, arg in ipairs({...}) do
        for key, val in pairs(arg) do tbl[key] = val end
    end
    return tbl
end

table.sliceArray = function(tbl, istart, iend)
    local arr={}
    for i = istart, iend do arr[1+i-istart] = tbl[i] end
    return arr
end

util.RGB_to_HSV = function(r,g,b)
    r,g,b = util.clamp(r,0,255), util.clamp(g,0,255), util.clamp(b,0,255)
    local v = math.max(r, g, b)
    local delta = v - math.min(r, g, b)
    if delta==0 then 
        return 0,0,0
    else         
        local s,c = delta/v, (r==v and g-b) or (g==v and b-r+2) or (r-g+4)
        local h = 60*c/delta
        return h>0 and h or h+360, s, v
    end
end

util.getScriptInfo = function(sub)
    local infoBlockFound, scriptInfo = false, {}
    for i=1,#sub do
        if sub[i].class=="info" then
            infoBlockFound = true
            scriptInfo[sub[i].key] = sub[i].value
        elseif infoBlockFound then break end
    end
    return scriptInfo
end

returnAll = function(...) -- blame lua
    local arr, arrN = {}, 0
    for _, arg in ipairs({...}) do
        for _, val in ipairs(arg) do
            arrN = arrN + 1
            arr[arrN] = val
        end
    end
    return unpack(arr)
end

