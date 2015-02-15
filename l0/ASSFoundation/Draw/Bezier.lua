return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local DrawBezier = createASSClass("Draw.Bezier", ASS.Draw.CommandBase, {"p1","p2","p3"},
                                      {ASS.Point, ASS.Point, ASS.Point}, {name="b", ords=6})

    function DrawBezier:commonOp(method, callback, default, ...)
        local args, j, valNames = {...}, 1, self.__meta__.order
        if #args<=2 then -- special case to allow common operation on all x an y values of a vector drawing
            args[3], args[4], args[5], args[6] = args[1], args[2], args[1], args[2]
            if type(default)=="table" and #default<=2 then
                default = {default[1], default[2], default[1], default[2]}
            end
        end
        args = {self:getArgs(args, default, false)}

        for i=1,#valNames do
            local subCnt = #self[valNames[i]].__meta__.order
            local subArgs = table.sliceArray(args,j,j+subCnt-1)
            self[valNames[i]][method](self[valNames[i]],unpack(subArgs))
            j=j+subCnt
        end
        return self
    end

    function DrawBezier:getFlattened(noUpdate)
        assert(YUtils, yutilsMissingMsg)
        if not (noUpdate and self.flattened) then
            if not (noUpdate and self.cursor) then
                self.parent:getLength()
            end
            -- TODO: check
            local shapeSection = ASS.Draw.DrawingBase{ASS.Draw.Move(self.cursor:get()),self}
            self.flattened = ASS.Draw.DrawingBase{str=YUtils.shape.flatten(shapeSection:getTagParams())}
        end
        return self.flattened
    end

    function DrawBezier:getPoints()
        return {self.p1, self.p2, self.p3}
    end

    return DrawBezier
end