return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local LineContents = createASSClass("LineContents", ASS.Base, {"sections"}, {"table"})
    function LineContents:new(line, sections)
        sections = self:getArgs({sections})
        assertEx(line and line.__class==Line, "argument 1 to %s() must be a Line or %s object, got %s.",
                 self.typeName, self.typeName, type(line))
        if not sections then
            sections = {}
            local i, j, drawingState, ovrStart, ovrEnd = 1, 1, ASS:createTag("drawing",0)
            while i<=#line.text do
                ovrStart, ovrEnd = line.text:find("{.-}",i)
                if ovrStart then
                    if ovrStart>i then
                        local substr = line.text:sub(i,ovrStart-1)
                        sections[j], j = drawingState.value==0 and ASS.Section.Text(substr) or ASS.Section.Drawing{str=substr, scale=drawingState}, j+1
                    end
                    sections[j] = ASS.Section.Tag(line.text:sub(ovrStart+1,ovrEnd-1))
                    -- remove drawing tags from the tag sections so we don't have to keep state in sync with ASSSection.Drawing
                    local drawingTags = sections[j]:removeTags("drawing")
                    if #sections[j].tags == 0 and #drawingTags>0 then
                        sections[j], j = nil, j-1
                    end
                    drawingState = drawingTags[#drawingTags] or drawingState
                    i = ovrEnd +1
                else
                    local substr = line.text:sub(i)
                    sections[j] = drawingState.value==0 and ASS.Section.Text(substr) or ASS.Section.Drawing{str=substr, scale=drawingState}
                    break
                end
                j=j+1
            end
        else sections = self:typeCheck(util.copy(sections)) end
        -- TODO: check if typeCheck works correctly with compatible classes and doesn't do useless busy work
        if line.parentCollection then
            self.sub, self.styles = line.parentCollection.sub, line.parentCollection.styles
            self.scriptInfo = line.parentCollection.meta
            ASSFInst.cache.lastParentCollection = line.parentCollection
            ASSFInst.cache.lastStyles, ASSFInst.cache.lastSub = line.parentCollection.styles, self.sub
        else self.scriptInfo = self.sub and ASS:getScriptInfo(self.sub) end
        self.line, self.sections = line, sections
        self:updateRefs()
        return self
    end

    function LineContents:updateRefs(prevCnt)
        if prevCnt~=#self.sections then
            for i=1,#self.sections do
                self.sections[i].prevSection = self.sections[i-1]
                self.sections[i].parent = self
                self.sections[i].index = i
            end
            return true
        else return false end
    end

    function LineContents:getString(coerce, classes)
        local defDrawingState = ASS:createTag("drawing",0)
        local j, str, sections, prevDrawingState, secType, prevSecType = 1, {}, self.sections, defDrawingState

        for i=1,#sections do
            secType, lastSecType = ASS:instanceOf(sections[i], ASS.Section, classes), secType
            if secType == ASS.Section.Text or secType == ASS.Section.Drawing then
                -- determine whether we need to enable or disable drawing mode and insert the appropriate tags
                local drawingState = secType==ASS.Section.Drawing and sections[i].scale or defDrawingState
                if drawingState ~= prevDrawingState then
                    if prevSecType==ASS.Section.Tag then
                        table.insert(str,j-1,drawingState:getTagString())
                        j=j+1
                    else
                        str[j], str[j+1], str[j+2], j = "{", drawingState:getTagString(), "}", j+3
                    end
                    prevDrawingState = drawingState
                end
                str[j] = sections[i]:getString()

            elseif secType == ASS.Section.Tag or secType==ASS.Section.Comment then
                str[j], str[j+1], str[j+2], j =  "{", sections[i]:getString(), "}", j+2

            else
                assertEx(coerce, "invalid %s section #%d. Expected {%s}, got a %s.",
                     self.typeName, i, table.concat(table.pluck(ASS.Section, "typeName"), ", "),
                     type(sections[i])=="table" and sections[i].typeName or type(sections[i])
                )
            end
            prevSecType, j = secType, j+1
        end
        return table.concat(str)
    end

    function LineContents:get(sectionClasses, start, end_, relative)
        local result, j = {}, 1
        self:callback(function(section,sections,i)
            result[j], j = section:copy(), j+1
        end, sectionClasses, start, end_, relative)
        return result
    end

    function LineContents:callback(callback, sectionClasses, start, end_, relative, reverse)
        local prevCnt = #self.sections
        start = default(start,1)
        end_ = default(end_, start>=1 and math.max(prevCnt,1) or -1)
        reverse = relative and start<0 or reverse

        assertEx(math.isInt(start) and math.isInt(end_),
                 "arguments 'start' and 'end' to callback() must be integers, got %s and %s.", type(start), type(end_))
        assertEx((start>0)==(end_>0) and start~=0 and end_~=0,
                 "arguments 'start' and 'end' to callback() must be either both >0 or both <0, got %d and %d.", start, end_)
        assertEx(start <= end_, "condition 'start' <= 'end' not met, got %d <= %d", start, end_)

        local j, numRun, sects = 0, 0, self.sections
        if start<0 then
            start, end_ = relative and math.abs(end_) or prevCnt+start+1, relative and math.abs(start) or prevCnt+end_+1
        end

        for i=reverse and prevCnt or 1, reverse and 1 or prevCnt, reverse and -1 or 1 do
            if ASS:instanceOf(sects[i], ASS.Section, sectionClasses) then
                j=j+1
                if (relative and j>=start and j<=end_) or (not relative and i>=start and i<=end_) then
                    numRun = numRun+1
                    local result = callback(sects[i],self.sections,i,j)
                    if result==false then
                        sects[i]=nil
                    elseif type(result)~="nil" and result~=true then
                        sects[i] = result
                        prevCnt=-1
                    end
                end
            end
        end
        self.sections = table.reduce(self.sections)
        self:updateRefs(prevCnt)
        return numRun>0 and numRun or false
    end

    function LineContents:insertSections(sections,index)
        index = index or #self.sections+1
        if type(sections)~="table" or sections.instanceOf then
            sections = {sections}
        end
        for i=1,#sections do
            assertEx(ASS:instanceOf(sections[i],ASS.Section), "can only insert sections of type {%s}, got %s.",
                     table.concat(table.select(ASS.Section, {"typeName"}), ", "), type(sections[i])
            )
            table.insert(self.sections, index+i-1, sections[i])
        end
        self:updateRefs()
        return sections
    end

    function LineContents:removeSections(start, end_)
        local removed = {}
        if not start then
            self.sections, removed = {}, self.sections
        elseif type(start) == "number" then
            end_ = end_ or start
            removed = table.removeRange(self.sections, start, end_)
        elseif type(start) == "table" then
            local toRemove = start.instanceOf and {[start]=true} or table.arrayToSet(start)
            local j = 1
            for i=1, #self.sections do
                if toRemove[self.sections[i]] then
                    local sect = self.sections[i]
                    removed[i-j+1], self.sections[i] = sect, nil
                    sect.parent, sect.index, sect.prevSection = nil, nil, nil
                elseif j~=i then
                    self.sections[j], j = self.sections[i], j+1
                else j=i+1 end
            end
        else error("Error: invalid parameter #1. Expected a rangem, an ASSObject or a table of ASSObjects, got a " .. type(start)) end
        self:updateRefs()
        return removed
    end

    function LineContents:modTags(tagNames, callback, start, end_, relative)
        start = default(start,1)
        end_ = default(end_, start<0 and -1 or math.max(self:getTagCount(),1))
        -- TODO: validation for start and end_
        local modCnt, reverse = 0, start<0

        self:callback(function(section)
            if (reverse and modCnt<-start) or (modCnt<end_) then
                local sectStart = reverse and start+modCnt or math.max(start-modCnt,1)
                local sectEnd = reverse and math.min(end_+modCnt,-1) or end_-modCnt
                local sectModCnt = section:modTags(tagNames, callback, relative and sectStart or nil, relative and sectEnd or nil, true)
                modCnt = modCnt + (sectModCnt or 0)
            end
        end, ASS.Section.Tag, not relative and start or nil, not relative and end_ or nil, true, reverse)

        return modCnt>0 and modCnt or false
    end

    function LineContents:getTags(tagNames, start, end_, relative)
        local tags, i = {}, 1

        self:modTags(tagNames, function(tag)
            tags[i], i = tag, i+1
        end, start, end_, relative)

        return tags
    end

    function LineContents:replaceTags(tagList, start, end_, relative)  -- TODO: transform and reset support
        if type(tagList)=="table" then
            if tagList.class == ASS.Section.Tag then
                tagList = ASS.TagList(tagList)
            elseif tagList.class and tagList.class ~= ASS.TagList then
                local tag = tagList
                tagList = ASS.TagList(nil, self)
                tagList.tags[tag.__tag.name] = tag
            else tagList = ASS.TagList(ASS.Section.Tag(tagList)) end
        else
            assertEx(tagList==nil, "argument #1 must be a tag object, a table of tag objects, an %s or an ASSTagList; got a %s.",
                     ASS.Section.Tag.typeName, ASS.TagList.typeName, type(tagList))
            return
        end

        local toInsert = ASS.TagList(tagList)
        -- search for tags in line, replace them if found
        -- remove all matching global tags that are not in the first section
        self:callback(function(section,_,i)
            section:callback(function(tag)
                local props = tag.__tag
                if tagList.tags[props.name] then
                    if props.global and i>1 then
                        return false
                    else
                        toInsert.tags[props.name] = nil
                        return tagList.tags[props.name]:copy()
                    end
                end
            end)
        end, ASS.Section.Tag, start, end_, relative)

        local globalToInsert, toInsert = toInsert:filterTags(nil, {global=true})
        local firstIsTagSection = #self.sections>0 and self.sections[1].instanceOf[ASS.Section.Tag]
        local globalSection = firstIsTagSection and self.sections[1] or ASS.Section.Tag()
        -- Insert the global tag section at the beginning of the line
        -- in case it doesn't exist and we have global tags to insert.
        -- Always insert the global tags into the first section.
        if table.length(globalToInsert.tags)>0 then
            if not firstIsTagSection then self:insertSections(globalSection,1) end
            globalSection:insertTags(globalToInsert)
        end

        -- insert remaining tags (not replaced) into the first processed section
        self:insertTags(toInsert, start or 1, nil, not relative)
    end

    function LineContents:removeTags(tags, start, end_, relative)
        start = default(start,1)
        if relative then
            end_ = default(end_, start<0 and -1 or self:getTagCount())
        end
        -- TODO: validation for start and end_
        local removed, matchCnt, reverse  = {}, 0, start<0

        self:callback(function(section)
            if not relative then
                removed = table.join(removed,(section:removeTags(tags)))  -- exra parentheses because we only want the first return value
            elseif (reverse and matchCnt<-start) or (matchCnt<end_) then
                local sectStart = reverse and start+matchCnt or math.max(start-matchCnt,1)
                local sectEnd = reverse and math.min(end_+matchCnt,-1) or end_-matchCnt
                local sectRemoved, matched = section:removeTags(tags, sectStart, sectEnd, true)
                removed, matchCnt = table.join(removed,sectRemoved), matchCnt+matched
            end
        end, ASS.Section.Tag, not relative and start or nil, not relative and end_ or nil, true, reverse)

        return removed
    end

    function LineContents:insertTags(tags, index, sectionPosition, direct)
        assertEx(index==nil or math.isInt(index) and index~=0,
                 "argument #2 (index) to insertTags() must be an integer != 0, got '%s' of type %s", tostring(index), type(index)
        )
        index = default(index, 1)

        if direct then
            local section = self.sections[index>0 and index or #self.sections-index+1]
            assertEx(ASS:instanceOf(section, ASS.Section.Tag), "can't insert tag in section #%d of type %s.",
                   index, section and section.typeName or "<no section>"
            )
            return section:insertTags(tags, sectionPosition)
        else
            local inserted
            local sectFound = self:callback(function(section)
                inserted = section:insertTags(tags, sectionPosition)
            end, ASS.Section.Tag, index, index, true)
            if not sectFound and index==1 then
                inserted = self:insertSections(ASS.Section.Tag(),1)[1]:insertTags(tags)
            end
            return inserted
        end
    end

    function LineContents:insertDefaultTags(tagNames, index, sectionPosition, direct)
        local defaultTags = self:getDefaultTags():filterTags(tagNames)
        return self:insertTags(defaultTags, index, sectionPosition, direct)
    end

    function LineContents:getEffectiveTags(index, includeDefault, includePrevious, copyTags)
        index, copyTags = default(index,1), default(copyTags, true)
        assertEx(math.isInt(index) and index~=0,
                 "argument #1 (index) to getEffectiveTags() must be an integer != 0, got '%s' of type %s.",
                 tostring(index), type(index)
        )
        if index<0 then index = index+#self.sections+1 end
        return self.sections[index] and self.sections[index]:getEffectiveTags(includeDefault,includePrevious,copyTags)
               or ASS.TagList(nil, self)
    end

    function LineContents:getTagCount()
        local cnt, sects = 0, self.sections
        for i=1,#sects do
            cnt = cnt + (sects[i].tags and #sects[i].tags or 0)
        end
        return cnt
    end

    function LineContents:stripTags()
        self:callback(function(section,sections,i)
            return false
        end, ASS.Section.Tag)
        return self
    end

    function LineContents:stripText()
        self:callback(function(section,sections,i)
            return false
        end, ASS.Section.Text)
        return self
    end

    function LineContents:stripComments()
        self:callback(function(section,sections,i)
            return false
        end, ASS.Section.Comment)
        return self
    end

    function LineContents:stripDrawings()
        self:callback(function(section,sections,i)
            return false
        end, ASS.Section.Drawing)
        return self
    end

    function LineContents:commit(line)
        line = line or self.line
        line.text, line.undoText = self:getString(), line.text
        line:createRaw()
        return line.text
    end

    function LineContents:undoCommit(line)
        line = line or self.line
        if line.undoText then
            line.text, line.undoText = line.undoText
            line:createRaw()
            return true
        else return false end
    end

    function LineContents:cleanTags(level, mergeSect, defaultToKeep, tagSortOrder)
        mergeSect, level = default(mergeSect,true), default(level,3)
        -- Merge consecutive sections
        if mergeSect then
            local lastTagSection, numMerged = -1, 0
            self:callback(function(section,sections,i)
                if i==lastTagSection+numMerged+1 then
                    sections[lastTagSection].tags = table.join(sections[lastTagSection].tags, section.tags)
                    numMerged = numMerged+1
                    return false
                else
                    lastTagSection, numMerged = i, 0
                end
            end, ASS.Section.Tag)
        end

        -- 1: remove empty sections, 2: dedup tags locally, 3: dedup tags globally
        -- 4: remove tags matching style default and not changing state, end: remove empty sections
        local tagListPrev = ASS.TagList(nil, self)

        if level>=3 then
            tagListDef = self:getDefaultTags()
            if not defaultToKeep or #defaultToKeep==1 and defaultToKeep[1]=="position" then
                -- speed up the default mode a little by using a precomputed tag name table
                tagListDef:filterTags(ASS.tagNames.noPos)
            else tagListDef:filterTags(defaultToKeep, nil, false, true) end
        end

        if level>=1 then
            self:callback(function(section,sections,i)
                if level<2 then return #section.tags>0 end
                local isLastSection = i==#sections

                local tagList = section:getEffectiveTags(false,false,false)
                if level>=3 then tagList:diff(tagListPrev) end
                if level>=4 then
                    if i==#sections then tagList:filterTags(nil, {globalOrRectClip=true}) end
                    tagList:diff(tagListDef:merge(tagListPrev,false,true),false,true)
                end
                if not isLastSection then tagListPrev:merge(tagList,false, false, false, true) end

                return not tagList:isEmpty() and ASS.Section.Tag(tagList, false, tagSortOrder) or false
            end, ASS.Section.Tag)
        end
        return self
    end

    function LineContents:splitAtTags(cleanLevel, reposition, writeOrigin)
        cleanLevel = default(cleanLevel,3)
        local splitLines = {}
        self:callback(function(section,_,i,j)
            local splitLine = Line(self.line, self.line.parentCollection, {ASS={}})
            splitLine.ASS = ASS.LineContents(splitLine, table.insert(self:get(ASS.Section.Tag,0,i),section))
            splitLine.ASS:cleanTags(cleanLevel)
            splitLine.ASS:commit()
            splitLines[j] = splitLine
        end, ASS.Section.Text)
        if reposition then self:repositionSplitLines(splitLines, writeOrigin) end
        return splitLines
    end

    function LineContents:splitAtIntervals(callback, cleanLevel, reposition, writeOrigin)
        cleanLevel = default(cleanLevel,3)
        if type(callback)=="number" then
            local step=callback
            callback = function(idx,len)
                return idx+step
            end
        else assertEx(type(callback)=="function", "argument #1 must be either a number or a callback function, got a %s.",
                     type(callback))
        end

        local len, idx, sectEndIdx, nextIdx, lastI = unicode.len(self:copy():stripTags():getString()), 1, 0, 0
        local splitLines, splitCnt = {}, 1

        self:callback(function(section,_,i)
            local sectStartIdx, text, off = sectEndIdx+1, section.value, sectEndIdx
            sectEndIdx = sectStartIdx + unicode.len(section.value)-1

            -- process unfinished line carried over from previous section
            if nextIdx > idx then
                -- carried over part may span over more than this entire section
                local skip = nextIdx>sectEndIdx+1
                idx = skip and sectEndIdx+1 or nextIdx
                local addTextSection = skip and section:copy() or ASS.Section.Text(text:sub(1,nextIdx-off-1))
                local addSections, lastContents = table.insert(self:get(ASS.Section.Tag,lastI+1,i), addTextSection), splitLines[#splitLines].ASS
                lastContents:insertSections(addSections)
            end

            while idx <= sectEndIdx do
                nextIdx = math.ceil(callback(idx,len))
                assertEx(nextIdx>idx, "index returned by callback function must increase with every iteration, got %d<=%d.",
                         nextIdx, idx)
                -- create a new line
                local splitLine = Line(self.line, self.line.parentCollection)
                splitLine.ASS = LineContents(splitLine, self:get(ASS.Section.Tag,1,i))
                splitLine.ASS:insertSections(ASS.Section.Text(unicode.sub(text,idx-off,nextIdx-off-1)))
                splitLines[splitCnt], splitCnt = splitLine, splitCnt+1
                -- check if this section is long enough to fill the new line
                idx = sectEndIdx>=nextIdx-1 and nextIdx or sectEndIdx+1
            end
            lastI = i
        end, ASS.Section.Text)

        for i=1,#splitLines do
            splitLines[i].ASS:cleanTags(cleanLevel)
            splitLines[i].ASS:commit()
        end

        if reposition then self:repositionSplitLines(splitLines, writeOrigin) end
        return splitLines
    end

    function LineContents:repositionSplitLines(splitLines, writeOrigin)
        writeOrigin = default(writeOrigin,true)
        local lineWidth = self:getTextExtents()
        local getAlignOffset = {
            [0] = function(wSec,wLine) return wSec-wLine end,    -- right
            [1] = function() return 0 end,                       -- left
            [2] = function(wSec,wLine) return wSec/2-wLine/2 end -- center
        }
        local xOff = 0
        local origin = writeOrigin and self:getEffectiveTags(-1,true,true,false).tags["origin"]


        for i=1,#splitLines do
            local data = splitLines[i].ASS
            -- get tag state at last line section, if you use more than one \pos, \org or \an in a single line,
            -- you deserve things breaking around you
            local effTags = data:getEffectiveTags(-1,true,true,false)
            local sectWidth = data:getTextExtents()

            -- kill all old position tags because we only ever need one
            data:removeTags("position")
            -- calculate new position
            local alignOffset = getAlignOffset[effTags.tags["align"]:get()%3](sectWidth,lineWidth)
            local pos = effTags.tags["position"]:copy()
            pos:add(alignOffset+xOff,0)
            -- write new position tag to first tag section
            data:insertTags(pos,1,1)

            -- if desired, write a new origin to the line if the style or the override tags contain any angle
            if writeOrigin and (#data:getTags({"angle","angle_x","angle_y"})>0 or effTags.tags["angle"]:get()~=0) then
                data:removeTags("origin")
                data:insertTags(origin:copy(),1,1)
            end

            xOff = xOff + sectWidth
            data:commit()
        end
        return splitLines
    end

    function LineContents:getStyleRef(style)
        if ASS:instanceOf(style, ASS.String) then
            style = style:get()
        end
        if style==nil or style=="" then
            style = self.line.styleRef
        elseif type(style)=="string" then
            style = self.line.parentCollection.styles[style] or style
            assertEx(type(style)=="table", "couldn't find style with name '%s'.", style)
        else assertEx(type(style)=="table" and style.class=="style",
                    "invalid argument #1 (style): expected a style name or a styleRef, got a %s.", type(style))
        end
        return style
    end

    function LineContents:getPosition(style, align, forceDefault)
        self.line:extraMetrics()
        local effTags = not (forceDefault and align) and self:getEffectiveTags(-1,false,true,false).tags
        style = self:getStyleRef(style)
        align = align or effTags.align or style.align

        if ASS:instanceOf(align,ASS.Tag.Align) then
            align = align:get()
        else assertEx(type(align)=="number", "argument #1 (align) must be of type number or %s, got a %s.",
             ASS.Tag.Align.typeName, ASS:instanceOf(align) or type(align))
        end

        if not forceDefault and effTags.position then
            return effTags.position
        end

        local scriptInfo = self.scriptInfo or ASS:getScriptInfo(self.sub)
        -- blatantly copied from torque's Line.moon
        vMargin = self.line.margin_t == 0 and style.margin_t or self.line.margin_t
        lMargin = self.line.margin_l == 0 and style.margin_l or self.line.margin_l
        rMargin = self.line.margin_r == 0 and style.margin_r or self.line.margin_r

        return ASS:createTag("position", self.line.defaultXPosition[align%3+1](scriptInfo.PlayResX, lMargin, rMargin),
                                         self.line.defaultYPosition[math.ceil(align/3)](scriptInfo.PlayResY, vMargin)
        ), ASS:createTag("align", align)
    end

    -- TODO: make all caches members of ASSFoundation
    local styleDefaultCache = {}
    function LineContents:getDefaultTags(style, copyTags, useOvrAlign)
        copyTags, useOvrAlign = default(copyTags,true), default(useOvrAlign, true)
        local line = self.line
        style = self:getStyleRef(style)

        -- alignment override tag may affect the default position so we'll have to retrieve it
        local position, align = self:getPosition(style, not useOvrAlign and style.align, true)
        local raw = (useOvrAlign and style.align~=align.value) and style.raw.."_"..align.value or style.raw

        if styleDefaultCache[raw] then
            -- always return at least a fresh ASSTagList object to prevent the cached one from being overwritten
            return copyTags and styleDefaultCache[raw]:copy() or ASS.TagList(styleDefaultCache[raw])
        end

        local function styleRef(tag)
            if tag:find("alpha") then
                return style[tag:gsub("alpha", "color")]:sub(3,4)
            elseif tag:find("color") then
                return style[tag]:sub(5,6), style[tag]:sub(7,8), style[tag]:sub(9,10)
            else return style[tag] end
        end

        local scriptInfo = self.scriptInfo or ASS:getScriptInfo(self.sub)
        local resX, resY = tonumber(scriptInfo.PlayResX), tonumber(scriptInfo.PlayResY)

        local tagList = ASS.TagList(nil, self)
        tagList.tags = {
            scale_x = ASS:createTag("scale_x",styleRef("scale_x")),
            scale_y = ASS:createTag("scale_y", styleRef("scale_y")),
            align = ASS:createTag("align", styleRef("align")),
            angle = ASS:createTag("angle", styleRef("angle")),
            outline = ASS:createTag("outline", styleRef("outline")),
            outline_x = ASS:createTag("outline_x", styleRef("outline")),
            outline_y = ASS:createTag("outline_y", styleRef("outline")),
            shadow = ASS:createTag("shadow", styleRef("shadow")),
            shadow_x = ASS:createTag("shadow_x", styleRef("shadow")),
            shadow_y = ASS:createTag("shadow_y", styleRef("shadow")),
            alpha1 = ASS:createTag("alpha1", styleRef("alpha1")),
            alpha2 = ASS:createTag("alpha2", styleRef("alpha2")),
            alpha3 = ASS:createTag("alpha3", styleRef("alpha3")),
            alpha4 = ASS:createTag("alpha4", styleRef("alpha4")),
            color1 = ASS:createTag("color1", styleRef("color1")),
            color2 = ASS:createTag("color2", styleRef("color2")),
            color3 = ASS:createTag("color3", styleRef("color3")),
            color4 = ASS:createTag("color4", styleRef("color4")),
            clip_vect = ASS:createTag("clip_vect", {ASS.Draw.Move(0,0), ASS.Draw.Line(resX,0), ASS.Draw.Line(resX,resY), ASS.Draw.Line(0,resY), ASS.Draw.Line(0,0)}),
            iclip_vect = ASS:createTag("iclip_vect", {ASS.Draw.Move(0,0), ASS.Draw.Line(0,0), ASS.Draw.Line(0,0), ASS.Draw.Line(0,0), ASS.Draw.Line(0,0)}),
            clip_rect = ASS:createTag("clip_rect", 0, 0, resX, resY),
            iclip_rect = ASS:createTag("iclip_rect", 0, 0, 0, 0),
            bold = ASS:createTag("bold", styleRef("bold")),
            italic = ASS:createTag("italic", styleRef("italic")),
            underline = ASS:createTag("underline", styleRef("underline")),
            strikeout = ASS:createTag("strikeout", styleRef("strikeout")),
            spacing = ASS:createTag("spacing", styleRef("spacing")),
            fontsize = ASS:createTag("fontsize", styleRef("fontsize")),
            fontname = ASS:createTag("fontname", styleRef("fontname")),
            position = position,
            move_simple = ASS:createTag("move_simple", position, position),
            move = ASS:createTag("move", position, position),
            origin = ASS:createTag("origin", position),
        }
        for name,tag in pairs(ASS.tagMap) do
            if tag.default then tagList.tags[name] = tag.type{raw=tag.default, tagProps=tag.props} end
        end

        styleDefaultCache[style.raw] = tagList
        return copyTags and tagList:copy() or ASS.TagList(tagList)
    end

    function LineContents:getTextExtents(coerce)   -- TODO: account for linebreaks
        local width, other = 0, {0,0,0}
        self:callback(function(section)
            local extents = {section:getTextExtents(coerce)}
            width = width + table.remove(extents,1)
            table.process(other, extents, function(val1,val2)
                return math.max(val1,val2)
            end)
        end, ASS.Section.Text)
        return width, unpack(other)
    end

    function LineContents:getLineBounds(noCommit)
        return ASS.LineBounds(self, noCommit)
    end

    function LineContents:getMetrics(includeLineBounds, includeTypeBounds, coerce)
        local metr = {ascent=0, descent=0, internal_leading=0, external_leading=0, height=0, width=0}
        local typeBounds = includeTypeBounds and {0,0,0,0}
        local textCnt = self:getSectionCount(ASS.Section.Text)

        self:callback(function(section, sections, i, j)
            local sectMetr = section:getMetrics(includeTypeBounds, coerce)
            -- combine type bounding boxes
            if includeTypeBounds then
                if j==1 then
                    typeBounds[1], typeBounds[2] = sectMetr.typeBounds[1] or 0, sectMetr.typeBounds[2] or 0
                end
                typeBounds[2] = math.min(typeBounds[2],sectMetr.typeBounds[2] or 0)
                typeBounds[3] = typeBounds[1] + sectMetr.typeBounds.width
                typeBounds[4] = math.max(typeBounds[4],sectMetr.typeBounds[4] or 0)
            end

            -- add all section widths
            metr.width = metr.width + sectMetr.width
            -- get maximum encountered section values for all other metrics (does that make sense?)
            metr.ascent, metr.descent, metr.internal_leading, metr.external_leading, metr.height =
                math.max(sectMetr.ascent, metr.ascent), math.max(sectMetr.descent, metr.descent),
                math.max(sectMetr.internal_leading, metr.internal_leading), math.max(sectMetr.external_leading, metr.external_leading),
                math.max(sectMetr.height, metr.height)

        end, ASS.Section.Text)

        if includeTypeBounds then
            typeBounds.width, typeBounds.height = typeBounds[3]-typeBounds[1], typeBounds[4]-typeBounds[2]
            metr.typeBounds = typeBounds
        end

        if includeLineBounds then
            metr.lineBounds, metr.animated = self:getLineBounds()
        end

        return metr
    end

    function LineContents:getSectionCount(classes)
        if classes then
            local cnt = 0
            self:callback(function(section, _, _, j)
                cnt = j
            end, classes, nil, nil, true)
            return cnt
        else
            local cnt = {}
            self:callback(function(section)
                local cls = table.keys(section.instanceOf)[1]
                cnt[cls] = cnt[cls] and cnt[cls]+1 or 1
            end)
            return cnt, #self.sections
        end
    end

    function LineContents:isAnimated()
        local effTags, line, xres = self:getEffectiveTags(-1, false, true, false), self.line, aegisub.video_size()
        local frameCount = xres and aegisub.frame_from_ms(line.end_time) - aegisub.frame_from_ms(line.start_time)
        local t = effTags.tags

        if xres and frameCount<2 then return false end

        local karaTags = ASS.tagNames.karaoke
        for i=1,karaTags.n do
            if t[karaTags[i]] and t[karaTags[i]].value*t[karaTags[i]].__tag.scale < line.duration then
                -- this is broken right now due to incorrect handling of kara tags in getEffectiveTags
                return true
            end
        end

        if #effTags.transforms>0 or
        (t.move and not t.move.startPos:equal(t.move.endPos) and t.move.startTime<t.move.endTime) or
        (t.move_simple and not t.move_simple.startPos:equal(t.move_simple.endPos)) or
        (t.fade and (t.fade.startDuration>0 and not t.fade.startAlpha:equal(t.fade.midAlpha) or
                     t.fade.endDuration>0 and not t.fade.midAlpha:equal(t.fade.endAlpha))) or
        (t.fade_simple and (t.fade_simple.startDuration>0 and not t.fade_simple.startAlpha:equal(t.fade_simple.midAlpha) or
                            t.fade_simple.endDuration>0 and not t.fade_simple.midAlpha:equal(t.fade_simple.endAlpha))) then
            return true
        end

        return false
    end

    function LineContents:reverse()
        local reversed, textCnt = {}, self:getSectionCount(ASS.Section.Text)
        self:callback(function(section,_,_,j)
            reversed[j*2-1] = ASS.Section.Tag(section:getEffectiveTags(true,true))
            reversed[j*2] = section:reverse()
        end, ASS.Section.Text, nil, nil, nil, true)
        self.sections = reversed
        self:updateRefs()
        return self:cleanTags(4)
    end
    return LineContents
end