return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Move = createASSClass("Tag.Move", ASS.Tag.Base,
        {"startPos", "endPos", "startTime", "endTime"},
        {ASS.Point, ASS.Point, ASS.Time, ASS.Time}
    )
    function Move:new(args)
        local startX, startY, endX, endY, startTime, endTime = self:getArgs(args, 0, true)

        assertEx(startTime<=endTime, "argument #4 (endTime) to %s may not be smaller than argument #3 (startTime), got %d>=%d.",
                 self.typeName, endTime, startTime)

        self:readProps(args)
        self.startPos, self.endPos = ASS.Point{startX, startY}, ASS.Point{endX, endY}
        self.startTime, self.endTime = ASS.Time{startTime}, ASS.Time{endTime}

        if self.__tag.simple == nil then
            self.__tag.simple = self:setSimple(args.simple)
        end

        return self
    end

    function Move:getTagParams(coerce)
        if self.__tag.simple or self.__tag.name=="move_simple" then
            return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)})
        else
            local t1,t2 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
            if not coerce then
                 assertEx(t1<=t2, "move times must evaluate to t1<=t2, got %d<=%d.", t1,t2)
            end
            return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)},
                             {math.min(t1,t2)}, {math.max(t2,t1)})
        end
    end

    function Move:setSimple(state)
        if state==nil then
            state = self.startTime:equal(0) and self.endTime:equal(0)
        end
        self.__tag.simple, self.__tag.name = state, state and "move_simple" or "move"
        return state
    end

    return Move
end