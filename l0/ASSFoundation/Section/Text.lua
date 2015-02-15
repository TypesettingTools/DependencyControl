return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local TextSection = createASSClass("Section.Text", ASS.String, {"value"}, {"string"})

    function TextSection:new(value)
        self.value = self:typeCheck(self:getArgs({value},"",true))
        return self
    end

    function TextSection:getString(coerce)
        if coerce then return tostring(self.value)
        else return self:typeCheck(self.value) end
    end


    function TextSection:getEffectiveTags(includeDefault, includePrevious, copyTags)
        includePrevious, copyTags = default(includePrevious, true), true
        -- previous and default tag lists
        local effTags
        if includeDefault then
            effTags = self.parent:getDefaultTags(nil, copyTags)
        end

        if includePrevious and self.prevSection then
            local prevTagList = self.prevSection:getEffectiveTags(false, true, copyTags)
            effTags = includeDefault and effTags:merge(prevTagList, false, false, true) or prevTagList
        end

        return effTags or ASS.TagList(nil, self.parent)
    end

    function TextSection:getStyleTable(name, coerce)
        return self:getEffectiveTags(false,true,false):getStyleTable(self.parent.line.styleRef, name, coerce)
    end

    function TextSection:getTextExtents(coerce)
        return aegisub.text_extents(self:getStyleTable(nil,coerce),self.value)
    end

    function TextSection:getMetrics(includeTypeBounds, coerce)
        assert(YUtils, yutilsMissingMsg)
        local fontObj, tagList, shape = self:getYutilsFont()
        local metrics = table.merge(fontObj.metrics(),fontObj.text_extents(self.value))

        if includeTypeBounds then
            shape = fontObj.text_to_shape(self.value)
            metrics.typeBounds = {YUtils.shape.bounding(shape)}
            metrics.typeBounds.width = (metrics.typeBounds[3] or 0)-(metrics.typeBounds[1] or 0)
            metrics.typeBounds.height = (metrics.typeBounds[4] or 0)-(metrics.typeBounds[2] or 0)
        end

        return metrics, tagList, shape
    end

    function TextSection:getShape(applyRotation, coerce)
        applyRotation = default(applyRotation, false)
        local metr, tagList, shape = self:getMetrics(true)
        local drawing, an = ASS.Draw.DrawingBase{str=shape}, tagList.tags.align:getSet()
        -- fix position based on aligment
            drawing:sub(not an.left and (metr.width-metr.typeBounds.width)   / (an.centerH and 2 or 1) or 0,
                        not an.top  and (metr.height-metr.typeBounds.height) / (an.centerV and 2 or 1) or 0
            )

        -- rotate shape
        if applyRotation then
            local angle = tagList.tags.angle:getTagParams(coerce)
            drawing:rotate(angle)
        end
        return drawing
    end

    function TextSection:convertToDrawing(applyRotation, coerce)
        local shape = self:getShape(applyRotation, coerce)
        self.value, self.contours, self.scale = nil, shape.contours, shape.scale
        setmetatable(self, ASS.Section.Drawing)
        return self
    end

    function TextSection:expand(x,y)
        self:convertToDrawing()
        return self:expand(x,y)
    end

    function TextSection:getYutilsFont(coerce)
        assert(YUtils, yutilsMissingMsg)
        local tagList = self:getEffectiveTags(true,true,false)
        local tags = tagList.tags
        return YUtils.decode.create_font(tags.fontname:getTagParams(coerce), tags.bold:getTagParams(coerce)>0,
                                         tags.italic:getTagParams(coerce)>0, tags.underline:getTagParams(coerce)>0, tags.strikeout:getTagParams(coerce)>0,
                                         tags.fontsize:getTagParams(coerce), tags.scale_x:getTagParams(coerce)/100, tags.scale_y:getTagParams(coerce)/100,
                                         tags.spacing:getTagParams(coerce)
        ), tagList
    end
    return TextSection
end