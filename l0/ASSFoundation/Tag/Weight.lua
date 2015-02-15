return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Weight = createASSClass("Tag.Weight", ASS.Tag.Base, {"weightClass","bold"}, {ASS.Number, ASS.Tag.Toggle})
    function Weight:new(args)
        local weight, bold = self:getArgs(args,{0,false},true)
                        -- also support signature Weight{bold} without weight
        if args.raw or (#args==1 and not ASS:instanceOf(args[1], Weight)) then
            weight, bold = weight~=1 and weight or 0, weight==1
        end
        self:readProps(args)
        self.bold = ASS.Tag.Toggle{bold}
        self.weightClass = ASS.Number{weight, tagProps={positive=true, precision=0}}
        return self
    end

    function Weight:getTagParams(coerce)
        if self.weightClass.value >0 then
            return self.weightClass:getTagParams(coerce)
        else
            return self.bold:getTagParams(coerce)
        end
    end

    function Weight:setBold(state)
        self.bold:set(type(state)=="nil" and true or state)
        self.weightClass.value = 0
    end

    function Weight:toggle()
        self.bold:toggle()
    end

    function Weight:setWeight(weightClass)
        self.bold:set(false)
        self.weightClass:set(weightClass or 400)
    end

    return Weight
end