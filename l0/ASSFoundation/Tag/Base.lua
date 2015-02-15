return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local TagBase = createASSClass("TagBase", ASS.Base)

    function TagBase:commonOp(method, callback, default, ...)
        local args = {self:getArgs({...}, default, false)}
        local j, valNames = 1, self.__meta__.order
        for i=1,#valNames do
            if ASS:instanceOf(self[valNames[i]]) then
                local subCnt = #self[valNames[i]].__meta__.order
                local subArgs = unpack(table.sliceArray(args,j,j+subCnt-1))
                self[valNames[i]][method](self[valNames[i]],subArgs)
                j=j+subCnt
            else
                self[valNames[i]]=callback(self[valNames[i]],args[j])
                j = self[valNames[i]], j+1
            end
        end
        return self
    end

    function TagBase:add(...)
        return self:commonOp("add", function(a,b) return a+b end, 0, ...)
    end

    function TagBase:sub(...)
        return self:commonOp("sub", function(a,b) return a-b end, 0, ...)
    end

    function TagBase:mul(...)
        return self:commonOp("mul", function(a,b) return a*b end, 1, ...)
    end

    function TagBase:div(...)
        return self:commonOp("div", function(a,b) return a/b end, 1, ...)
    end

    function TagBase:pow(...)
        return self:commonOp("pow", function(a,b) return a^b end, 1, ...)
    end

    function TagBase:mod(...)
        return self:commonOp("mod", function(a,b) return a%b end, 1, ...)
    end

    function TagBase:set(...)
        return self:commonOp("set", function(a,b) return b end, nil, ...)
    end

    function TagBase:round(...)
        return self:commonOp("round", function(a,b) return math.round(a,b) end, nil, ...)
    end

    function TagBase:ceil()
        return self:commonOp("ceil", function(a) return math.ceil(a) end, nil)
    end

    function TagBase:floor()
        return self:commonOp("floor", function(a) return math.floor(a) end, nil)
    end

    function TagBase:modify(callback, ...)
        return self:set(callback(self:get(...)))
    end

    function TagBase:readProps(args)
        if type(args[1])=="table" and args[1].instanceOf and args[1].instanceOf[self.class] then
            for k, v in pairs(args[1].__tag) do
                self.__tag[k] = v
            end
        elseif args.tagProps then
            for key, val in pairs(args.tagProps) do
                self.__tag[key] = val
            end
        end
    end

    function TagBase:getTagString(caller, coerce)
        return (self.disabled or caller and caller.toRemove and caller.toRemove[self]) and ""
               or ASS:formatTag(self, self:getTagParams(coerce))
    end

    function TagBase:equal(ASSTag)  -- checks equalness only of the relevant properties
        local vals2
        if type(ASSTag)~="table" then
            vals2 = {ASSTag}
        elseif not ASSTag.instanceOf then
            vals2 = ASSTag
        elseif ASSTag.class == self.class and self.__tag.name==ASSTag.__tag.name then
            vals2 = {ASSTag:get()}
        else return false end

        local vals1 = {self:get()}
        if #vals1~=#vals2 then return false end

        for i=1,#vals1 do
            if type(vals1[i])=="table" and #table.intersectInto(vals1[i],vals2[i]) ~= #vals2[i] then
                return false
            elseif type(vals1[i])~="table" and vals1[i]~=vals2[i] then return false end
        end

        return true
    end
    return TagBase
end