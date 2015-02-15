return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    ClipRect = createASSClass("Tag.ClipRect", ASS.Tag.Base, {"topLeft", "bottomRight"}, {ASS.Point, ASS.Point})

    function ClipRect:new(args)
        local left, top, right, bottom = self:getArgs(args, 0, true)
        self:readProps(args)

        self.topLeft = ASS.Point{left, top}
        self.bottomRight = ASS.Point{right, bottom}
        self:setInverse(self.__tag.inverse or false)
        return self
    end

    function ClipRect:getTagParams(coerce)
        self:setInverse(self.__tag.inverse or false)
        return returnAll({self.topLeft:getTagParams(coerce)}, {self.bottomRight:getTagParams(coerce)})
    end

    function ClipRect:getVect()
        local vect = ASSFInst:createTag(ASS.tagNames[ASS.ClipVect][self.__tag.inverse and 2 or 1])
        return vect:drawRect(self.topLeft, self.bottomRight)
    end

    function ClipRect:getDrawing(trimDrawing, pos, an)
        if ASS:instanceOf(pos, ASS.TagList) then
            pos, an = pos.tags.position, pos.tags.align
        end

        if not (pos and an) then
            if self.parent and self.parent.parent then
                local effTags = self.parent.parent:getEffectiveTags(-1, true, true, false).tags
                pos, an = pos or effTags.position, an or effTags.align
            end
        end

        return self:getVect():getDrawing(trimDrawing, pos, an)
    end

    function ClipRect:setInverse(state)
        state = state==nil and true or state
        self.__tag.inverse = state
        self.__tag.name = state and "iclip_rect" or "clip_rect"
        return state
    end

    function ClipRect:toggleInverse()
        return self:setInverse(not self.__tag.inverse)
    end

    return ClipRect
end