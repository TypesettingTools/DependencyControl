return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local CommandBase = createASSClass("Draw.CommandBase", ASS.Tag.Base, {}, {})
    function CommandBase:new(...)
        local args = {self:getArgs({...}, 0, true)}

        if self.compatible[ASS.Point] then
            self.x, self.y = ASS.Number{args[1]}, ASS.Number{args[2]}
        else
            for i=1,#args,2 do
                local j = (i+1)/2
                self[self.__meta__.order[j]] = self.__meta__.types[j]{args[i],args[i+1]}
            end
        end
        return self
    end


    function CommandBase:getTagParams(coerce)
        local params, parts = self.__meta__.order, {}
        local i, j = 1, 1
        while i<=self.__meta__.rawArgCnt do
            parts[i], parts[i+1] = self[params[j]]:getTagParams(coerce)
            i, j = i+self[params[j]].__meta__.rawArgCnt, j+1
        end
        return table.concat(parts, " ")
    end

    function CommandBase:getLength(prevCmd)
        assert(YUtils, yutilsMissingMsg)
        -- get end coordinates (cursor) of previous command
        local x0, y0 = 0, 0
        if prevCmd and prevCmd.__tag.name == "b" then
            x0, y0 = prevCmd.p3:get()
        elseif prevCmd then x0, y0 = prevCmd:get() end

        -- save cursor for further processing
        self.cursor = ASS.Point{x0, y0}

        local name, len = self.__tag.name, 0
        if name == "b" then
            -- TODO: check
            local shapeSection = ASS.Draw.DrawingBase{ASS.Draw.Move(self.cursor:get()),self}
            self.flattened = ASS.Draw.DrawingBase{str=YUtils.shape.flatten(shapeSection:getTagParams())} --save flattened shape for further processing
            len = self.flattened:getLength()
        elseif name =="m" or name == "n" then len=0
        elseif name =="l" then
            local x, y = self:get()
            len = YUtils.math.distance(x-x0, y-y0)
        end
        -- save length for further processing
        self.length = len
        return len
    end

    function CommandBase:getPositionAtLength(len, noUpdate, useCurveTime)
        assert(YUtils, yutilsMissingMsg)
        if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
        local name, pos = self.__tag.name
        if name == "b" and useCurveTime then
            local px, py = YUtils.math.bezier(math.min(len/self.length,1), {{self.cursor:get()},{self.p1:get()},{self.p2:get()},{self.p3:get()}})
            pos = ASS.Point{px, py}
        elseif name == "b" then
            pos = self:getFlattened(true):getPositionAtLength(len, true)   -- we already know this data is up-to-date because self.parent:getLength() was run
        elseif name == "l" then
            pos = ASS.Point{self:copy():ScaleToLength(len,true)}
        elseif name == "m" then
            pos = ASS.Point{self}
        end
        pos.__tag.name = "position"
        return pos
    end

    function CommandBase:getPoints(allowCompatible)
        return allowCompatible and {self} or {ASS.Point{self}}
    end

    return CommandBase
end