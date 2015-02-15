return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    Point = createASSClass("Point", ASS.Tag.Base, {"x","y"}, {ASS.Number, ASS.Number})
    function Point:new(args)
        local x, y = self:getArgs(args,0,true)
        self:readProps(args)
        self.x, self.y = ASS.Number{x}, ASS.Number{y}
        return self
    end

    function Point:getTagParams(coerce, precision)
        return self.x:getTagParams(coerce, precision), self.y:getTagParams(coerce, precision)
    end

    function Point:getAngle(ref, vectAngle)
        local rx, ry
        assertEx(type(ref)=="table", "argument #1 (ref) must be of type table, got a %s.", type(ref))
        if ref.instanceOf[ASS.Draw.Bezier] then
            rx, ry = ref.p3:get()
        elseif not ref.instanceOf then
            rx, ry = ref[1], ref[2]
            assertEx(type(rx)=="number" and type(rx)=="number",
                     "table with reference coordinates must be of format {x,y}, got {%s,%s}.", tostring(rx), tostring(ry))
        elseif ref.compatible[Point] then
            rx, ry = ref:get()
        else error(string.format(
                   "Error: argument #1 (ref) be an %s (or compatible), a drawing command or a coordinates table, got a %s.",
                   Point.typeName, ref.typeName))
        end

        local sx, sy, deg = self.x.value, self.y.value
        if vectAngle then
            local cw = (sx*ry - sy*rx)<0
            local a = (sx*rx + sy*ry) / math.sqrt(sx^2 + sy^2) / math.sqrt(rx^2 + ry^2)
            -- math.acos(x) only defined for -1<x<1, a may be 1/0
            deg = (a>=1 or a<=-1 or a~=a) and 0 or math.deg(math.acos(a) * (cw and 1 or -1))
        else
            deg = math.deg(-math.atan2(sy-ry, sx-rx))
        end

        return ASS:createTag("angle", deg), cw
    end
    return Point
end