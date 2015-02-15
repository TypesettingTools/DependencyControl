return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Toggle = createASSClass("Tag.Toggle", ASS.Tag.Base, {"value"}, {"boolean"})
    function Toggle:new(args)
        self.value = self:getArgs(args,false,true)
        self:readProps(args)
        self:typeCheck(self.value)
        return self
    end

    function Toggle:toggle(state)
        assertEx(type(state)=="boolean" or type(state)=="nil",
                 "argument #1 (state) must be true, false or nil, got a %s.", type(state))
        self.value = state==nil and not self.value or state
        return self.value
    end

    function Toggle:getTagParams(coerce)
        if not coerce then self:typeCheck(self.value) end
        return self.value and 1 or 0
    end
    return Toggle
end