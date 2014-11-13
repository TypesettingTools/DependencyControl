local util = require("aegisub.util")
local unicode = require("aegisub.unicode")

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
    local outStr=fmtStr:gsub("(%%[%+%- 0]*%d*.?%d*[hlLzjtI]*)([aABcedEfFgGcnNopiuAsuxX])", function(opts,type_)
        i=i+1
        if type_=="N" then
            return tonumber(string.format(opts.."f", args[i])) 
        elseif type_=="B" then
            return args[i] and 1 or 0
        else
            return string.format(opts..type_, args[i])
        end
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

-- difference, union and intersection for hashtables (comparison is done on key-val pair)
table.diff = function(left, right, preferLeft)
    local diff={}
    if preferLeft then
        left, right = right, left
    end
    
    for key,val in pairs(right) do
        if val ~= left[key] then
            diff[key] = val
        end
    end
    return diff
end

table.union = function(left, right, preferLeft)
    if preferLeft then
        left, right = right, left
    end
    -- write entries that differ between left<->right from right
    local union = table.diff(left, right)

    -- write left entries missing from right into diff
    for key,val in pairs(left) do
        if not union[key] then
            union[key] = val
        end
    end
end

table.intersect = function(...)
    local tbls = {...}
    local intersection, j = tbls[1], 0
    for i=2,#tbls do
        for key,val in pairs(intersection) do
            intersection[key] = val==tbls[i][key] and val or nil
            j=j+1
        end
    end
    return intersection, j
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

table._insert = table.insert
table.insert = function(tbl,...)
    table._insert(tbl,...)
    return tbl
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

table.joinInto = function(arr, ...)
    local arrN, args = #arr, {...}
    for i=1,#args do
        for j=1,#args[i] do
            arrN = arrN + 1
            arr[arrN] = args[i][j]
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

table.pluck = function(tbl, prop)
    local plucked = {}
    for i=1,#tbl do
        plucked[i] = tbl[i][prop]
    end
    return plucked
end

table.process = function(tbl1,tbl2,callback)
    local tblProc = {}
    for key,val in pairs(tbl1) do
        tbl1[key] = callback(val,tbl2[key],key,tbl1,tbl2)
    end
    return tblProc
end

table.reverseArray = function(tbl)
    local length, rTbl = #tbl, {}
    for i,val in ipairs(tbl) do
        rTbl[length-i+1] = val
    end
    return rTbl
end

table.trimArray = function(tbl)
    local trimmed = {}
    for _,val in pairs(tbl) do
        if val~=nil then table.insert(trimmed,val) end
    end
    return trimmed
end

table.select = function(tbl,keys)
    local selected = {}
    for i=1,#keys do
        selected[keys[i]] = tbl[keys[i]]
    end
    return selected
end

table.sliceArray = function(tbl, istart, iend)
    istart, iend = istart or 1, iend or #tbl
    local arr={}
    for i = istart, iend do 
        arr[1+i-istart] = tbl[i] 
    end
    return arr
end

table._sort = table.sort
table.sort = function(tbl,...)
    table._sort(tbl,...)
    return tbl
end

table.values = function(tbl)
    local vals, valsN = {}, 0
    for _,val in pairs(tbl) do
        valsN = valsN + 1
        vals[valsN] = val
    end
    return vals
end

unicode.reverse = function(s)
    return table.concat(table.reverseArray(unicode.toCharTable(s)))
end

unicode.sub = function(s, i, j)
    local uniChars = unicode.toCharTable(s)
    local charCnt = #uniChars

    i = (not i and 1) or (i<0 and math.max(charCnt+i+1,1)) or util.clamp(i,1,charCnt)
    j = (not j and charCnt) or (j<0 and math.max(charCnt+j+1,1)) or util.clamp(j,1,charCnt)
    return table.concat(uniChars, "", i, j)
end

unicode.toCharTable = function(s)
    local charNum, charStart, uniChars = 1, 1, {}
    while charStart <= #s do
        local charEnd = charStart + unicode.charwidth(s:sub(charStart,charStart)) - 1
        uniChars[charNum] = s:sub(charStart, charEnd)
        charStart, charNum = charEnd+1, charNum+1
    end
    return uniChars
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
        return h>0 and h or h+360, s, v/255
    end
end

util.uuid = function()
    -- https://gist.github.com/jrus/3197011
    math.randomseed(os.time())
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
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
        if type(arg)=="table" then
            for _, val in ipairs(arg) do
                arrN = arrN + 1
                arr[arrN] = val
            end
        else 
            arrN = arrN + 1
            arr[arrN] = arg
        end
    end
    return unpack(arr)
end

function default(var, val)
    return type(var)=="nil" and val or var
end