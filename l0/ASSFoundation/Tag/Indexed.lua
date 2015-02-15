return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Indexed = createASSClass("Tag.Indexed", ASS.Number, {"value"}, {"number"}, {precision=0, positive=true})
    function Indexed:cycle(down)
        local min, max = self.__tag.range[1], self.__tag.range[2]
        if down then
            return self.value<=min and self:set(max) or self:add(-1)
        else
            return self.value>=max and self:set(min) or self:add(1)
        end
    end

    return Indexed
end