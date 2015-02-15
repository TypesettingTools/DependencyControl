return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Align = createASSClass("Tag.Align", ASS.Tag.Indexed, {"value"}, {"number"}, {range={1,9}, default=5})

    function Align:up()
        if self.value<7 then return self:add(3)
        else return false end
    end

    function Align:down()
        if self.value>3 then return self:add(-3)
        else return false end
    end

    function Align:left()
        if self.value%3~=1 then return self:add(-1)
        else return false end
    end

    function Align:right()
        if self.value%3~=0 then return self:add(1)
        else return false end
    end

    function Align:centerV()
        if self.value<=3 then self:up()
        elseif self.value>=7 then self:down() end
    end

    function Align:centerH()
        if self.value%3==1 then self:right()
        elseif self.value%3==0 then self:left() end
    end

    function Align:getSet(pos)
        local val = self.value
        local set = { top = val>=7, centerV = val>3 and val<7, bottom = val<=3,
                      left = val%3==1, centerH = val%3==2, right = val%3==0 }
        return pos==nil and set or set[pos]
    end

    function Align:isTop() return self:getSet("top") end
    function Align:isCenterV() return self:getSet("centerV") end
    function Align:isBottom() return self:getSet("bottom") end
    function Align:isLeft() return self:getSet("left") end
    function Align:isCenterH() return self:getSet("centerH") end
    function Align:isRight() return self:getSet("right") end

    function Align:getPositionOffset(w, h)
        local x, y = {w, 0, w/2}, {h, h/2, 0}
        local off = ASS.Point{x[self.value%3+1], y[math.ceil(self.value/3)]}
        return off
    end

    return Align
end