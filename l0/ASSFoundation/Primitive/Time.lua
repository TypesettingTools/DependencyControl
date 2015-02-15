return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Time = createASSClass("Time", ASS.Number, {"value"}, {"number"}, {precision=0})
    -- TODO: implement adding by framecount

    function Time:getTagParams(coerce, precision)
        precision = precision or 0
        local val = self.value
        if coerce then
            precision = math.min(precision,0)
            val = self:coerceNumber(0)
        else
            assertEx(precision <= 0, "%s doesn't support floating point precision.", self.typeName)
            self:checkType("number", self.value)
            if self.__tag.positive then self:checkPositive(self.value) end
        end
        val = val/self.__tag.scale
        return math.round(val,precision)
    end
    return Time
end