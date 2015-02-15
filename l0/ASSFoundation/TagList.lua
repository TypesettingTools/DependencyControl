return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local TagList = createASSClass("TagList", ASS.Base, {"tags", "transforms" ,"reset", "startTime", "endTime", "accel"},
                                {"table", "table", ASS.String, ASS.Time, ASS.Time, ASS.Number})

    function TagList:new(tags, contentRef)
        if ASS:instanceOf(tags, ASS.Section.Tag) then
            self.tags, self.transforms, self.contentRef = {}, {}, tags.parent
            local trIdx, transforms, ovrTransTags, transTags = 1, {}, {}
            local seenVectClip, childAlphaNames = false, ASS.tagNames.childAlpha

            tags:callback(function(tag)
                local props = tag.__tag

                -- Discard all previous non-global tags when a reset is encountered (including all transformed tags)
                -- Vectorial clips are not "global" but can't be reset
                if props.name == "reset" then
                    self.tags, self.reset = self:getGlobal(true), tag

                    for i=1,#transforms do
                        local keep = false
                        transforms[i].tags:callback(function(tag)
                            if tag.instanceOf[ASS.Tag.ClipRect] then
                                keep = true
                            else return false end
                        end)
                        if not keep then transforms[i] = nil end
                    end

                -- Transforms are stored in a separate table because there can be more than one.
                elseif tag.instanceOf[ASS.Tag.Transform] then
                    transforms[trIdx] = ASS.Tag.Transform{tag, transformableOnly=true}   -- we need a shallow copy of the transform to filter
                    transTags, trIdx = transforms[trIdx].tags.tags, trIdx+1

                -- Discard all except the first instance of global tags.
                -- This expects all global tags to be non-transformable which is true for ASSv4+
                -- Since there can be only one vectorial clip or iclip at a time, only keep the first one
                elseif not (self.tags[props.name] and props.global)
                and not (seenVectClip and tag.instanceOf[ASS.Tag.ClipVect]) then
                    self.tags[props.name] = tag
                    if tag.__tag.transformable then
                        -- When the list is converted back into an ASSTagSection, the transforms are written to its end,
                        -- so we have to make sure transformed tags are not overridden afterwards:
                        -- If a transformable tag is encountered, its entry in the overridden transforms list
                        -- is set to the nummber of the last transform(+1), so the tag can be purged from all previous transforms.
                        ovrTransTags[tag.__tag.name] = trIdx
                    elseif tag.instanceOf[ASS.Tag.ClipVect]  then
                        seenVectClip = true
                    end
                    if tag.__tag.masterAlpha then
                        for i=1,#childAlphaNames do
                            self.tags[childAlphaNames[i]] = nil
                        end
                    end
                end
            end)

            -- filter tags by overridden transform list, keep transforms that have still tags left at the end
            local t=1
            for i=1,trIdx-1 do
                if transforms[i] then
                    local transTagCnt = 0
                    transforms[i].tags:callback(function(tag)
                        local ovrEnd = ovrTransTags[tag.__tag.name] or 0
                        -- drop all overridden transforms
                        if ovrEnd>i then
                            return false
                        else transTagCnt = transTagCnt+1 end
                    end)
                    -- write final transforms table
                    if transTagCnt>0 then
                        self.transforms[t], t = transforms[i], t+1
                    end
                end
            end

        elseif ASS:instanceOf(tags, TagList) then
            self.tags, self.reset, self.transforms = util.copy(tags.tags), tags.reset, util.copy(tags.transforms)
            self.contentRef = tags.contentRef
        elseif tags==nil then
            self.tags, self.transforms = {}, {}
        else error(string.format("Error: an %s can only be constructed from an %s or %s; got a %s.",
                                  TagList.typeName, ASS.Section.Tag.typeName, TagList.typeName,
                                  ASS:instanceOf(tags) and tags.typeName or type(tags))
             )
        end
        self.contentRef = contentRef or self.contentRef
        return self
    end

    function TagList:get()
        local flatTagList = {}
        for name,tag in pairs(self.tags) do
            flatTagList[name] = tag:get()
        end
        return flatTagList
    end

    function TagList:isTagTransformed(tagName)
        local set = {}
        for i=1,#self.transforms do
            for j=1,#self.transforms[i].tags.tags do
                set[self.transforms[i].tags.tags[j].__tag.name] = true
            end
        end
        return tagName and set[tagName] or set
    end

    function TagList:merge(tagLists, copyTags, returnOnly, overrideGlobalTags, expandResets)
        copyTags = default(copyTags, true)
        if ASS:instanceOf(tagLists, TagList) then
            tagLists = {tagLists}
        end

        local merged, ovrTransTags, resetIdx = TagList(self), {}, 0
        local seenTransform, seenVectClip = #self.transforms>0, self.clip_vect or self.iclip_vect
        local childAlphaNames = ASS.tagNames.childAlpha

        if expandResets and self.reset then
            local expReset = merged.contentRef:getDefaultTags(merged.reset)
            merged.tags = merged:getDefaultTags(merged.reset):merge(merged.tags, false)
        end

        for i=1,#tagLists do
            assertEx(ASS:instanceOf(tagLists[i],TagList),
                     "can only merge %s objects, got a %s for argument #%d.", TagList.typeName, type(tagLists[i]), i)

            if tagLists[i].reset then
                if expandResets then
                    local expReset = tagLists[i].contentRef:getDefaultTags(tagLists[i].reset)
                    merged.tags = overrideGlobalTags and expReset or expReset:merge(merged:getGlobal(true),false)
                else
                    -- discard all previous non-global tags when a reset is encountered
                    merged.tags, merged.reset = merged:getGlobal(true), tagLists[i].reset
                end

                resetIdx = i
            end

            seenTransform = seenTransform or #tagLists[i].transforms>0

            for name,tag in pairs(tagLists[i].tags) do
                -- discard all except the first instance of global tags
                -- also discard all vectorial clips if one was already seen
                if overrideGlobalTags or not (merged.tags[name] and tag.__tag.global)
                and not (seenVectClip and tag.instanceOf[ASS.Tag.ClipVect]) then
                    -- when overriding tags, make sure vect. iclips also overwrite vect. clips and vice versa
                    if overrideGlobalTags then
                        merged.tags.clip_vect, merged.tags.iclip_vect = nil, nil
                    end
                    merged.tags[name] = tag
                    -- mark transformable tags in previous transform lists as overridden
                    if seenTransform and tag.__tag.transformable then
                        ovrTransTags[tag.__tag.name] = i
                    end
                    if tag.__tag.masterAlpha then
                        for i=1,#childAlphaNames do
                            self.tags[childAlphaNames[i]] = nil
                        end
                    end
                end
            end
        end

        merged.transforms = {}
        if seenTransform then
            local t=1
            for i=0,#tagLists do
                local transforms = i==0 and self.transforms or tagLists[i].transforms
                for j=1,#transforms do
                    local transform = i==0 and transforms[j] or ASS.Tag.Transform{transforms[j]}
                    local transTagCnt = 0

                    transform.tags:callback(function(tag)
                        local ovrEnd = ovrTransTags[tag.__tag.name] or 0
                        -- remove transforms overwritten by resets or the override table
                        if resetIdx>i and not tag.instanceOf[ASS.Tag.ClipRect] or ovrEnd>i then
                            return false
                        else transTagCnt = transTagCnt+1 end
                    end)

                    -- fill final transforms table
                    if transTagCnt > 0 then
                        merged.transforms[t], t = transform, t+1
                    end
                end
            end
        end

        if copyTags then merged = merged:copy() end
        if not returnOnly then
            self.tags, self.reset, self.transforms = merged.tags, merged.reset, merged.transforms
            return self
        else return merged end
    end

    function TagList:diff(other, returnOnly, ignoreGlobalState) -- returnOnly note: only provided because copying the tag list before diffing may be much slower
        assertEx(ASS:instanceOf(other,TagList), "can only diff %s objects, got a %s.", TagList.typeName, type(other))

        local diff, ownReset = TagList(nil, self.contentRef), self.reset

        if #other.tags == 0 and self.reset and (
            other.reset and self.reset.value == other.reset.value
            or not other.reset and (self.reset.value == "" or self.reset.value == other.contentRef:getStyleRef().name)
        ) then
            ownReset, self.reset = nil, returnOnly and self.reset or nil
        end

        local defaults = ownReset and self.contentRef:getDefaultTags(ownReset)
        local otherReset = other.reset and other.contentRef:getDefaultTags(other.reset)
        local otherTransSet = other:isTagTransformed()

        for name,tag in pairs(self.tags) do
            local global = tag.__tag.global and not ignoreGlobalState

            -- if this tag list contains a reset, we need to compare its local tags to the default values set by the reset
            -- instead of to the values of the other tag list
            local ref = (ownReset and not global) and defaults or other

            -- Since global tags can't be overwritten, only treat global tags that are not
            -- present in the other tag list as different.
            -- There can be only vector (i)clip at the time, so treat any we encounter in this list only as different
            -- when there are neither in the other list.
            if global and not other.tags[name]
                      and not (tag.instanceOf[ASS.Tag.ClipVect] and (other.tags.clip_vect or other.tags.iclip_vect))
            -- all local tags transformed in the previous section will change state (no matter the tag values) when used in this section,
            -- unless this section begins with a reset, in which case only rectangular clips are kept
            or not (global or ownReset and not tag.instanceOf[ASS.Tag.ClipRect]) and otherTransSet[name]
            -- check local tags for equality in reference list
            or not (global or tag:equal(ref.tags[name]) or otherReset and tag:equal(otherReset.tags[name])) then
                if returnOnly then diff.tags[name] = tag end

            elseif not returnOnly then
                self.tags[name] = nil
            end
        end
        diff.reset = ownReset
        -- transforms can't be deduplicated so all of them will be kept in the diff
        diff.transforms = self.transforms
        return returnOnly and diff or self
    end

    function TagList:getStyleTable(styleRef, name, coerce)
        assertEx(type(styleRef)=="table" and styleRef.class=="style",
                 "argument #1 must be a style table, got a %s.", type(styleRef))
        local function color(num)
            local a, c = "alpha"..tostring(num), "color"..tostring(num)
            local alpha, color = tag(a), {tag(c)}
            local str = (alpha and string.format("&H%02X", alpha) or styleRef[c]:sub(1,4)) ..
                        (#color==3 and string.format("%02X%02X%02X&", unpack(color)) or styleRef[c]:sub(5))
            return str
        end
        function tag(name,bool)
            if self.tags[name] then
                local vals = {self.tags[name]:getTagParams(coerce)}
                if bool then
                    return vals[1]>0
                else return unpack(vals) end
            end
        end

        local sTbl = {
            name = name or styleRef.name,
            id = util.uuid(),

            align=tag("align"), angle=tag("angle"), bold=tag("bold",true),
            color1=color(1), color2=color(2), color3=color(3), color4=color(4),
            encoding=tag("encoding"), fontname=tag("fontname"), fontsize=tag("fontsize"),
            italic=tag("italic",true), outline=tag("outline"), underline=tag("underline",true),
            scale_x=tag("scale_x"), scale_y=tag("scale_y"), shadow=tag("shadow"),
            spacing=tag("spacing"), strikeout=tag("strikeout",true)
        }
        sTbl = table.merge(styleRef,sTbl)

        sTbl.raw = string.formatFancy("Style: %s,%s,%N,%s,%s,%s,%s,%B,%B,%B,%B,%N,%N,%N,%N,%d,%N,%N,%d,%d,%d,%d,%d",
                   sTbl.name, sTbl.fontname, sTbl.fontsize, sTbl.color1, sTbl.color2, sTbl.color3, sTbl.color4,
                   sTbl.bold, sTbl.italic, sTbl.underline, sTbl.strikeout, sTbl.scale_x, sTbl.scale_y,
                   sTbl.spacing, sTbl.angle, sTbl.borderstyle, sTbl.outline, sTbl.shadow, sTbl.align,
                   sTbl.margin_l, sTbl.margin_r, sTbl.margin_t, sTbl.encoding
        )
        return sTbl
    end

    function TagList:filterTags(tagNames, tagProps, returnOnly, inverseNameMatch)
        if type(tagNames)=="string" then tagNames={tagNames} end
        assertEx(not tagNames or type(tagNames)=="table",
                 "argument #1 must be either a single or a table of tag names, got a %s.", type(tagNames))

        local filtered, removed = TagList(nil, self.contentRef), TagList(nil, self.contentRef)
        local selected, transNames, retTrans = {}, ASS.tagNames[ASS.Tag.Transform]
        local propCnt = tagProps and table.length(tagProps) or 0

        if not tagNames and not (tagProps or #tagProps==0) then
            return returnOnly and self:copy() or self
        elseif not tagNames then
            tagNames = ASS.tagNames.all
        elseif #tagNames==0 then
            return filtered
        elseif inverseNameMatch then
            tagNames = table.diff(tagNames, ASS.tagNames.all)
        end

        local target
        for i=1,#tagNames do
            local name, propMatch = tagNames[i], true
            local selfTag = name=="reset" and self.reset or self.tags[name]
            assertEx(type(name)=="string", "invalid tag name #%d '(%s)'. expected a string, got a %s",
                     i, tostring(name), type(name))

            if propCnt~=0 and selfTag then
                local _, propMatchCnt = table.intersect(tagProps, self.tags[name].__tag)
                propMatch = propMatchCnt == propCnt
            end

            target = propMatch and selfTag and filtered or removed

            if name == "reset" then
                target.reset = selfTag
            elseif transNames[name] then
                target.retTrans = true         -- TODO: filter transforms by type
            elseif self.tags[name] then
                target.tags[name] = selfTag
            end
        end

        target = filtered.retTrans and filtered or removed
        target.transforms = returnOnly and util.copy(self.transforms) or self.transforms

        if returnOnly then
            return filtered, removed
        end

        self.tags, self.reset, self.transforms = filtered.tags, filtered.reset, filtered.transforms
        return self, removed
    end

    function TagList:isEmpty()
        return table.length(self.tags)<1 and not self.reset and #self.transforms==0
    end

    function TagList:getGlobal(includeRectClips)
        local global = {}
        for name,tag in pairs(self.tags) do
            global[name] = (includeRectClips and tag.__tag.globalOrRectClip or tag.__tag.global) and tag or nil
        end
        return global
    end
    return TagList
end