return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local LineBounds = createASSClass("LineBounds", ASS.Base, {1, 2, "w", "h", "fbf", "animated", "rawText"},
                                  {ASS.Point, ASS.Point, "number", "number", "table", "boolean", "string"})
    function LineBounds:new(cnts, noCommit)
        -- TODO: throw error if no video is open
        assertEx(ASS:instanceOf(cnts, ASS.LineContents), "argument #1 must be an object of type %s, got a %s.",
                 ASS.LineContents.typeName, ASS:instanceOf(cnts) or type(cnts)
        )
        if not noCommit then cnts:commit() end

        local assi, msg = ASSFInst.cache.ASSInspector
        if not assi then
            assi, msg = ASSInspector(cnts.sub)
            assertEx(assi, "ASSInspector Error: %s.", tostring(msg))
            ASSFInst.cache.ASSInspector = assi
        elseif cnts.line.sub ~= ASSFInst.cache.lastSub then
            assi:updateHeader(cnts.line.sub)
            ASSFInst.cache.lastSub = cnts.line.sub
        end

        self.animated = cnts:isAnimated()
        cnts.line.assi_exhaustive = self.animated

        local bounds, times = assi:getBounds{cnts.line}
        assertEx(bounds~=nil,"ASSInspector Error: %s.", tostring(times))

        if bounds[1]~=false or self.animated then
            local frame, x2Max, y2Max, x1Min, y1Min = aegisub.frame_from_ms, 0, 0

            self.fbf={off=frame(times[1]), n=#bounds}
            for i=1,self.fbf.n do
                if bounds[i] then
                    local x1, y1, w, h = bounds[i].x, bounds[i].y, bounds[i].w, bounds[i].h
                    local x2, y2 = x1+w, y1+h
                    self.fbf[frame(times[i])] = {ASS.Point{x1,y1}, ASS.Point{x2,y2}, w=w, h=h, hash=bounds[i].hash, solid=bounds[i].solid}
                    x1Min, y1Min = math.min(x1, x1Min or x1), math.min(y1, y1Min or y1)
                    x2Max, y2Max = math.max(x2, x2Max), math.max(y2, y2Max)
                else self.fbf[frame(times[i])] = {w=0, h=0, hash=false} end
            end

            if x1Min then
               self[1], self[2], self.w, self.h = ASS.Point{x1Min,y1Min}, ASS.Point{x2Max, y2Max}, x2Max-x1Min, y2Max-y1Min
               self.firstHash = self.fbf[self.fbf.off].hash
               self.firstFrameIsSolid = self.fbf[self.fbf.off].solid
            else self.w, self.h = 0, 0 end

        else self.w, self.h, self.fbf = 0, 0, {n=0} end

        self.rawText = cnts.line.text
        if not noCommit then cnts:undoCommit() end
        return self
    end

    function LineBounds:equal(other)
        assertEx(ASS:instanceOf(other, LineBounds), "argument #1 must be an object of type %s, got a %s.",
                 LineBounds.typeName, ASS:instanceOf(other) or type(other))
        if self.w + other.w == 0 then
            return true
        elseif self.w~=other.w or self.h~=other.h or self.animated~=other.animated or self.fbf.n~=other.fbf.n then
            return false
        end

        for i=0,self.fbf.n-1 do
            if self.fbf[self.fbf.off+i].hash ~= other.fbf[other.fbf.off+i].hash then
                return false
            end
        end

        return true
    end
    return LineBounds
end