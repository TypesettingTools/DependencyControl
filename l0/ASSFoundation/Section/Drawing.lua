return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local DrawingSection = createASSClass("Section.Drawing", ASS.Draw.DrawingBase, {"contours","scale"}, {"table", ASS.Number},
                                          {}, {ASS.Draw.DrawingBase, ASS.Tag.ClipVect})

    DrawingSection.getStyleTable = ASS.Section.Text.getStyleTable
    DrawingSection.getEffectiveTags = ASS.Section.Text.getEffectiveTags
    DrawingSection.getString = DrawingSection.getTagParams
    DrawingSection.getTagString = nil

    function DrawingSection:alignToOrigin(mode)
        mode = ASS.Tag.Align{mode or 7}
        local ex = self:getExtremePoints(true)
        local cmdOff = ASS.Point{ex.left.x, ex.top.y}
        local posOff = mode:getPositionOffset(ex.w, ex.h):add(cmdOff)
        self:sub(cmdOff)
        return posOff, ex
    end

    function DrawingSection:getBounds(coerce)
        assert(YUtils, yutilsMissingMsg)
        local bounds = {YUtils.shape.bounding(self:getString())}
        bounds.width = (bounds[3] or 0)-(bounds[1] or 0)
        bounds.height = (bounds[4] or 0)-(bounds[2] or 0)
        return bounds
    end

    function DrawingSection:getClip(inverse)
        -- TODO: scale support
        local effTags, ex = self.parent:getEffectiveTags(-1, true, true, false).tags , self:getExtremePoints()
        local clip = ASS:createTag(ASS.tagNames[ASS.Tag.ClipVect][inverse and 2 or 1], self)
        local anOff = effTags.align:getPositionOffset(ex.w, ex.h)
        return clip:add(effTags.position):sub(anOff)
    end

    return DrawingSection
end