return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Color = createASSClass("Tag.Color", ASS.Tag.Base, {"r","g","b"}, {ASS.Hex, ASS.Hex, ASS.Hex})
    function Color:new(args)
        local b,g,r = self:getArgs(args,nil,true)
        self:readProps(args)
        self.r, self.g, self.b = ASS.Hex{r}, ASS.Hex{g}, ASS.Hex{b}
        return self
    end

    function Color:addHSV(h,s,v)
        local ho,so,vo = util.RGB_to_HSV(self.r:get(),self.g:get(),self.b:get())
        local r,g,b = util.HSV_to_RGB(ho+h,util.clamp(so+s,0,1),util.clamp(vo+v,0,1))
        return self:set(r,g,b)
    end

    function Color:getTagParams(coerce)
        return self.b:getTagParams(coerce), self.g:getTagParams(coerce), self.r:getTagParams(coerce)
    end
    return Color
end