return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local ClipVect = createASSClass("Tag.ClipVect", ASS.Draw.DrawingBase, {"commands", "scale"},
                                    {"table", ASS.Number}, {}, {ASS.Draw.DrawingBase})
    --TODO: unify setInverse and toggleInverse for VectClip and RectClip by using multiple inheritance
    function ClipVect:setInverse(state)
        state = state==nil and true or state
        self.__tag.inverse = state
        self.__tag.name = state and "iclip_vect" or "clip_vect"
        return state
    end

    function ClipVect:toggleInverse()
        return self:setInverse(not self.__tag.inverse)
    end

    function ClipVect:getDrawing(trimDrawing, pos, an)
        if ASS.instanceOf(pos, ASS.TagList) then
            pos, an = pos.tags.position, pos.tags.align
        end

        if not (pos and an) then
            if self.parent and self.parent.parent then
                local effTags = self.parent.parent:getEffectiveTags(-1, true, true, false).tags
                pos, an = pos or effTags.position, an or effTags.align
            elseif not an then an=ASS.Tag.Align{7} end
        end

        assertEx(not pos or ASS.instanceOf(pos, ASS.Point, nil, true),
                 "argument position must be an %d or a compatible object, got a %s.",
                 ASS.Point.typeName, type(pos)=="table" and pos.typeName or type(pos))
        assertEx(ASS.instanceOf(an, ASS.Tag.Align),
                 "argument align must be an %d or a compatible object, got a %s.",
                 ASS.Tag.Align.typeName, type(pos)=="table" and an.typeName or type(an))

        local drawing = ASS.Section.Drawing{self}
        local ex = self:getExtremePoints()
        local anOff = an:getPositionOffset(ex.w, ex.h)

        if trimDrawing or not pos then
            drawing:sub(ex.left.x.value, ex.top.y.value)
            return drawing, ASS:createTag("position", ex.left.x, ex.top.y):add(anOff)
        else return drawing:add(anOff):sub(pos) end
    end

    return ClipVect
end