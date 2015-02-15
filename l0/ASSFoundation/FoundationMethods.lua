return function(createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local ASS = createASSClass("ASSFoundation")

    function ASS:new()
        self.cache = {}
        return self
    end

    function ASS:getTagNames(ovrNames)
        if type(ovrNames)=="string" then
            if self.tagMap[ovrNames] then return name end
            ovrNames = {ovrNames}
        end

        local tagNames, t = {}, 1
        for i=1,#ovrNames do
            local ovrToTag = self.tagNames[ovrNames[i]]
            if ovrToTag and ovrToTag.n==1 then
                tagNames[t] = ovrToTag[1]
            elseif ovrToTag then
                tagNames, t = table.joinInto(tagNames, ovrToTag)
            elseif self.tagMap[ovrNames[i]] then
                tagNames[t] = ovrNames[i]
            end
            t=t+1
        end

        return tagNames
    end

    function ASS:mapTag(name)
        assertEx(type(name)=="string", "argument #1 must be a string, got a %s.", type(name))
        return assertEx(self.tagMap[name], "can't find tag %s", name)
    end

    function ASS:addStyle(tagList, name, styleRef, sub)
        local style = tagList:getStyleTable(styleRef, name, coerce)
        sub = sub and type(sub)=="userdata" and sub.insert
              or tagList.contentRef.line.parentCollection and tagList.contentRef.line.parentCollection
              or self.cache.lastSub
              or error("no valid subtitles object was supplied or cached.")

        local styles, s = {}
        for i=1,#sub do
            if sub[i].class=="style" then
                styles[sub[i].name], s = sub[i], i
            elseif s then break end
        end

        sub.insert(s+1, style)
        styles[style.name], self.cache.lastStyles = style, styles
    end

    function ASS:createTag(name, ...)
        local tag = self:mapTag(name)
        return tag.type{tagProps=tag.props, ...}
    end

    function ASS:createLine(args)
        local defaults, cnts, ref, newLine = self.defaults.line, args[1], args[2]

        local msg = "argument #2 (ref) must be a Line, LineCollection or %s object or nil; got a %s."
        if type(ref)=="table" then
            if ref.__class == Line then
                ref = ref.parentCollection
            elseif ref.class == self.LineContents then
                ref = ref.line.parentCollection
            end
            assertEx(ref.__class==LineCollection, msg, self.LineContents.typeName, ref.typeName or "table")
        elseif ref~=nil then
            error(string.format(msg, self.LineContents.typeName, type(ref)))
        end

        msg = "argument #1 (contents) must be a Line or %s object, a section or a table of sections, a raw line or line string, or nil; got a %s."
        local msgNoRef = "can only create a Line with a reference to a LineCollection, but none could be found."
        if not cnts then
            assertEx(ref, msgNoRef)
            newLine = Line({}, ref, table.merge(defaults, args))
            newLine:parse()
        elseif type(cnts)=="string" then
            local p, s, num = {}, {cnts:match("^Dialogue: (%d+),(.-),(.-),(.-),(.-),(%d*),(%d*),(%d*),(.-),(.-)$")}, tonumber
            if #s == 0 then
                p = util.copy(defaults)
                p.text = cnts
            else
                p.layer, p.start_time, p.end_time, p.style = num(s[1]), util.timecode2ms(s[2]), util.timecode2ms(s[3]), s[4]
                p.actor, p.margin_l, p.margin_r, p.margin_t, p.effect, p.text = s[5], num(s[6]), num(s[7]), num(s[8]), s[9], s[10]
            end
            newLine = Line({}, assertEx(ref, msgNoRef), table.merge(defaults, p, args))
            self:parse(newLine)
        elseif type(cnts)~="table" then
            error(string.format(msg, self.LineContents.typeName, type(cnts)))
        elseif cnts.__class==Line then
            -- Line objects will be copied and the ASSFoundation stuff committed and reparsed (full copy)
            local text = cnts.ASS and cnts.ASS:getString() or cnts.text
            newLine = Line(cnts, assertEx(ref or cnts.parentCollection, msgNoRef), args)
            newLine.text = text
            self:parse(newLine)
        elseif cnts.class==self.LineContents then
            -- ASSLineContents object will be attached to the new line
            -- line properties other than the text will be taken either from the defaults or the current previous line
            ref = assertEx(ref or cnts.parentCollection, msgNoRef)
            newLine = useLineProps and Line(cnts.line, ref, args) or Line({}, ref, table.merge(defaults, args))
            newLine.ASS, cnts.ASS.line = cnts.ASS, newLine
            newLine:commit()
        else
            -- A new ASSLineContents object is created from the supplied sections and attached to a new Line
            if cnts.class then cnts = {cnts} end
            newLine = Line({}, ref, table.merge(defaults, args))
            for i=1,#cnts do
                -- TODO: move into ASSLineContents:new()
                assertEx(self:instanceOf(cnts[i], self.Section), msg, self.LineContents.typeName, cnts[i].typeName or type(cnts[i]))
                if not ref then
                    local lc = self:getParentLineContents()
                    ref = lc and lc.line.parentCollection
                end
            end
            assertEx(ref, msgNoRef)
            newLine.ASS = self.LineContents(newLine, cnts)
            newLine.ASS:commit()
        end
        newLine:createRaw()
        return newLine
    end

    function ASS:getParentLineContents(obj)
        if not type(obj)=="table" and obj.class then return nil end
        while obj do
            if obj.class == self.LineContents then
                return obj
            end
            obj = obj.parent
        end
        return nil
    end

    function ASS:getScriptInfo(obj)
        if type(obj)=="table" and obj.class then
            local lineContents = self:getParentLineContents(obj)
            return lineContents and lineContents.scriptInfo, lineContents
        end
        obj = default(obj, self.cache.lastSub)
        assertEx(obj and type(obj)=="userdata" and obj.insert,
                 "can't get script info because no valid subtitles object was supplied or cached.")
        self.cache.lastSub = obj
        return util.getScriptInfo(obj)
    end

    function ASS:getTagFromString(str)
        for _,tag in pairs(self.tagMap) do
            if tag.pattern then
                local res = {str:find("^"..tag.pattern)}
                if #res>0 then
                    local start, end_ = table.remove(res,1), table.remove(res,1)
                    return tag.type{raw=res, tagProps=tag.props}, start, end_
                end
            end
        end
        local tagType = self.tagMap[str:sub(1,1)=="\\" and "unknown" or "junk"]
        return self.Tag.Unknown{str, tagProps=tagType.props}, 1, #str
    end

    function ASS:getTagsNamesFromProps(props)
        local names, n = {}, 1
        for name,tag in pairs(self.tagMap) do
            if tag.props then
                local propMatch = true
                for k,v in pairs(props) do
                    if tag.props[k]~=v or tag.props[k]==false and tag.props[k] then
                        propMatch = false
                        break
                    end
                end
                if propMatch then
                    names[n], n = name, n+1
                end
            end
        end
        return names
    end

    function ASS:formatTag(tagRef, ...)
        return self:mapTag(tagRef.__tag.name).format:formatFancy(...)
    end

    function ASS:instanceOf(val, classes, filter, includeCompatible)
        if type(val)~="table" or not val.class then
            return false
        elseif classes==nil then
            return val.class, includeCompatible and table.keys(val.compatible)
        elseif type(classes)~="table" or classes.instanceOf then
            classes = {classes}
        end

        if type(filter)=="table" then
            if filter.instanceOf then
                filter={[filter]=true}
            elseif #filter>0 then
                filter = table.arrayToSet(filter)
            end
        end

        for i=1,#classes do
            if (val.class == classes[i] or includeCompatible and val.compatible[classes[i]]) and (not filter or filter[classes[i]]) then
                return classes[i]
            end
        end
        return false
    end

    function ASS:parse(line)
        line.ASS = self.LineContents(line)
        return line.ASS
    end

    return ASS
end