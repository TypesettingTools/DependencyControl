return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Number = createASSClass("Number", ASS.Tag.Base, {"value"}, {"number"}, {base=10, precision=3, scale=1})

    function Number:new(args)
        self:readProps(args)
        self.value = self:getArgs(args,0,true)
        self:checkValue()
        if self.__tag.mod then self.value = self.value % self.__tag.mod end
        return self
    end

    function Number:checkValue()
        self:typeCheck(self.value)
        if self.__tag.range then
            math.inRange(self.value, self.__tag.range[1], self.__tag.range[2], self.typeName, self.integer)
        else
            if self.__tag.positive then assertEx(self.value>=0, "%s must be a positive number, got %d.", self.typeName, self.value) end
            if self.__tag.integer then math.isInt(self.value, self.typeName) end
        end
    end

    function Number:getTagParams(coerce, precision)
        precision = precision or self.__tag.precision
        local val = self.value
        if coerce then
            self:coerceNumber(val,0)
        else
            assertEx(precision <= self.__tag.precision, "output wih precision %d is not supported for %s (maximum: %d).",
                     precision, self.typeName, self.__tag.precision)
            self:checkValue()
        end
        if self.__tag.mod then val = val % self.__tag.mod end
        return math.round(val,self.__tag.precision)
    end

    function Number.cmp(a, mode, b)
        local modes = {
            ["<"] = function() return a<b end,
            [">"] = function() return a>b end,
            ["<="] = function() return a<=b end,
            [">="] = function() return a>=b end
        }

        local errStr = "operand %d must be a number or an object of (or based on) the %s class, got a %s."
        if type(a)=="table" and (a.instanceOf[Number] or a.baseClasses[Number]) then
            a = a:get()
        else assertEx(type(a)=="number", errStr, 1, Number.typeName, ASS:instanceOf(a) and a.typeName or type(a)) end

        if type(b)=="table" and (b.instanceOf[Number] or b.baseClasses[Number]) then
            b = b:get()
        else assertEx(type(b)=="number", errStr, 1, Number.typeName, ASS:instanceOf(b) and b.typeName or type(b)) end

        return modes[mode]()
    end

    function Number.__lt(a,b) return Number.cmp(a, "<", b) end
    function Number.__le(a,b) return Number.cmp(a, "<=", b) end
    function Number.__add(a,b) return type(a)=="table" and a:copy():add(b) or b:copy():add(a) end
    function Number.__sub(a,b) return type(a)=="table" and a:copy():sub(b) or Number{a}:sub(b) end
    function Number.__mul(a,b) return type(a)=="table" and a:copy():mul(b) or b:copy():mul(a) end
    function Number.__div(a,b) return type(a)=="table" and a:copy():div(b) or Number{a}:div(b) end
    function Number.__mod(a,b) return type(a)=="table" and a:copy():mod(b) or Number{a}:mod(b) end
    function Number.__pow(a,b) return type(a)=="table" and a:copy():pow(b) or Number{a}:pow(b) end

    return Number
end