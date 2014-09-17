local re = require("aegisub.re")
local util = require("aegisub.util")
local l0Common = require("l0.Common")
local YUtils = require("YUtils")
local Line = require("a-mo.Line")
local Log = require("a-mo.Log")

function createASSClass(typeName,baseClass,order,types,tagProps)
  local cls, baseClass = {}, baseClass or {}
  for key, val in pairs(baseClass) do
    cls[key] = val
  end

  cls.__index = cls
  cls.instanceOf = {[cls] = true}
  cls.typeName = typeName
  cls.__meta__ = { 
       order = order,
       types = types
  }
  cls.__defProps = table.merge(cls.__defProps or {},tagProps or {})
  cls.baseClass=baseClass

  setmetatable(cls, {
    __call = function (cls, ...)
        local self = setmetatable({__tag = util.copy(cls.__defProps)}, cls)
        self = self:new(...)
        return self
    end})
  return cls
end

--------------------- Base Class ---------------------

ASSBase = createASSClass("ASSBase")
function ASSBase:checkType(type_, ...) --TODO: get rid of
    for _,val in ipairs({...}) do
        result = (type_=="integer" and math.isInt(val)) or type(val)==type_
        assert(result, string.format("Error: %s must be a %s, got %s.\n",self.typeName,type_,type(val)))
    end
end

function ASSBase:checkPositive(...)
    self:checkType("number",...)
    for _,val in ipairs({...}) do
        assert(val >= 0, string.format("Error: %s tagProps do not permit numbers < 0, got %d.\n", self.typeName,val))
    end
end

function ASSBase:checkRange(min,max,...)
    self:checkType("number",...)
    for _,val in ipairs({...}) do
        assert(val >= min and val <= max, string.format("Error: %s must be in range %d-%d, got %d.\n",self.typeName,min,max,val))
    end
end

function ASSBase:CoerceNumber(num, default)
    num = tonumber(num)
    if not num then num=default or 0 end
    if self.__tag.positive then num=math.max(num,0) end
    if self.__tag.range then num=util.clamp(num,self.__tag.range[1], self.__tag.range[2]) end
    return num 
end

function ASSBase:getArgs(args, default, coerce, ...)
    assert(type(args)=="table", "Error: first argument to getArgs must be a table of packed arguments, got " .. type(args) ..".\n")
    -- check if first arg is a compatible ASSClass and dump into args 
    if #args == 1 and type(args[1]) == "table" and args[1].typeName then
        local res, selfClasses = false, {}
        for key,val in pairs(self.instanceOf) do
            if val then table.insert(selfClasses,key) end
        end
        for _,class in ipairs(table.join(table.pack(...),selfClasses)) do
            res = args[1].instanceOf[class] and true or res
        end
        assert(res, string.format("%s does not accept instances of class %s as argument.\n", self.typeName, args[1].typeName))
        args=table.pack(args[1]:get())
    end

    local valTypes, j, outArgs = self.__meta__.types, 1, {}
    for i,valName in ipairs(self.__meta__.order) do
        -- write defaults
        args[j] = type(args[j])=="nil" and default or args[j]

        if ASS.instanceOf(valTypes[i]) then
            local subCnt = #valTypes[i].__meta__.order
            outArgs = table.join(outArgs, {valTypes[i]:getArgs(table.sliceArray(args,j,j+subCnt-1), default, coerce)})
            j=j+subCnt-1

        elseif coerce then
            local tagProps = self.__tag or self.__defProps
            local map = {
                number = function()
                    if type(args[j])=="boolean" then return args[j] and 1 or 0
                    else return tonumber(args[j],tagProps.base or 10)*(tagProps.scale or 1) end
                end,
                string = function() return tostring(args[j]) end,
                boolean = function() return not (args[j] == 0 or not args[j]) end
            }
            table.insert(outArgs, args[j]~= nil and map[valTypes[i]]() or nil)
        else table.insert(outArgs, args[j]) end
        j=j+1
    end
    --self:typeCheck(unpack(outArgs))
    return unpack(outArgs)
end

function ASSBase:copy()
    local newObj, meta = {}, getmetatable(self)
    setmetatable(newObj, meta)
    for key,val in pairs(self) do
        if key=="__tag" or not meta or (meta and table.find(self.__meta__.order,key)) then   -- only deep copy registered members of the object
            if ASS.instanceOf(val) then
                newObj[key] = val:copy()
            elseif type(val)=="table" then
                newObj[key]=ASSBase.copy(val)
            else newObj[key]=val end
        end
    end
    return newObj
end

function ASSBase:typeCheck(...)
    local valTypes, j, args = self.__meta__.types, 1, {...}
    --assert(#valNames >= #args, string.format("Error: too many arguments. Expected %d, got %d.\n",#valNames,#args))
    for i,valName in ipairs(self.__meta__.order) do
        if ASS.instanceOf(valTypes[i]) then
            if ASS.instanceOf(args[j]) then
                self[valName]:typeCheck(args[j])
                j=j+1
            else
                local subCnt = #valTypes[i].__meta__.order
                valTypes[i]:typeCheck(unpack(table.sliceArray(args,j,j+subCnt-1)))
                j=j+subCnt
            end
        else    
            assert(type(args[i])==valTypes[i] or type(args[i])=="nil" or valTypes[i]=="nil",
                   string.format("Error: bad type for argument %d (%s). Expected %s, got %s.\n", i,valName,type(self[valName]),type(args[i]))) 
        end
    end
    return unpack(args)
end

function ASSBase:get()
    local vals = {}
    for _,valName in ipairs(self.__meta__.order) do
        if ASS.instanceOf(self[valName]) then
            for _,cval in pairs({self[valName]:get()}) do vals[#vals+1]=cval end
        else 
            vals[#vals+1] = self[valName]
        end
    end
    return unpack(vals)
end

--- TODO: implement working alternative 
--[[
function ASSBase:remove(returnCopy)
    local copy = returnCopy and ASSBase:copy() or true
    self = nil
    return copy
end
]]--

--------------------- Container Classes ---------------------

ASSLineContents = createASSClass("ASSLineContents", ASSBase, {"sections"}, {"table"})
function ASSLineContents:new(line,sections)
    sections = self:getArgs({sections})
    assert(line and line.text, string.format("Error: argument 1 to %s() must be a Line or %s object, got %s.\n", self.typeName, self.typeName, type(line)))
    if not sections then
        sections = {}
        local i, ovrStart, ovrEnd = 1
        while i<#line.text do
            ovrStart, ovrEnd = line.text:find("{.-}",i)
            if ovrStart then
                if ovrStart>i then table.insert(sections, ASSLineTextSection(line.text:sub(i,ovrStart-1))) end
                table.insert(sections, ASSLineTagSection(line.text:sub(ovrStart+1,ovrEnd-1)))
                i = ovrEnd +1
            else
                table.insert(sections,ASSLineTextSection(line.text:sub(i)))
                break
            end
        end
    end
    self.line, self.sections = line, self:typeCheck(sections)
    self:updateRefs()
    return self
end

function ASSLineContents:updateRefs(prevCnt)
    if prevCnt~=#self.sections then
        for i,section in ipairs(self.sections) do
            section.prevSection = self.sections[i-1]
            section.parent = self
        end
        return true
    else return false end
end

function ASSLineContents:getString(coerce, noTags, noText, noCmts)
    local str = ""
    for i,section in ipairs(self.sections) do
        if ASS.instanceOf(section, ASSLineTextSection) and not noText then
            str = str .. section:getString()
        elseif ASS.instanceOf(section, {not noTags and ASSLineTagSection, not noCmts and ASSLineCommentSection}) then
            str =  string.format("%s{%s}",str,section:getString())
        else 
            eval(coerce, string.format("Error: %s section #%d is not a %d or %d.\n", self.typeName, i, ASSLineTextSection.typeName, ASSLineTagSection.typeName)) 
        end
    end
    return str
end

function ASSLineContents:get(noTags, noText, noCmts, start, end_, relative)
    local result, j = {}, 1
    self:callback(function(section,sections,i)
        table.insert(result, section:copy())
    end, noTags, noText, noCmts, start, end_, relative)
    return result
end

function ASSLineContents:callback(callback, noTags, noText, noCmts, start, end_, relative)
    start, end_ = default(start,1), default(end_,#self.sections)
    local prevCnt, j = #self.sections, 1
    for i,section in ipairs(self.sections) do
        if ASS.instanceOf(section, {not noText and ASSLineTextSection, not noTags and ASSLineTagSection, not noCmts and ASSLineCommentSection}) and
        (relative and j>=start and j<=end_ or i>=start and i<=end_) then
            local result, hasRun = callback(section,self.sections,i), true
            if result==false then
                self.sections[i]=nil
            elseif type(result)~="nil" and result~=true then
                self.sections[i] = result
                prevCnt=-1
            end
            j=j+1
        end
    end
    self.sections = table.trimArray(self.sections)
    self:updateRefs(prevCnt)
    return j>1 and j-1 or false
end

function ASSLineContents:insertSections(sections,index)
    index = index or #self.sections+1
    if type(sections)~="table" or sections.instanceOf then
        sections = {sections}
    end
    for i,section in ipairs(sections) do
        assert(ASS.instanceOf(section,{ASSLineTextSection, ASSLineTagSection, ASSLineCommentSection}),
              string.format("Error: can only insert sections of type %s, %s or %s, got %s.\n", 
              ASSLineTextSection.typeName, ASSLineTagSection.typeName, ASSLineCommentSection.typeName, type(sections))
        )
        table.insert(self.sections, index+i-1, section)
    end
    self:updateRefs()
end

function ASSLineContents:removeSections(start, end_)
    start = start or #self.sections
    end_ = end_ or start
    for i=start,end_ do
        table.remove(self.sections,i)
    end
    self:updateRefs()
end

function ASSLineContents:modTags(callback, tagTypes, start, end_, relative)
    local j = 0
    self:callback(function(section)
        if not relative or end_>j then
            j = j + (section:modTags(callback, tagTypes, relative and math.max(start-j,1), relative and end_-j) or 0)
        end
    end, true, false, true, not relative and start, not relative and end_)

    return j>0 and j or false
end

function ASSLineContents:stripTags()
    self:callback(function(section,sections,i)
        return false
    end, false, true, true)
    return self
end

function ASSLineContents:stripText()
    self:callback(function(section,sections,i)
        return false
    end, true, false, true)
    return self
end

function ASSLineContents:stripComments()
    self:callback(function(section,sections,i)
        return false
    end, true, true, false)
    return self
end

function ASSLineContents:commit(line)
    line = line or self.line
    line.text = self:getString()
    return line.text
end

function ASSLineContents:cleanTags(level, mergeSect)   -- TODO: optimize it, make it work properly for transforms
    mergeSect, level = default(mergeSect,true), default(level,2)
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
        end, false, true, true)
    end

    -- 1: dedup tags locally, 2: dedup tags globally
    -- 3: remove tags matching style default and not changing state, end: remove empty sections
    if level>=1 then
        self:callback(function(section,sections,i)
            local tagList = section:getEffectiveTags(false,false)
            if level>=2 then
                local tagListPrev = section.prevSection and section.prevSection:getEffectiveTags()
                if tagListPrev then tagList:diff(tagListPrev) end
            end
            if level>=3 then
                local startStates = section.prevSection and section.prevSection:getEffectiveTags(true)
                                        or self:getStyleDefaultTags()
                tagList:diff(startStates)
            end
            return table.length(tagList.tags)>0 and ASSLineTagSection(tagList) or false
        end, false, true, true)
    end
end

function ASSLineContents:splitAtTags(cleanLevel)
    cleanLevel = default(cleanLevel,3)
    local splitLines = {}
    self:callback(function(section,sections,i)
        local splitLine = Line(self.line, self.line.parentCollection)
        splitLine.ASS = ASSLineContents(splitLine, table.insert(self:get(false,true,true,0,i),section))
        splitLine.ASS:cleanTags(cleanLevel)
        splitLine.ASS:commit()
        table.insert(splitLines,splitLine)
    end, true, false, true)
    return splitLines
end

function ASSLineContents:splitAtIntervals(callback, cleanLevel)
    cleanLevel = default(cleanLevel,3)
    if type(callback)=="number" then
        local step=callback
        callback = function(idx,len)
            return idx+step
        end
    else assert(type(callback)=="function", "Error: first argument to splitAtIntervals must be either a number or a callback function.\n") end
    
    local len, idx, sectEndIdx, nextIdx, lastI = #self:copy():stripTags():getString(), 1, 0, 0
    local splitLines = {}

    self:callback(function(section,sections,i)
        local sectStartIdx, text, off = sectEndIdx+1, section.value, sectEndIdx
        sectEndIdx = sectStartIdx+#section.value-1

        -- process unfinished line carried over from previous section
        if nextIdx > idx then
            -- carried over part may span over more than this entire section
            local skip = nextIdx>sectEndIdx+1
            idx = skip and sectEndIdx+1 or nextIdx 
            local addTextSection = skip and section:copy() or ASSLineTextSection(text:sub(1,nextIdx-off-1))
            local addSections, lastContents = table.insert(self:get(false,true,true,lastI+1,i), addTextSection), splitLines[#splitLines].ASS
            lastContents:insertSections(addSections)
        end
            
        while idx <= sectEndIdx do
            nextIdx = math.ceil(callback(idx,len))
            assert(nextIdx>idx, "Error: callback function for splitAtIntervals must always return an index greater than the last index.")
            -- create a new line
            local splitLine = Line(self.line, self.line.parentCollection)
            splitLine.ASS = ASSLineContents(splitLine, self:get(false,true,true,0,i))
            splitLine.ASS:insertSections(ASSLineTextSection(text:sub(idx-off,nextIdx-off-1)))
            table.insert(splitLines,splitLine)        
            -- check if this section is long enough to fill the new line
            idx = sectEndIdx>=nextIdx-1 and nextIdx or sectEndIdx+1
        end
        lastI = i
    end, true, false, true)
    
    for _,line in ipairs(splitLines) do
        line.ASS:cleanTags(cleanLevel)
        line.ASS:commit()
    end

    return splitLines
end

function ASSLineContents:getStyleDefaultTags()    -- TODO: cache
    local function styleRef(tag)
        local style = self.line.styleRef
        if tag:find("alpha") then 
            return {style[tag:gsub("alpha", "color")]:sub(3,4)}
        elseif tag:find("color") then
            return {style[tag]:sub(5,6),style[tag]:sub(7,8),style[tag]:sub(9,10)}
        else return {style[tag]} end
    end

    local scriptInfo = util.getScriptInfo(self.line.parentCollection.sub)
    local resX, resY = scriptInfo.PlayResX, scriptInfo.PlayResY
    self.line:extraMetrics()

    local styleDefaults = {
        scale_x = ASS:__createTag("scale_x",styleRef("scale_x")),
        scale_y = ASS:__createTag("scale_y", styleRef("scale_y")),
        align = ASS:__createTag("align", styleRef("align")),
        angle = ASS:__createTag("angle", styleRef("angle")),
        outline = ASS:__createTag("outline", styleRef("outline")),
        outline_x = ASS:__createTag("outline_x", styleRef("outline")),
        outline_y = ASS:__createTag("outline_y", styleRef("outline")),
        shadow = ASS:__createTag("shadow", styleRef("shadow")),
        shadow_x = ASS:__createTag("shadow_x", styleRef("shadow")),
        shadow_y = ASS:__createTag("shadow_y", styleRef("shadow")),
        alpha1 = ASS:__createTag("alpha1", styleRef("alpha1")),
        alpha2 = ASS:__createTag("alpha2", styleRef("alpha2")),
        alpha3 = ASS:__createTag("alpha3", styleRef("alpha3")),
        alpha4 = ASS:__createTag("alpha4", styleRef("alpha4")),
        color1 = ASS:__createTag("color1", styleRef("color1")),
        color2 = ASS:__createTag("color2", styleRef("color2")),
        color3 = ASS:__createTag("color3", styleRef("color3")),
        color4 = ASS:__createTag("color4", styleRef("color4")),
        clip_vect = ASS:__createTag("clip_vect", {string.format("m 0 0 l %s 0 %s %s 0 %s 0 0",resX,resX,resY,resY)}),
        iclip_vect = ASS:__createTag("iclip_vect", {"m 0 0 l 0 0 0 0 0 0 0 0"}),
        clip_rect = ASS:__createTag("clip_rect", {0,0,resX,resY}),
        iclip_rect = ASS:__createTag("iclip_rect", {0,0,0,0}),
        bold = ASS:__createTag("bold", styleRef("bold")),
        italic = ASS:__createTag("italic", styleRef("italic")),
        underline = ASS:__createTag("underline", styleRef("underline")),
        strikeout = ASS:__createTag("strikeout", styleRef("strikeout")),
        spacing = ASS:__createTag("spacing", styleRef("spacing")),
        fontsize = ASS:__createTag("fontsize", styleRef("fontsize")),
        fontname = ASS:__createTag("fontname", styleRef("fontname")),
        position = ASS:__createTag("position", {self.line:getDefaultPosition()}),
        move_simple = ASS:__createTag("move_simple", {self.line.xPosition, self.line.yPosition, self.line.xPosition, self.line.yPosition}),
        move = ASS:__createTag("move", {self.line.xPosition, self.line.yPosition, self.line.xPosition, self.line.yPosition}),
        org = ASS:__createTag("org", {self.line.xPosition, self.line.yPosition}),
    }

    for name,tag in pairs(ASS.tagMap) do
        if tag.default then styleDefaults[name] = tag.type(tag.default, tag.props) end
    end

    return ASSTagList(styleDefaults)
end

function ASSLineContents:getTextExtents(coerce)   -- TODO: account for linebreaks
    local width, other = 0, {0,0,0}
    self:callback(function(section)
        local extents = {section:getTextExtents(coerce)}
        width = width + table.remove(extents,1)
        table.process(other, extents, function(val1,val2)
            return math.max(val1,val2)
        end)
    end, true, false, true)
    return width, unpack(other)
end

ASSLineTextSection = createASSClass("ASSLineTextSection", ASSBase, {"value"}, {"string"})
function ASSLineTextSection:new(value)
    self.value = self:typeCheck(self:getArgs({value},"",true))
    return self
end

function ASSLineTextSection:getString(coerce)
    if coerce then return tostring(self.value)
    else return self:typeCheck(self.value) end
end

function ASSLineTextSection:getEffectiveTags(includeDefault,includePrevious)
    includePrevious = default(includePrevious, true)
    -- previous and default tag lists
    local effTags
    if includeDefault then
        effTags = self.parent:getStyleDefaultTags()
    end
    if includePrevious and self.prevSection then
        local prevTagList = self.prevSection:getEffectiveTags()
        effTags = includeDefault and effTags:merge(prevTagList) or prevTagList
    end
    return effTags or ASSTagList()
end

function ASSLineTextSection:getStyleTable(name, coerce)
    return self:getEffectiveTags():getStyleTable(self.parent.line.styleRef, name, coerce)
end

function ASSLineTextSection:getTextExtents(coerce)
    return aegisub.text_extents(self:getStyleTable(nil,coerce),self.value)
end

ASSLineCommentSection = createASSClass("ASSLineCommentSection", ASSLineTextSection, {"value"}, {"string"})

ASSLineTagSection = createASSClass("ASSLineTagSection", ASSBase, {"tags"}, {"table"})
function ASSLineTagSection:new(tags)
    if ASS.instanceOf(tags,ASSTagList) then
        self.tags = table.values(tags:copy().tags)
    elseif type(tags)=="string" then
        self.tags = {}
        for tag in re.gfind(tags, "\\\\[^\\\\\\(]+(?:\\([^\\)]+\\))?") do
            table.insert(self.tags, ASS:getTagFromString(tag))
        end
        if #self.tags==0 and #tags>0 then    -- no tags found but string not empty -> must be a comment section
            return ASSLineCommentSection(tags)
        end
    elseif tags==nil then self.tags={}
    else self.tags = self:typeCheck(self:getArgs({tags})) end
    return self
end

function ASSLineTagSection:callback(callback, tagTypes, start, end_, relative)
    start, end_ = default(start,1), default(end_,#self.tags)
    local tagSet = {}
    if type(tagTypes)=="string" then tagTypes={tagTypes} end
    if tagTypes then
        assert(type(tagTypes)=="table", "Error: argument 2 to callback must be either a table of strings or a single string, got " .. type(tagTypes))
        for _,tagType in pairs(tagTypes) do
            tagSet[ASS.getInternalTagName()] = true
        end
    end

    local j = 1
    for i,tag in ipairs(self.tags) do
        if (not tagTypes or tagSet[tag.__tag.name]) and (relative and j>=start and j<=end_ or i>=start and i<=end_) then
            local result, hasRun = callback(tag,self.tags,i), true
            if result==false then
                self.tags[i]=nil
            elseif type(result)~="nil" and result~=true then
                self.tags[i] = result
            end
            j=j+1
        end
    end
    self.tags = table.trimArray(self.tags)
    return j>1 and j-1 or false
end
ASSLineTagSection.modTags = ASSLineTagSection.callback

function ASSLineTagSection:getTags(tagTypes, start, end_, relative)
    local tags = {}
    self:callback(function(tag)
        tags[#tags+1] = tag
    end, tagTypes, start, end_, relative)
    return tags
end

function ASSLineTagSection:removeTags(...)
    local tags, tagTypes, tagObjects, removed, cnt = {...}, {}, {}, {}
    
    for i=1,#tags do 
        if ASS.instanceOf(tags[i]) then
            tagObjects[tags[i]] = true
        elseif type(tags[i]=="string") then
            tagTypes[ASS.mapTag(tags[i])] = true
        else error(string.format("Error: argument %d to removeTags() must be either a tag name or a tag object, got a %s.", i, type(tags[i]))) end
    end

    if #tags==0 then 
        cnt = #self.tags
        self.tags = {}
    else
        cnt = self:callback(function(tag)
            if tagTypes[tag.__tag.name] or tagObjects[tag] then
                removed[#removed+1] = tag
                return false
            end
        end)
    end
    return removed
end

function ASSLineTagSection:insertTags(tags, index)
    index = Default(index,#self.tags)
    if type(tags)~="table" or ASS.instanceOf(tags) then
        tags = {tags}
    end

    local inserted = {}
    for i,tag in ipairs(tags) do
        local cls = ASS.instanceOf(tag)
        if not cls then
            error(string.format("Error: argument %d to insertTags() must be a tag object, got a %s", i, type(tag)))
        end

        local tagData = ASS.tagMap[tag.__tag.name]
        if not tagData then
            error(string.format("Error: can't insert tag #%d of type %s: no with name '%s'.", i, tag.typeName, tag.__tag.name))
        elseif cls ~= tagData.type then
            error(string.format("Error: can't insert tag #%d with name '%s': expected type was %s, got %s.", 
                                i, tag.__tag.name, tagData.type.typeName, tag.typeName)
            )
        end

        table.insert(self.tags, index+i-1, tag:copy())
        inserted[i] = self.tags[index+i+1] 
    end
    return #inserted>1 and inserted or inserted[1]
end

function ASSLineTagSection:insertDefaultTags(tagTypes, index)
    if type(tagTypes)~="table" then tagTypes={tagTypes} end
    local defaultTags = self.parent:getStyleDefaultTags():getTags(tagTypes)
    return self:insertTags(defaultTags, index)
end

function ASSLineTagSection:getString(coerce)
    local tagString = ""
    self:callback(function(tag)
        tagString = tagString .. tag:getTagString(coerce)
    end)
    return tagString
end

function ASSLineTagSection:getEffectiveTags(includeDefault,includePrevious)   -- TODO: properly handle transforms
    includePrevious = default(includePrevious, true)
    -- previous and default tag lists
    local effTags
    if includeDefault then
        effTags = self.parent:getStyleDefaultTags()
    end
    if includePrevious and self.prevSection then
        local prevTagList = self.prevSection:getEffectiveTags()
        effTags = includeDefault and effTags:merge(prevTagList) or prevTagList
    end
    -- tag list of this section
    local tagList = ASSTagList(self)
    return effTags and effTags:merge(tagList) or tagList
end

ASSLineTagSection.getStyleTable = ASSLineTextSection.getStyleTable

ASSTagList = createASSClass("ASSTagList", ASSBase, {"tags"}, {"table"})

function ASSTagList:new(tags)
    if ASS.instanceOf(tags, ASSLineTagSection) then
        self.tags = {}
        tags:callback(function(tag)
            self.tags[tag.__tag.name] = tag
        end)
    elseif tags==nil then
        self.tags = {}
    else self.tags = self:typeCheck(tags) end
    return self
end

function ASSTagList:get()
    local flatTagList = {}
    for name,tag in pairs(self.tags) do
        flatTagList[name] = tag:get()
    end
    return flatTagList
end

function ASSTagList:merge(...)
    local tbls, merged = {...}, ASSTagList()
    for i=1,#tbls do
        assert(ASS.instanceOf(tbls[i],ASSTagList), 
               string.format("Error: can only merge %s objects, got a %s for argument #%d.", ASSTagList.typeName, type(tbls[i]), i)
        )
        merged.tags = table.merge(merged.tags, tbls[i]:copy().tags)
    end
    self.tags = table.merge(self.tags, merged.tags)
    return ASSTagList(table.merge(self:copy().tags, merged.tags))
end

function ASSTagList:intersect(...)
    local tbls = {...}
    local intersection = self:copy()

    for i=1,#tbls do
        assert(ASS.instanceOf(tbls[i],ASSTagList), 
               string.format("Error: can only intersect %s objects, got a %s for argument #%d.", ASSTagList.typeName, type(tbls[i]), i)
        )
        for name,tag in pairs(intersection.tags) do
            local isEqual = tag:equal(tbls[i].tags[name])
            intersection.tags[name] =  isEqual and tag or nil
            self.tags[name] = isEqual and atag or nil                  -- modify self but return copy
        end
    end
    return intersection
end

function ASSTagList:diff(other)
    assert(ASS.instanceOf(other,ASSTagList),
           string.format("Error: can only diff %s objects, got a %s.", ASSTagList.typeName, type(other))
    )

    local diff={}
    for name,tag in pairs(self.tags) do
        if not tag:equal(other.tags[name]) then
            diff[name] = tag:copy()
        else self.tags[name] = nil
        end
    end
    return ASSTagList(diff)
end

function ASSTagList:getStyleTable(styleRef, name, coerce)
    assert(type(styleRef)=="table" and styleRef.class=="style", 
           "Error: argument 1 to getStyleTable() must be a style table, got a " .. tostring(type(styleRef))
    )
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

function ASSTagList:getTags(tagTypes)
    if type(tagTypes)~="table" then tagTypes={tagTypes} end
    local tags = #tagTypes>0 and table.select(self.tags,tagTypes) or self.tags
    return table.values(tags)
end
--------------------- Override Tag Classes ---------------------

ASSTagBase = createASSClass("ASSTagBase", ASSBase)

function ASSTagBase:commonOp(method, callback, default, ...)
    local args = {self:getArgs({...}, default, false)}
    local j, res = 1, {}
    for _,valName in ipairs(self.__meta__.order) do
        if ASS.instanceOf(self[valName]) then
            local subCnt = #self[valName].__meta__.order
            res=table.join(res,{self[valName][method](self[valName],unpack(table.sliceArray(args,j,j+subCnt-1)))})
            j=j+subCnt
        else 
            self[valName]=callback(self[valName],args[j])
            j=j+1
            table.insert(res,self[valName])
        end
    end
    return unpack(res)
end

function ASSTagBase:add(...)
    return self:commonOp("add", function(a,b) return a+b end, 0, ...)
end

function ASSTagBase:sub(...)
    return self:commonOp("sub", function(a,b) return a-b end, 0, ...)
end

function ASSTagBase:mul(...)
    return self:commonOp("mul", function(a,b) return a*b end, 1, ...)
end

function ASSTagBase:pow(...)
    return self:commonOp("pow", function(a,b) return a^b end, 1, ...)
end

function ASSTagBase:set(...)
    return self:commonOp("set", function(a,b) return b end, nil, ...)
end

function ASSTagBase:mod(callback, ...)
    return self:set(callback(self:get(...)))
end

function ASSTagBase:readProps(tagProps)
    for key, val in pairs(tagProps or {}) do
        self.__tag[key] = val
    end
end

function ASSTagBase:getTagString(coerce)
    return ASS:formatTag(self, self:getTagParams(coerce))
end

function ASSTagBase:equal(ASSTag)  -- checks equalness only of the relevant properties
    if ASS.instanceOf(ASSTag)~=ASS.instanceOf(self) or self.__tag.name~=ASSTag.__tag.name then
        return false
    end

    local vals1, vals2 = {self:get()}, {ASSTag:get()}
    if #vals1~=#vals2 then return false end
    for i,val in ipairs(vals1) do
        if type(val)=="table" and #table.intersect(val,vals2[i])~=#val then
            return false
        elseif val~=vals2[i] then return false end
    end
    return true
end

ASSNumber = createASSClass("ASSNumber", ASSTagBase, {"value"}, {"number"}, {base=10, precision=3, scale=1})

function ASSNumber:new(val, tagProps)
    self:readProps(tagProps)
    self.value = type(val)=="table" and self:getArgs(val,0,true) or val or 0
    self:typeCheck(self.value)
    if self.__tag.positive then self:checkPositive(self.value) end
    if self.__tag.range then self:checkRange(self.__tag.range[1], self.__tag.range[2], self.value) end
    return self
end

function ASSNumber:getTagParams(coerce, precision)
    self:readProps(tagProps)
    precision = precision or self.__tag.precision
    local val = self.value
    if coerce then
        self:CoerceNumber(val,0)
    else
        assert(precision <= self.__tag.precision, string.format("Error: output wih precision %d is not supported for %s (maximum: %d).\n", 
               precision,self.typeName,self.__tag.precision))
        self:typeCheck(self.value)
        if self.__tag.positive then self:checkPositive(val) end
        if self.__tag.range then self:checkRange(self.__tag.range[1], self.__tag.range[2],val) end
    end
    return math.round(val,self.__tag.precision)
end


ASSPosition = createASSClass("ASSPosition", ASSTagBase, {"x","y"}, {"number", "number"})
function ASSPosition:new(valx, valy, tagProps)
    if type(valx) == "table" then
        tagProps = valy
        valx, valy = self:getArgs(valx,0,true)
    end
    self:readProps(tagProps)
    self:typeCheck(valx, valy)
    self.x, self.y = valx, valy
    return self
end


function ASSPosition:getTagParams(coerce, precision)
    local x,y = self.x, self.y
    if coerce then
        x,y = self:CoerceNumber(x,0), self:CoerceNumber(y,0)
    else 
        self:checkType("number", x, y)
    end
    precision = precision or 3
    local x = math.round(x,precision)
    local y = math.round(y,precision)
    return x, y
end
-- TODO: ASSPosition:move(ASSPosition) -> return \move tag

ASSTime = createASSClass("ASSTime", ASSNumber, {"value"}, {"number"}, {precision=0})
-- TODO: implement adding by framecount

function ASSTime:getTagParams(coerce, precision)
    precision = precision or 0
    local val = self.value
    if coerce then
        precision = math.min(precision,0)
        val = self:CoerceNumber(0)
    else
        assert(precision <= 0, "Error: " .. self.typeName .." doesn't support floating point precision")
        self:checkType("number", self.value)
        if self.__tag.positive then self:checkPositive(self.value) end
    end
    val = val/self.__tag.scale
    return math.round(val,precision)
end

ASSDuration = createASSClass("ASSDuration", ASSTime, {"value"}, {"number"}, {positive=true})
ASSHex = createASSClass("ASSHex", ASSNumber, {"value"}, {"number"}, {range={0,255}, base=16, precision=0})

ASSColor = createASSClass("ASSColor", ASSTagBase, {"r","g","b"}, {ASSHex,ASSHex,ASSHex})   
function ASSColor:new(r,g,b, tagProps)
    if type(r) == "table" then
        tagProps = g
        r,g,b = self:getArgs({r[1],r[2],r[3]},0,true)
    end 
    self:readProps(tagProps)
    self.r, self.g, self.b = ASSHex(r), ASSHex(g), ASSHex(b)
    return self
end

function ASSColor:addHSV(h,s,v)
    local ho,so,vo = util.RGB_to_HSV(self.r:get(),self.g:get(),self.b:get())
    local r,g,b = util.HSV_to_RGB(ho+h,util.clamp(so+s,0,1),util.clamp(vo+v,0,1))
    return self:set(r,g,b)
end

function ASSColor:getTagParams(coerce)
    return self.b:getTagParams(coerce), self.g:getTagParams(coerce), self.r:getTagParams(coerce)
end

ASSFade = createASSClass("ASSFade", ASSTagBase,
    {"startDuration", "endDuration", "startTime", "endTime", "startAlpha", "midAlpha", "endAlpha"},
    {ASSDuration,ASSDuration,ASSTime,ASSTime,ASSHex,ASSHex,ASSHex}
)
function ASSFade:new(startDuration,endDuration,startTime,endTime,startAlpha,midAlpha,endAlpha,tagProps)
    if type(startDuration) == "table" then
        tagProps = endDuration or {}
        prms={self:getArgs(startDuration,nil,true)}
        if #prms == 2 then 
            startDuration, endDuration = unpack(prms)
            tagProps.simple = true
        elseif #prms == 7 then
            startDuration, endDuration, startTime, endTime = prms[5]-prms[4], prms[7]-prms[6], prms[4], prms[7] 
        end
    end 
    self:readProps(tagProps)

    self.startDuration, self.endDuration = ASSDuration(startDuration), ASSDuration(endDuration)
    self.startTime = self.__tag.simple and ASSTime(0) or ASSTime(startTime)
    self.endTime = self.__tag.simple and nil or ASSTime(endTime)
    self.startAlpha = self.__tag.simple and ASSHex(0) or ASSHex(startAlpha)
    self.midAlpha = self.__tag.simple and ASSHex(255) or ASSHex(midAlpha)
    self.endAlpha = self.__tag.simple and ASSHex(0) or ASSHex(endAlpha)
    return self
end

function ASSFade:getTagParams(coerce)
    if self.__tag.simple then
        return self.startDuration:getTagParams(coerce), self.endDuration:getTagParams(coerce)
    else
        local t1, t4 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
        local t2 = t1 + self.startDuration:getTagParams(coerce)
        local t3 = t4 - self.endDuration:getTagParams(coerce)
        if not coerce then
             self:checkPositive(t2,t3)
             assert(t1<=t2 and t2<=t3 and t3<=t4, string.format("Error: fade times must evaluate to t1<=t2<=t3<=t4, got %d<=%d<=%d<=%d", t1,t2,t3,t4))
        end
        return self.startAlpha:getTagParams(coerce), self.midAlpha:getTagParams(coerce), self.endAlpha:getTagParams(coerce), 
               math.min(t1,t2), util.clamp(t2,t1,t3), util.clamp(t3,t2,t4), math.max(t4,t3)
    end
end

ASSMove = createASSClass("ASSMove", ASSTagBase,
    {"startPos", "endPos", "startTime", "endTime"},
    {ASSPosition,ASSPosition,ASSTime,ASSTime}
)
function ASSMove:new(startPosX,startPosY,endPosX,endPosY,startTime,endTime,tagProps)
    if type(startPosX) == "table" then
        tagProps = startPosY
        startPosX,startPosY,endPosX,endPosY,startTime,endTime = self:getArgs(startPosX, nil, true)
    end
    self:readProps(tagProps)
    assert((startTime==endTime and self.__tag.simple~=false) or (startTime and endTime), "Error: creating a complex move requires both start and end time.\n")
    
    if startTime==nil or endTime==nil or (startTime==0 and endTime==0) then
        self.__tag.simple = true
        self.__tag.name = "move_simple"
    else self.__tag.simple = false end

    self.startPos = ASSPosition(startPosX,startPosY)
    self.endPos = ASSPosition(endPosX,endPosY)
    self.startTime = ASSTime(startTime)
    self.endTime = ASSTime(endTime)
    return self
end

function ASSMove:getTagParams(coerce)
    if self.__tag.simple or self.__tag.name=="move_simple" then
        return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)})
    else
        if not coerce then
             assert(startTime<=endTime, string.format("Error: move times must evaluate to t1<=t2, got %d<=%d.\n", startTime,endTime))
        end
        local t1,t2 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
        return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)},
                         {math.min(t1,t2)}, {math.max(t2,t1)})
    end
end

ASSToggle = createASSClass("ASSToggle", ASSTagBase, {"value"}, {"boolean"})
function ASSToggle:new(val, tagProps)
    self:readProps(tagProps)
    if type(val) == "table" then
        self.value = self:getArgs(val,false,true)
    else 
        self.value = val or false 
    end
    self:typeCheck(self.value)
    return self
end

function ASSToggle:toggle(state)
    assert(type(state)=="boolean" or type(state)=="nil", "Error: state argument to toggle must be true, false or nil.\n")
    self.value = state==nil and not self.value or state
    return self.value
end

function ASSToggle:getTagParams(coerce)
    if not coerce then self:typeCheck(self.value) end
    return self.value and 1 or 0
end

ASSIndexed = createASSClass("ASSIndexed", ASSNumber, {"value"}, {"number"}, {precision=0, positive=true})
function ASSIndexed:cycle(down)
    local min, max = self.__tag.range[1], self.__tag.range[2]
    if down then
        return self.value<=min and self:set(max) or self:add(-1)
    else
        return self.value>=max and self:set(min) or self:add(1)
    end
end

ASSAlign = createASSClass("ASSAlign", ASSIndexed, {"value"}, {"number"}, {range={1,9}, default=5})

function ASSAlign:up()
    if self.value<7 then return self:add(3)
    else return false end
end

function ASSAlign:down()
    if self.value>3 then return self:add(-3)
    else return false end
end

function ASSAlign:left()
    if self.value%3~=1 then return self:add(-1)
    else return false end
end

function ASSAlign:right()
    if self.value%3~=0 then return self:add(1)
    else return false end
end

ASSWeight = createASSClass("ASSWeight", ASSTagBase, {"weightClass","bold"}, {ASSNumber,ASSToggle})
function ASSWeight:new(val, tagProps)
    if type(val) == "table" then
        local val = self:getArgs(val,0,true)
        self.bold = (val==1 and true) or (val==0 and false)
        self.weightClass = val>1 and true or 0
    elseif type(val) == "boolean" then
        self.bold, self.weightClass = val, 0
    else self.weightClass = val
    end
    self:readProps(tagProps)
    self.bold = ASSToggle(self.bold)
    self.weightClass = ASSNumber(self.weightClass,{positive=true,precision=0})
    return self
end

function ASSWeight:getTagParams(coerce)
    if self.weightClass.value >0 then
        return self.weightClass:getTagParams(coerce)
    else
        return self.bold:getTagParams(coerce)
    end
end

function ASSWeight:setBold(state)
    self.bold:set(type(state)=="nil" and true or state)
    self.weightClass.value = 0
end

function ASSWeight:toggleBold()
    self.bold:toggle()
end

function ASSWeight:setWeight(weightClass)
    self.bold:set(false)
    self.weightClass:set(weightClass or 400)
end

ASSWrapStyle = createASSClass("ASSWrapStyle", ASSIndexed, {"value"}, {"number"}, {range={0,3}, default=0})

ASSString = createASSClass("ASSString", ASSTagBase, {"value"}, {"string"})
function ASSString:new(val, tagProps)
    self:readProps(tagProps)
    if type(val) == "table" then
        self.value = self:getArgs(val,"",true)
    else 
        self.value = val or ""
    end
    return self
end

function ASSString:getTagParams(coerce)
    local val = self.value or ""
    if coerce and type(val)~= "string" then
        val = ""
    else self:typeCheck(val) end

    return val
end

function ASSString:append(str)
    return self:commonOp("append", function(val,str)
        return val..str
    end, "", str)
end

function ASSString:prepend(str)
    return self:commonOp("prepend", function(val,str)
        return str..val
    end, "", str)
end

function ASSString:replace(target,rep,useLuaPatterns)
    self.value = useLuaPatterns and self.value:gsub(target, rep) or re.sub(self.value,target,rep)
    return self.value
end

ASSString.add, ASSString.mul, ASSString.pow = ASSString.append, nil, nil

ASSClip = createASSClass("ASSClip", ASSTagBase, {}, {})
function ASSClip:new(arg1,arg2,arg3,arg4,tagProps)
    if type(arg1) == "table" then
        tagProps = arg2
        arg1,arg2,arg3,arg4 = unpack(arg1)
        if arg2 then
            arg1,arg2,arg3,arg4 = string.toNumbers(10,arg1,arg2,arg3,arg4)
        end
    end
    tagProps = tagProps or {}
    if type(arg1)=="number" then
        return ASSClipRect(arg1,arg2,arg3,arg4,tagProps)
    elseif type(arg1)=="string" then
        return ASSClipVect({arg1},tagProps)
    else error("Invalid argumets to ASSClip") end
end

ASSClipRect = createASSClass("ASSClipRect", ASSTagBase, {"topLeft", "bottomRight"}, {ASSPosition, ASSPosition})

function ASSClipRect:new(left,top,right,bottom,tagProps)
    if type(left) == "table" then
        tagProps = top
        left,top,right,bottom = self:getArgs(left, nil, true)
    end
    self:readProps(tagProps)
    self.topLeft = ASSPosition(left,top)
    self.bottomRight = ASSPosition(right,bottom)
    self:setInverse(self.__tag.inverse or false)
    return self
end

function ASSClipRect:getTagParams(coerce)
    self:setInverse(self.__tag.inverse or false)
    return returnAll({self.topLeft:getTagParams(coerce)}, {self.bottomRight:getTagParams(coerce)})
end

function ASSClipRect:setInverse(state)
    state = type(state)==nil and true or false
    self.__tag.inverse = state
    self.__tag.name = state and "iclip_rect" or "clip_rect"
    return state
end

function ASSClipRect:toggleInverse()
    return self:setInverse(not self.__tag.inverse)
end

ASSClipVect = createASSClass("ASSClipVect", ASSTagBase, {"commands"}, {"table"})

function ASSClipVect:new(...)
    --- two ways to create: [1] from string in a table [2] from list of ASSDraw objects
    local args, tagProps = {...}, {}
    self.commands = {}
    if #args<=2 and type(args[1])=="table" and not args[1].instanceOf then
        local cmdTypes = {
            m = ASSDrawMove,
            n = ASSDrawMoveNc,
            l = ASSDrawLine,
            b = ASSDrawBezier
        }
        local cmdParts, cmdType, prmCnt, i = args[1][1]:split(" "), "", 0, 1
        while i<=#cmdParts do
            if cmdTypes[cmdParts[i]] then
                cmdType = cmdParts[i]
                prmCnt, i = #cmdTypes[cmdType].__meta__.order, i+1
            else 
                self.commands[#self.commands+1] = cmdTypes[cmdType](table.sliceArray(cmdParts,i,i+prmCnt-1),self)
                i=i+prmCnt
            end
        end
        tagProps = args[2]
    elseif type(args[1])=="table" then
        tagProps = args[#args].instanceOf and {} or table.remove(args)
        for i,arg in ipairs(args) do
            assert(arg.baseClass==ASSDrawBase, string.format("Error: argument %d to %s is not a drawing object.", i, self.typeName))
        end
        self.commands = args
    end
    self:readProps(tagProps)
    self:setInverse(self.__tag.inverse or false)
    return self
end

function ASSClipVect:getTagParams(coerce)
    self:setInverse(self.__tag.inverse or false)
    local cmdStr, lastCmdType
    for i,cmd in ipairs(self.commands) do
        if lastCmdType~=cmd.__tag.name then
            lastCmdType = cmd.__tag.name
            cmdStr =  i==1 and lastCmdType or cmdStr .. " " .. lastCmdType
        end
        cmdStr = cmdStr .. " " .. table.concat({cmd:get(coerce)}," ")
    end
    return cmdStr
end

--TODO: unify setInverse and toggleInverse for VectClip and RectClip by using multiple inheritance
function ASSClipVect:setInverse(state)
    state = type(state)==nil and true or state
    self.__tag.inverse = state
    self.__tag.name = state and "iclip_vect" or "clip_vect"
    return state
end

function ASSClipVect:toggleInverse()
    return self:setInverse(not self.__tag.inverse)
end

function ASSClipVect:commonOp(method, callback, default, x, y) -- drawing commands only have x and y in common
    local res = {}
    for _,command in ipairs(self.commands) do
        local subCnt = #command.__meta__.order
        res=table.join(res,{command[method](command,x,y)})
    end
    return unpack(res)
end

function ASSClipVect:flatten()
    local flatStr = YUtils.shape.flatten(self:getTagParams())
    local flattened = ASSClipVect({flatStr},self.__tag)
    self.commands = flattened.commands
    return flatStr
end

function ASSClipVect:getLength()
    local totalLen,lens = 0, {}
    for i=1,#self.commands do
        local len = self.commands[i]:getLength(self.commands[i-1])
        lens[i], totalLen = len, totalLen+len
    end
    return totalLen,lens
end

function ASSClipVect:getCommandAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local currTotalLen, nextTotalLen = 0
    for _,cmd in ipairs(self.commands) do
        nextTotalLen = currTotalLen + cmd.length
        if nextTotalLen-len > -0.001 and cmd.length>0 and not (cmd.instanceOf[ASSDrawMove] or cmd.instanceOf[ASSDrawMoveNc]) then
            return cmd, math.max(len-currTotalLen,0)
        else currTotalLen = nextTotalLen end
    end
    error(string.format("Error: length requested (%02f) is exceeding the total length of the shape (%02f)",len,currTotalLen))
end

function ASSClipVect:getPositionAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen  = self:getCommandAtLength(len, true)
    return cmd:getPositionAtLength(remLen,true)
end

function ASSClipVect:getAngleAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen = self:getCommandAtLength(len, true)
    if cmd.instanceOf[ASSDrawBezier] then
        cmd = cmd.flattened:getCommandAtLength(remLen, true)
    end
    return cmd:getAngle(nil,true)
end

function ASSClipVect:get()
    local commands = {}
    for i,cmd in ipairs(self.commands) do
        commands = table.join(table.insert(commands,cmd.__tag.name),{cmd:get()})
    end
    return commands
end
ASSClipVect.set, ASSClipVect.mod = nil, nil  -- TODO: check if these can be remapped/implemented in a way that makes sense, maybe work on strings


--------------------- Drawing Command Classes ---------------------

ASSDrawBase = createASSClass("ASSDrawBase", ASSTagBase, {}, {})
function ASSDrawBase:new(...)
    local args = {...}
    if type(args[1]) == "table" then
        self.parent = args[2]
        args = {self:getArgs(args[1], nil, true)}
    end
    for i,arg in ipairs(args) do
        if i>#self.__meta__.order then
            self.parent = arg
        else
            self[self.__meta__.order[i]] = self.__meta__.types[i](arg) 
        end
    end
    return self
end

function ASSDrawBase:getTagParams(coerce)
    local cmdStr = self.__tag.name
    for _,param in ipairs(self.__meta__.order) do
        cmdStr = cmdStr .. " " .. tostring(self[param]:getTagParams(coerce))
    end
    return cmdStr
end

function ASSDrawBase:getLength(prevCmd) 
    -- get end coordinates (cursor) of previous command
    local x0, y0 = 0, 0
    if prevCmd and prevCmd.__tag.name == "b" then
        x0, y0 = prevCmd.x3:get(), prevCmd.y3:get()
    elseif prevCmd then x0, y0 = prevCmd.x:get(), prevCmd.y:get() end

    -- save cursor for further processing
    self.cursor = ASSPosition(x0,y0)

    local name, len = self.__tag.name, 0
    if name == "b" then
        local shapeSection = ASSClipVect(ASSDrawMove(self.cursor:get()),self)
        self.flattened = ASSClipVect({YUtils.shape.flatten(shapeSection:getTagParams())}) --save flattened shape for further processing
        len = self.flattened:getLength()
    elseif name =="m" or name == "n" then len=0
    elseif name =="l" then
        len = YUtils.math.distance(self.x:get()-x0, self.y:get()-y0)
    end
    -- save length for further processing
    self.length = len
    return len
end

function ASSDrawBase:getPositionAtLength(len,noUpdate)
    if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
    local name, pos = self.__tag.name
    if name == "b" then
        local x1,y1,x2,y2,x3,y3 = self:get()
        local px, py = YUtils.math.bezier(math.min(len/self.length,1), {{self.cursor:get()},{x1,y1},{x2,y2},{x3,y3}})
        pos = ASSPosition(px, py)
    elseif name == "l" then
        pos = ASSPosition(self:copy():ScaleToLength(len,true))  
    elseif name == "m" then
        pos = ASSPosition(self:get())
    end
    return pos
end

ASSDrawMove = createASSClass("ASSDrawMove", ASSDrawBase, {"x","y"}, {ASSNumber, ASSNumber}, {name="m"})
ASSDrawMoveNc = createASSClass("ASSDrawMoveNc", ASSDrawBase, {"x","y"}, {ASSNumber, ASSNumber}, {name="n"})
ASSDrawLine = createASSClass("ASSDrawLine", ASSDrawBase, {"x","y"}, {ASSNumber, ASSNumber}, {name="l"})
ASSDrawBezier = createASSClass("ASSDrawBezier", ASSDrawBase, {"x1","y1","x2","y2","x3","y3"}, {ASSNumber, ASSNumber, ASSNumber, ASSNumber, ASSNumber, ASSNumber}, {name="b"})
--- TODO: b-spline support

function ASSDrawLine:ScaleToLength(len,noUpdate)
    if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
    local scaled = self.cursor:copy()
    scaled:add(YUtils.math.stretch(returnAll(
        {ASSPosition(self:get()):sub(self.cursor)},
        {0, len})
    ))
    self:set(scaled:get())
    return self:get()
end

function ASSDrawLine:getAngle(ref, noUpdate)
    if not (ref or (self.cursor and noUpdate)) then self.parent:getLength() end
    ref = ref or self.cursor:copy()
    assert(type(ref)=="table", "Error: argument ref to getAngle() must be of type table, got " .. type(ref) .. ".\n")
    if ref.instanceOf[ASSDrawBezier] then
        ref = ASSPosition(ref.x3, ref.y3)
    elseif not ref.instanceOf then
        ref = ASSPosition(ref[1], ref[2])
    elseif not ref.instanceOf[ASSPosition] and ref.baseClass~=ASSDrawBase then
        error("Error: argument ref to getAngle() must either be an ASSDraw object, an ASSPosition or a table containing coordinates x and y.\n")
    end
    local dx,dy = ASSPosition(self:get()):sub(ref)
    return (360 - math.deg(math.atan2(dy,dx))) %360
end

function ASSDrawBezier:commonOp(method, callback, default, ...)
    local args, j, res = {...}, 1, {}
    if #args<=2 then -- special case to allow common operation on all x an y values of a vector drawing
        args[1], args[2] = args[1] or 0, args[2] or 0
        args = table.join(args,args,args)
    end
    args = {self:getArgs(args, default, false)}
    for _,valName in ipairs(self.__meta__.order) do
        local subCnt = #self[valName].__meta__.order
        res=table.join(res,{self[valName][method](self[valName],unpack(table.sliceArray(args,j,j+subCnt-1)))})
        j=j+subCnt
    end
    return unpack(res)
end

----------- Tag Mapping -------------

ASSFoundation = createASSClass("ASSFoundation")
function ASSFoundation:new()
    local tagMap = {
        scale_x= {friendlyName="\\fscx", type=ASSNumber, pattern="\\fscx([%d%.]+)", format="\\fscx%.3N"},
        scale_y = {friendlyName="\\fscy", type=ASSNumber, pattern="\\fscy([%d%.]+)", format="\\fscy%.3N"},
        align = {friendlyName="\\an", type=ASSAlign, pattern="\\an([1-9])", format="\\an%d"},
        angle = {friendlyName="\\frz", type=ASSNumber, pattern="\\frz?([%-%d%.]+)", format="\\frz%.3N"}, 
        angle_y = {friendlyName="\\fry", type=ASSNumber, pattern="\\fry([%-%d%.]+)", format="\\frz%.3N", default=0},
        angle_x = {friendlyName="\\frx", type=ASSNumber, pattern="\\frx([%-%d%.]+)", format="\\frz%.3N", default=0}, 
        outline = {friendlyName="\\bord", type=ASSNumber, props={positive=true}, pattern="\\bord([%d%.]+)", format="\\bord%.2N"}, 
        outline_x = {friendlyName="\\xbord", type=ASSNumber, props={positive=true}, pattern="\\xbord([%d%.]+)", format="\\xbord%.2N"}, 
        outline_y = {friendlyName="\\ybord", type=ASSNumber,props={positive=true}, pattern="\\ybord([%d%.]+)", format="\\ybord%.2N"}, 
        shadow = {friendlyName="\\shad", type=ASSNumber, pattern="\\shad([%-%d%.]+)", format="\\shad%.2N"}, 
        shadow_x = {friendlyName="\\xshad", type=ASSNumber, pattern="\\xshad([%-%d%.]+)", format="\\xshad%.2N"}, 
        shadow_y = {friendlyName="\\yshad", type=ASSNumber, pattern="\\yshad([%-%d%.]+)", format="\\yshad%.2N"}, 
        reset = {friendlyName="\\r", type=ASSString, pattern="\\r([^\\}]*)", format="\\r%s", default=""}, 
        alpha = {friendlyName="\\alpha", type=ASSHex, pattern="\\alpha&H(%x%x)&", format="\\alpha&H%02X&", default=0}, 
        alpha1 = {friendlyName="\\1a", type=ASSHex, pattern="\\1a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        alpha2 = {friendlyName="\\2a", type=ASSHex, pattern="\\2a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        alpha3 = {friendlyName="\\3a", type=ASSHex, pattern="\\3a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        alpha4 = {friendlyName="\\4a", type=ASSHex, pattern="\\4a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        color1 = {friendlyName="\\1c", type=ASSColor, pattern="\\1?c&H(%x%x)(%x%x)(%x%x)&", format="\\1c&H%02X%02X%02X&"},
        color2 = {friendlyName="\\2c", type=ASSColor, pattern="\\2c&H(%x%x)(%x%x)(%x%x)&", format="\\2c&H%02X%02X%02X&"},
        color3 = {friendlyName="\\3c", type=ASSColor, pattern="\\3c&H(%x%x)(%x%x)(%x%x)&", format="\\3c&H%02X%02X%02X&"},
        color4 = {friendlyName="\\4c", type=ASSColor, pattern="\\4c&H(%x%x)(%x%x)(%x%x)&", format="\\4c&H%02X%02X%02X&"},
        clip_vect = {friendlyName="\\clip (Vect)", type=ASSClipVect, pattern="\\clip%(([mnlbspc] .-)%)", format="\\clip(%s)"}, 
        iclip_vect = {friendlyName="\\iclip (Vect)", type=ASSClipVect, props={inverse=true}, pattern="\\iclip%(([mnlbspc] .-)%)", format="\\iclip(%s)", default={"m 0 0 l 0 0 0 0 0 0 0 0"}},
        clip_rect = {friendlyName="\\clip (Rect)", type=ASSClipRect, pattern="\\clip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\clip(%.2N,%.2N,%.2N,%.2N)"}, 
        iclip_rect = {friendlyName="\\iclip (Rect)", type=ASSClipRect, props={inverse=true}, pattern="\\iclip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\iclip(%.2N,%.2N,%.2N,%.2N)", default={0,0,0,0}},
        blur_edges = {friendlyName="\\be", type=ASSNumber, props={positive=true}, pattern="\\be([%d%.]+)", format="\\be%.2N", default=0}, 
        blur = {friendlyName="\\blur", type=ASSNumber, props={positive=true}, pattern="\\blur([%d%.]+)", format="\\blur%.2N", default=0}, 
        shear_x = {friendlyName="\\fax", type=ASSNumber, pattern="\\fax([%-%d%.]+)", format="\\fax%.2N", default=0}, 
        shear_y = {friendlyName="\\fay", type=ASSNumber, pattern="\\fay([%-%d%.]+)", format="\\fay%.2N", default=0}, 
        bold = {friendlyName="\\b", type=ASSWeight, pattern="\\b(%d+)", format="\\b%d"}, 
        italic = {friendlyName="\\i", type=ASSToggle, pattern="\\i([10])", format="\\i%d"}, 
        underline = {friendlyName="\\u", type=ASSToggle, pattern="\\u([10])", format="\\u%d"},
        strikeout = {friendlyName="\\s", type=ASSToggle, pattern="\\s([10])", format="\\s%d"},
        spacing = {friendlyName="\\fsp", type=ASSNumber, pattern="\\fsp([%-%d%.]+)", format="\\fsp%.2N"},
        fontsize = {friendlyName="\\fs", type=ASSNumber, props={positive=true}, pattern="\\fs([%d%.]+)", format="\\fs%.2N"},
        fontname = {friendlyName="\\fn", type=ASSString, pattern="\\fn([^\\}]*)", format="\\fn%s"},
        k_fill = {friendlyName="\\k", type=ASSDuration, props={scale=10}, pattern="\\k([%d]+)", format="\\k%d", default=0},
        k_sweep = {friendlyName="\\kf", type=ASSDuration, props={scale=10}, pattern="\\kf([%d]+)", format="\\kf%d", default=0},
        k_sweep_alt = {friendlyName="\\K", type=ASSDuration, props={scale=10}, pattern="\\K([%d]+)", format="\\K%d", default=0},
        k_bord = {friendlyName="\\ko", type=ASSDuration, props={scale=10}, pattern="\\ko([%d]+)", format="\\ko%d", default=0},
        position = {friendlyName="\\pos", type=ASSPosition, pattern="\\pos%(([%-%d%.]+),([%-%d%.]+)%)", format="\\pos(%.2N,%.2N)"},
        move_simple = {friendlyName=nil, type=ASSMove, props={simple=true}, pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\move(%.2N,%.2N,%.2N,%.2N)"},
        move = {friendlyName="\\move", type=ASSMove, pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),(%d+),(%d+)%)", format="\\move(%.2N,%.2N,%.2N,%.2N,%.2N,%.2N)"},
        org = {friendlyName="\\org", type=ASSPosition, pattern="\\org%(([%-%d%.]+),([%-%d%.]+)%)", format="\\org(%.2N,%.2N)"},
        wrap = {friendlyName="\\q", type=ASSWrapStyle, pattern="\\q(%d)", format="\\q%d", default=0},
        fade_simple = {friendlyName="\\fad", type=ASSFade, props={simple=true}, pattern="\\fad%((%d+),(%d+)%)", format="\\fad(%d,%d)", default={0,0}},
        fade = {friendlyName="\\fade", type=ASSFade, pattern="\\fade?%((.-)%)", format="\\fade(%d,%d,%d,%d,%d,%d,%d)", default={255,0,255,0,0,0,0}},
        transform = {friendlyName="\\t", type=ASSTransform, pattern="\\t%((.-)%)"},
    }

    -- insert tag name into props
    for name,tag in pairs(tagMap) do
        tag.props = tag.props or {}
        tag.props.name = name
    end

    self.tagMap = tagMap
    return self
end

function ASSFoundation:getInternalTagName(name)
    if self.tagMap[name] then return name
    else
        for key,val in pairs(self.tagMap) do
            if val.friendlyName==name then return key end
        end
    end
    return false
end

function ASSFoundation:mapTag(name)
    assert(type(name)=="string", "Error: argument 1 to mapTag() must be a string, got a " .. type(name))
    name = self:getInternalTagName(name)
    return self.tagMap[assert(name,"Error: can't find tag " .. name)], name
end

function ASSFoundation:createTag(name, ...)
    local tag = self:mapTag(name)
    return tag.type(returnAll({...},{tag.props}))
end

function ASSFoundation:__createTag(name, ...)     -- faster version for internal use
    local tag = self.tagMap[name]
    return tag.type(returnAll({...},{tag.props}))
end

function ASSFoundation:getTagFromString(str)
    for _,tag in pairs(self.tagMap) do
        if tag.pattern then
            local prms={str:match(tag.pattern)}
            if #prms>0 then
                return tag.type(prms,tag.props)
            end
        end
    end
    return false
end

function ASSFoundation:formatTag(tagRef, ...)
    return self:mapTag(tagRef.__tag.name).format:formatFancy(...)
end

function ASSFoundation.instanceOf(val,classes)
    local isASSObj = type(val)=="table" and val.instanceOf

    if not isASSObj then
        return false
    elseif type(classes)=="nil" then
        return isASSObj and table.keys(isASSObj)[1]
    elseif type(classes)~="table" or classes.instanceOf then
        classes = {classes}
    end

    for _,class in ipairs(classes) do 
        if val.instanceOf[class] then
            return true
        end
    end
    return false
end


ASS = ASSFoundation()