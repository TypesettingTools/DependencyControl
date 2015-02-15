return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Base = createASSClass("Base")

    function Base:checkType(type_, ...) --TODO: get rid of
        local vals = table.pack(...)
        for i=1,vals.n do
            result = (type_=="integer" and math.isInt(vals[i])) or type(vals[i])==type_
            assertEx(result, "%s must be a %s, got %s.", self.typeName, type_, type(vals[i]))
        end
    end

    function Base:checkPositive(...)
        self:checkType("number", ...)
        local vals = table.pack(...)
        for i=1,vals.n do
            assertEx(vals[i] >= 0, "%s tagProps do not permit numbers < 0, got %d.", self.typeName, vals[i])
        end
    end

    function Base:coerceNumber(num, default)
        num = tonumber(num)
        if not num then num=default or 0 end
        if self.__tag.positive then num=math.max(num,0) end
        if self.__tag.range then num=util.clamp(num,self.__tag.range[1], self.__tag.range[2]) end
        return num
    end

    function Base:coerce(value, type_)
        assertEx(type(value)~="table", "can't cast a table to a %s.", tostring(type_))
        local tagProps = self.__tag or self.__defProps
        if type(value) == type_ then
            return value
        elseif type_ == "number" then
            if type(value)=="boolean" then return value and 1 or 0
            else
                cval = tonumber(value, tagProps.base or 10)
                assertEx(cval, "failed coercing value '%s' of type %s to a number on creation of %s object.",
                         tostring(value), type(value), self.typeName)
            return cval*(tagProps.scale or 1) end
        elseif type_ == "string" then
            return tostring(value)
        elseif type_ == "boolean" then
            return value~=0 and value~="0" and value~=false
        elseif type_ == "table" then
            return {value}
        end
    end

    function Base:getArgs(args, defaults, coerce, extraValidClasses)
        -- TODO: make getArgs automatically create objects
        assertEx(type(args)=="table", "first argument to getArgs must be a table of arguments, got a %s.", type(args))
        local propTypes, propNames = self.__meta__.types, self.__meta__.order
        if not args then args={}
        -- process "raw" property that holds all tag parameters when parsed from a string
        elseif type(args.raw)=="table" then args=args.raw
        elseif args.raw then args={args.raw}
        -- check if first and only arg is a compatible ASSClass and dump into args
        elseif #args == 1 and type(args[1]) == "table" and args[1].instanceOf then
            local selfClasses = extraValidClasses and table.merge(self.compatible, extraValidClasses) or self.compatible
            local _, clsMatchCnt = table.intersect(selfClasses, args[1].compatible)

            if clsMatchCnt>0 then

                if args.deepCopy then
                    args = {args[1]:get()}
                else
                    -- This is a fast path for compatible objects
                    -- TODO: check for issues caused by this change
                    local obj = args[1]
                    for i=1,#self.__meta__.order do
                        args[i] = obj[self.__meta__.order[i]]
                    end
                    return unpack(args)
                end
            else assertEx(type(propTypes[1]) == "table" and propTypes[1].instanceOf,
                          "object of class %s does not accept instances of class %s as argument.",
                          self.typeName, args[1].typeName
                 )
            end
        end

        -- TODO: check if we can get rid of either the index into the default table or the output table
        local defIdx, j, outArgs, o = 1, 1, {}, 1
        for i=1,#propNames do
            if ASS:instanceOf(propTypes[i]) then
                local argSlice, a, rawArgCnt, propRawArgCnt, defSlice = {}, 1, 0, propTypes[i].__meta__.rawArgCnt
                while rawArgCnt<propRawArgCnt do
                    argSlice[a], a = args[j], a+1
                    rawArgCnt = rawArgCnt + (type(args[j])=="table" and args[j].class and args[j].__meta__.rawArgCnt or 1)
                    j=j+1
                end

                if type(defaults) == "table" then
                    defSlice = table.sliceArray(defaults, defIdx, defIdx+propRawArgCnt-1)
                    defIdx = defIdx + propRawArgCnt
                end

                outArgs, o = table.joinInto(outArgs, {propTypes[i]:getArgs(argSlice, defSlice or defaults, coerce)})
            else
                if args[j]==nil then -- write defaults
                    outArgs[o] = type(defaults)=="table" and defaults[defIdx] or defaults
                elseif type(args[j])=="table" and args[j].class then
                    assertEx(args[j].__meta__.rawArgCnt==1, "type mismatch in argument #%d (%s). Expected a %s or a compatible object, but got a %s.",
                             i, propNames[i], propTypes[i], args[j].typeName)
                    outArgs[o] = args[j]:get()
                elseif coerce and type(args[j])~=propTypes[i] then
                    outArgs[o] = self:coerce(args[j], propTypes[i])
                else outArgs[o] = args[j] end
                j, defIdx = j+1, defIdx+1
            end
            o=o+1
        end
        return unpack(outArgs)
    end

    function Base:copy() --TODO: optimize
        local newObj, meta = {}, getmetatable(self)
        setmetatable(newObj, meta)
        for key,val in pairs(self) do
            if key=="__tag" or not meta or (meta and table.find(self.__meta__.order,key)) then   -- only deep copy registered members of the object
                if ASS:instanceOf(val) then
                    newObj[key] = val:copy()
                elseif type(val)=="table" then
                    newObj[key]=Base.copy(val)
                else newObj[key]=val end
            else newObj[key]=val end
        end
        return newObj
    end

    function Base:typeCheck(...)
        local valTypes, valNames, j, args = self.__meta__.types, self.__meta__.order, 1, {...}
        for i=1,#valNames do
            if ASS:instanceOf(valTypes[i]) then
                if ASS:instanceOf(args[j]) then   -- argument and expected type are both ASSObjects, defer type checking to object
                    self[valNames[i]]:typeCheck(args[j])
                else  -- collect expected number of arguments for target ASSObject
                    local subCnt = #valTypes[i].__meta__.order
                    valTypes[i]:typeCheck(unpack(table.sliceArray(args,j,j+subCnt-1)))
                    j=j+subCnt-1
                end
            else
                assertEx(type(args[j])==valTypes[i] or args[j]==nil or valTypes[i]=="nil",
                       "bad type for argument #%d (%s). Expected %s, got %s.", i, valNames[i], valTypes[i], type(args[j]))
            end
            j=j+1
        end
        return unpack(args)
    end

    function Base:get()
        local vals, names, valCnt = {}, self.__meta__.order, 1
        for i=1,#names do
            if ASS:instanceOf(self[names[i]]) then
                for j,subVal in pairs({self[names[i]]:get()}) do
                    vals[valCnt], valCnt = subVal, valCnt+1
                end
            else
                vals[valCnt], valCnt = self[names[i]], valCnt+1
            end
        end
        return unpack(vals)
    end

    return Base
end