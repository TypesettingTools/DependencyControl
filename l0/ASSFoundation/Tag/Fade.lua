return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Fade = createASSClass("Tag.Fade", ASS.Tag.Base,
        {"startDuration", "endDuration", "startTime", "endTime", "startAlpha", "midAlpha", "endAlpha"},
        {ASS.Duration, ASS.Duration, ASS.Time, ASS.Time, ASS.Hex, ASS.Hex, ASS.Hex}
    )
    function Fade:new(args)
        self:readProps(args)
        if args.raw and self.__tag.name=="fade" then
            local a, r, num = {}, args.raw, tonumber
            a[1], a[2], a[3], a[4] = num(r[5])-num(r[4]), num(r[7])-num(r[6]), r[4], r[7]
            -- avoid having alpha values automatically parsed as hex strings
            a[5], a[6], a[7] = num(r[1]), num(r[2]), num(r[3])
            args.raw = a
        end
        startDuration, endDuration, startTime, endTime, startAlpha, midAlpha, endAlpha = self:getArgs(args,{0,0,0,0,255,0,255},true)

        self.startDuration, self.endDuration = ASS.Duration{startDuration}, ASS.Duration{endDuration}
        self.startTime, self.endTime = ASS.Time{startTime}, ASS.Time{endTime}
        self.startAlpha, self.midAlpha, self.endAlpha = ASS.Hex{startAlpha}, ASS.Hex{midAlpha}, ASS.Hex{endAlpha}

        if self.__tag.simple == nil then
            self.__tag.simple = self:setSimple(args.simple)
        end

        return self
    end

    function Fade:getTagParams(coerce)
        if self.__tag.simple then
            return self.startDuration:getTagParams(coerce), self.endDuration:getTagParams(coerce)
        else
            local t1, t4 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
            local t2 = t1 + self.startDuration:getTagParams(coerce)
            local t3 = t4 - self.endDuration:getTagParams(coerce)
            if not coerce then
                 self:checkPositive(t2,t3)
                 assertEx(t1<=t2 and t2<=t3 and t3<=t4, "fade times must evaluate to t1<=t2<=t3<=t4, got %d<=%d<=%d<=%d.",
                          t1,t2,t3,t4)
            end
            return self.startAlpha:getTagParams(coerce), self.midAlpha:getTagParams(coerce), self.endAlpha:getTagParams(coerce),
                   math.min(t1,t2), util.clamp(t2,t1,t3), util.clamp(t3,t2,t4), math.max(t4,t3)
        end
    end

    function Fade:setSimple(state)
        if state==nil then
            state = self.startTime:equal(0) and self.endTime:equal(0) and
                    self.startAlpha:equal(255) and self.midAlpha:equal(0) and self.endAlpha:equal(255)
        end
        self.__tag.simple, self.__tag.name = state, state and "fade_simple" or "fade"
        return state
    end

    return Fade
end