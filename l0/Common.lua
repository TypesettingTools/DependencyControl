math.isInt = function(val)
    return type(val) == "number" and val%1==0
end

math.toStrings = function(...)
    strings={}
    for _,num in ipairs(table.pack(...)) do
        strings[#strings+1] = tostring(num)
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
        if type_=="N" then
            return string.format(opts.."f",args[i]):gsub("%.(%d-)0+$","%.%1"):gsub("%.$",""), ""
        else return string.format(opts..type_,args[i]), "" end
    end)
    return outStr
end

string.patternEscape = function(str)
    return str:gsub("([%%%(%)%[%]%.%*%-%+%?%$%^])","%%%1")
end

string.toNumbers = function(base, ...)
    numbers={}
    for _,string in ipairs(table.pack(...)) do
        numbers[#numbers+1] = tonumber(string, base)
    end
    return unpack(numbers)
end

table.length = function(tbl) -- currently unused
    local res=0
    for _,_ in pairs(tbl) do res=res+1 end
    return res
end

table.isArray = function(tbl)
    local i = 0
    for _,_ in ipairs(tbl) do i=i+1 end
    return i==#tbl
end

table.filter = function(tbl, callback)
    local fltTbl = {}
    local tblIsArr = table.isArray(table)
    for key, value in pairs(tbl) do
        if callback(value,key,tbl) then 
            if tblIsArr then fltTbl[#fltTbl+1] = value
            else fltTbl[key] = value end
        end
    end
    return fltTbl
end

table.find = function(tbl,findVal)
    for key,val in pairs(tbl) do
        if val==findVal then return key end
    end
    return nil
end

table.join = function(tbl1,tbl2)
    local tbl = {}
    for _,val in ipairs(tbl1) do table.insert(tbl,val) end
    for _,val in ipairs(tbl2) do table.insert(tbl,val) end
    return tbl
end

table.keys = function(tbl)
    local keys={}
    for key,_ in pairs(tbl) do
        table.insert(keys, key)
    end
    return keys
end

table.merge = function(tbl1,tbl2)
    local tbl = {}
    for key,val in pairs(tbl1) do tbl[key] = val end
    for key,val in pairs(tbl2) do tbl[key] = val end
    return tbl
end

table.sliceArray = function(tbl, istart, iend)
    local arr={}
    for i=istart,iend,1 do arr[#arr+1]=tbl[i] end
    return arr
end

util.RGB_to_HSV = function(r,g,b)
    r,g,b = util.clamp(r,0,255), util.clamp(g,0,255), util.clamp(b,0,255)
    local min, max = math.min(r,g,b), math.max(r,g,b)
    local v, delta = max, max-min
    if delta==0 then 
        return 0,0,0
    else         
        local s,c = delta/max, (r==max and g-b) or (g==max and b-r+2) or (r-g+4)
        local h = 60*c/delta
        return h>0 and h or h+360, s, v
    end
end


returnAll = function(...) -- blame lua
    local arr={}
    for _,results in ipairs({...}) do
        for _,result in ipairs(results) do
            arr[#arr+1] = result
        end
    end
    return unpack(arr)
end