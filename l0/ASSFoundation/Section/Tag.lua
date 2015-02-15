return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local TagSection = createASSClass("Section.Tag", ASS.Base, {"tags"}, {"table"})
    TagSection.tagMatch = re.compile("\\\\[^\\\\\\(]+(?:\\([^\\)]+\\)[^\\\\]*)?|[^\\\\]+")
    TagSection.getStyleTable = ASS.Section.Text.getStyleTable

    function TagSection:new(tags, transformableOnly, tagSortOrder)
        if ASS:instanceOf(tags,ASS.TagList) then
            tagSortOrder = tagSortOrder or ASS.tagSortOrder
            -- TODO: check if it's a good idea to work with refs instead of copies
            local j=1
            self.tags = {}
            if tags.reset then
                self.tags[1], j = tags.reset, 2
            end

            for i=1,#tagSortOrder do
                local tag = tags.tags[tagSortOrder[i]]
                if tag and (not transformableOnly or tag.__tag.transformable or tag.instanceOf[ASS.Tag.Unknown]) then
                    self.tags[j], j = tag, j+1
                end
            end

            table.joinInto(self.tags, tags.transforms)
        elseif type(tags)=="string" or type(tags)=="table" and #tags==1 and type(tags[1])=="string" then
            if type(tags)=="table" then tags=tags[1] end
            self.tags = {}
            local tagMatch, i = self.tagMatch, 1
            for match in tagMatch:gfind(tags) do
                local tag, start, end_ = ASS:getTagFromString(match)
                if not transformableOnly or tag.__tag.transformable or tag.instanceOf[ASS.Tag.Unknown] then
                    self.tags[i], i = tag, i+1
                    tag.parent = self
                end
                if end_ < #match then   -- comments inside tag sections are read into ASS.Tag.Unknowns
                    local afterStr = match:sub(end_+1)
                    self.tags[i] = ASS:createTag(afterStr:sub(1,1)=="\\" and "unknown" or "junk", afterStr)
                    self.tags[i].parent, i = self, i+1
                end
            end

            if #self.tags==0 and #tags>0 then    -- no tags found but string not empty -> must be a comment section
                return ASS.Section.Comment(tags)
            end
        elseif tags==nil then self.tags={}
        elseif ASS:instanceOf(tags, TagSection) then
            -- does only shallow-copy, good idea?
            self.parent = tags.parent
            local j, otherTags = 1, tags.tags
            self.tags = {}
            for i=1,#otherTags do
                if not transformableOnly or (otherTags[i].__tag.transformable or otherTags[i].instanceOf[ASS.Tag.Unknown]) then
                    self.tags[j] = otherTags[i]
                    self.tags[j].parent, j = self, j+1
                end
            end
        elseif type(tags)=="table" then
            self.tags = {}
            local allTags = ASS.tagNames.all
            for i=1,#tags do
                local tag = tags[i]
                assertEx(allTags[tag.__tag.name or false], "supplied tag %d (a %s with name '%s') is not a supported tag.",
                         i, type(tag)=="table" and tags[i].typeName or type(tag), tag.__tag and tag.__tag.name)
                self.tags[i], tag.parent = tag, self
            end
        else self.tags = self:typeCheck(self:getArgs({tags})) end
        return self
    end

    function TagSection:callback(callback, tagNames, start, end_, relative, reverse)
        local tagSet, prevCnt = {}, #self.tags
        start = default(start,1)
        end_ = default(end_, start>=1 and math.max(prevCnt,1) or -1)
        reverse = relative and start<0 or reverse

        assertEx(math.isInt(start) and math.isInt(end_), "arguments 'start' and 'end' must be integers, got %s and %s.",
                 type(start), type(end_))
        assertEx((start>0)==(end_>0) and start~=0 and end_~=0,
                 "arguments 'start' and 'end' must be either both >0 or both <0, got %d and %d.", start, end_)
        assertEx(start <= end_, "condition 'start' <= 'end' not met, got %d <= %d", start, end_)

        if type(tagNames)=="string" then tagNames={tagNames} end
        if tagNames then
            assertEx(type(tagNames)=="table", "argument #2 must be either a table of strings or a single string, got %s.", type(tagNames))
            for i=1,#tagNames do
                tagSet[tagNames[i]] = true
            end
        end

        local j, numRun, tags, rmCnt = 0, 0, self.tags, 0
        self.toRemove = {}

        if start<0 then
            start, end_ = relative and math.abs(end_) or prevCnt+start+1, relative and math.abs(start) or prevCnt+end_+1
        end

        for i=reverse and prevCnt or 1, reverse and 1 or prevCnt, reverse and -1 or 1 do
            if not tagNames or tagSet[tags[i].__tag.name] then
                j=j+1
                if (relative and j>=start and j<=end_) or (not relative and i>=start and i<=end_) then
                    local result = callback(tags[i], self.tags, i, j, self.toRemove)
                    numRun = numRun+1
                    if result==false then
                        self.toRemove[tags[i]], self.toRemove[rmCnt+1], rmCnt = true, i, rmCnt+1
                        if tags[i].parent == self then tags[i].parent=nil end
                    elseif type(result)~="nil" and result~=true then
                        tags[i] = result
                        tags[i].parent = self
                    end
                end
            end
        end

        -- delay removal of tags until the all contours have been processed
        if rmCnt>0 then
            table.removeFromArray(tags, self.toRemove)
        end
        self.toRemove = {}

        return numRun>0 and numRun or false
    end

    function TagSection:modTags(tagNames, callback, start, end_, relative)
        return self:callback(callback, tagNames, start, end_, relative)
    end

    function TagSection:getTags(tagNames, start, end_, relative)
        local tags = {}
        self:callback(function(tag)
            tags[#tags+1] = tag
        end, tagNames, start, end_, relative)
        return tags
    end

    function TagSection:remove()
        if not self.parent then return self end
        return self.parent:removeSections(self)
    end

    function TagSection:removeTags(tags, start, end_, relative)
        if type(tags)=="number" and relative==nil then    -- called without tags parameter -> delete all tags in range
            tags, start, end_, relative = nil, tags, start, end_
        end

        if #self.tags==0 then
            return {}, 0
        elseif not (tags or start or end_) then
            -- remove all tags if called without parameters
            removed, self.tags = self.tags, {}
            return removed, #removed
        end

        start, end_ = default(start,1), default(end_, start and start<0 and -1 or #self.tags)
        -- wrap single tags and tag objects
        if tags~=nil and (type(tags)~="table" or ASS:instanceOf(tags)) then
            tags = {tags}
        end

        local tagNames, tagObjects, removed, reverse = {}, {}, {}, start<0
        -- build sets
        if tags and #tags>0 then
            for i=1,#tags do
                if ASS:instanceOf(tags[i]) then
                    tagObjects[tags[i]] = true
                elseif type(tags[i]=="string") then
                    tagNames[ASS:mapTag(tags[i]).props.name] = true
                else error(string.format("Error: argument %d to removeTags() must be either a tag name or a tag object, got a %s.", i, type(tags[i]))) end
            end
        end

        if reverse and relative then
            start, end_ = math.abs(end_), math.abs(start)
        end
        -- remove matching tags
        local matched = 0
        self:callback(function(tag)
            if tagNames[tag.__tag.name] or tagObjects[tag] or not tags then
                matched = matched + 1
                if not relative or (matched>=start and matched<=end_) then
                    removed[#removed+1], tag.parent = tag, nil
                    return false
                end
            end
        end, nil, not relative and start or nil, not relative and end_ or nil, false, reverse)

        return removed, matched
    end

    function TagSection:insertTags(tags, index)
        local prevCnt, inserted = #self.tags, {}
        index = default(index,math.max(prevCnt,1))
        assertEx(math.isInt(index) and index~=0,
               "argument #2 (index) must be an integer != 0, got '%s' of type %s.", tostring(index), type(index))

        if type(tags)=="table" then
            if tags.instanceOf[TagSection] then
                tags = tags.tags
            elseif tags.instanceOf[ASS.TagList] then
                tags = TagSection(tags).tags
            elseif tags.instanceOf then tags = {tags} end
        else error("Error: argument 1 (tags) must be one of the following: a tag object, a table of tag objects, an TagSection or an ASSTagList; got a "
                   .. type(tags) .. ".")
        end

        for i=1,#tags do
            local cls = tags[i].class
            if not cls then
                error(string.format("Error: argument %d to insertTags() must be a tag object, got a %s", i, type(tags[i])))
            end

            local tagData = ASS.tagMap[tags[i].__tag.name]
            if not tagData then
                error(string.format("Error: can't insert tag #%d of type %s: no tag with name '%s'.", i, tags[i].typeName, tags[i].__tag.name))
            elseif cls ~= tagData.type then
                error(string.format("Error: can't insert tag #%d with name '%s': expected type was %s, got %s.",
                                    i, tags[i].__tag.name, tagData.type.typeName, tags[i].typeName)
                )
            end

            local insertIdx = index<0 and prevCnt+index+i or index+i-1
            table.insert(self.tags, insertIdx, tags[i])
            tags[i].parent, tags[i].deleted = self, false
            inserted[i] = self.tags[insertIdx]
        end
        return #inserted>1 and inserted or inserted[1]
    end

    function TagSection:insertDefaultTags(tagNames, index)
        local defaultTags = self.parent:getDefaultTags():getTags(tagNames)
        return self:insertTags(defaultTags, index)
    end

    function TagSection:getString(coerce)
        local tagStrings = {}
        self:callback(function(tag, _, i)
            tagStrings[i] = tag:getTagString(self, coerce)
        end)
        return table.concat(tagStrings)
    end

    function TagSection:getEffectiveTags(includeDefault, includePrevious, copyTags)   -- TODO: properly handle transforms, include forward sections for global tags
        includePrevious, copyTags = default(includePrevious, true), true
        -- previous and default tag lists
        local effTags
        if includeDefault then
            effTags = self.parent:getDefaultTags(nil, copyTags)
        end
        if includePrevious and self.prevSection then
            local prevTagList = self.prevSection:getEffectiveTags(false, true, copyTags)
            effTags = includeDefault and effTags:merge(prevTagList, false, false, true) or prevTagList
            includeDefault = false
        end
        -- tag list of this section
        local tagList = copyTags and ASS.TagList(self):copy() or ASS.TagList(self)
        return effTags and effTags:merge(tagList, false, nil, includeDefault) or tagList
    end

    return TagSection
end