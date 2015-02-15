return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local String = createASSClass("String", ASS.Base, {"value"}, {"string"})
    function String:new(args)
        self.value = self:getArgs(args,"",true)
        self:readProps(args)
        return self
    end

    function String:append(str)
        return self:commonOp("append", function(val,str)
            return val..str
        end, "", str)
    end

    function String:prepend(str)
        return self:commonOp("prepend", function(val,str)
            return str..val
        end, "", str)
    end

    function String:replace(pattern, rep, plainMatch, useRegex)
        if plainMatch then
            useRegex, pattern = false, target:patternEscape()
        end
        self.value = useRegex and re.sub(self.value, pattern, rep) or self.value:gsub(pattern, rep)
        return self
    end

    function String:reverse()
        self.value = unicode.reverse(self.value)
        return self
    end

    return String
end