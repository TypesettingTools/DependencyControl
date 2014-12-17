local re = require("aegisub.re")
local unicode = require("aegisub.unicode")
local util = require("aegisub.util")
local l0Common = require("l0.Common")
local YUtils = require("YUtils")
local Line = require("a-mo.Line")
local Log = require("a-mo.Log")
local ASSInspector = require("ASSInspector.Inspector")

function createASSClass(typeName, baseClasses, order, types, tagProps, compatibleClasses)
    if not baseClasses or type(baseClasses)=="table" and baseClasses.instanceOf then
        baseClasses = {baseClasses}
    end
    local cls, compatibleClasses = {}, compatibleClasses or {}

    -- write base classes set and import class members
    cls.baseClasses = {}
    for i=1,#baseClasses do
        for k, v in pairs(baseClasses[i]) do
            cls[k] = v
        end
        cls.baseClasses[baseClasses[i]] = true
    end

    -- object constructor
    setmetatable(cls, {
    __call = function(cls, ...)
        local self = setmetatable({__tag = util.copy(cls.__defProps)}, cls)
        self = self:new(...)
        return self
    end})

    cls.__index, cls.instanceOf, cls.typeName, cls.class = cls, {[cls] = true}, typeName, cls
    cls.__meta__ = {order = order, types = types}
    cls.__defProps = table.merge(cls.__defProps or {},tagProps or {})

    -- compatible classes
    cls.compatible = table.arrayToSet(compatibleClasses)
    -- set mutual compatibility in reference classes
    for i=1,#compatibleClasses do
        compatibleClasses[i].compatible[cls] = true
    end
    cls.compatible[cls] = true

    return cls
end

--------------------- Base Class ---------------------

ASSBase = createASSClass("ASSBase")
function ASSBase:checkType(type_, ...) --TODO: get rid of
    local vals = table.pack(...)
    for i=1,vals.n do
        result = (type_=="integer" and math.isInt(vals[i])) or type(vals[i])==type_
        assert(result, string.format("Error: %s must be a %s, got %s.\n",self.typeName,type_,type(vals[i])))
    end
end

function ASSBase:checkPositive(...)
    self:checkType("number", ...)
    local vals = table.pack(...)
    for i=1,vals.n do
        assert(vals[i] >= 0, string.format("Error: %s tagProps do not permit numbers < 0, got %d.\n", self.typeName,vals[i]))
    end
end

function ASSBase:checkRange(min,max,...)
    self:checkType("number",...)
    local vals = table.pack(...)
    for i=1,vals.n do
        assert(vals[i] >= min and vals[i] <= max, string.format("Error: %s must be in range %d-%d, got %d.\n",self.typeName,min,max,vals[i]))
    end
end

function ASSBase:coerceNumber(num, default)
    num = tonumber(num)
    if not num then num=default or 0 end
    if self.__tag.positive then num=math.max(num,0) end
    if self.__tag.range then num=util.clamp(num,self.__tag.range[1], self.__tag.range[2]) end
    return num 
end

function ASSBase:coerce(value, type_)
    assert(type(value)~="table", "Error: can't cast a table to a " .. type_ ..".")
    local tagProps = self.__tag or self.__defProps
    if type(value) == type_ then
        return value
    elseif type_ == "number" then
        if type(value)=="boolean" then return value and 1 or 0
        else return tonumber(value,tagProps.base or 10)*(tagProps.scale or 1) end
    elseif type_ == "string" then
        return tostring(value)
    elseif type_ == "boolean" then
        return value~=0 and value~="0" and value~=false
    elseif type_ == "table" then
        return {value}
    end
end

function ASSBase:getArgs(args, defaults, coerce, extraValidClasses)
    -- TODO: make getArgs automatically create objects
    assert(type(args)=="table", "Error: first argument to getArgs must be a table of arguments, got a " .. type(args) ..".\n")
    local propTypes, propNames, j, outArgs, argSlice = self.__meta__.types, self.__meta__.order, 1, {}
    if not args then args={}
    -- process "raw" property that holds all tag parameters when parsed from a string
    elseif type(args.raw)=="table" then args=args.raw
    elseif args.raw then args={args.raw}
    -- check if first and only arg is a compatible ASSClass and dump into args 
    elseif #args == 1 and type(args[1]) == "table" and args[1].instanceOf then
        local selfClasses = extraValidClasses and table.merge(self.compatible, extraValidClasses) or self.compatible
        local _, clsMatchCnt = table.intersect(selfClasses, args[1].compatible)

        if clsMatchCnt>0 then
            if args.deepCopy then 
                args = {args[1]:get()}
            else
                -- This is a fast path for compatible objects
                -- TODO: check for issues caused by this change
                local obj = args[1]
                for i=1,#self.__meta__.order do
                    args[i] = obj[self.__meta__.order[i]]
                end
                return unpack(args)
            end
        else assert(type(propTypes[1]) == "table" and propTypes[1].instanceOf, 
                    string.format("Error: object of class %s does not accept instances of class %s as argument.\n", self.typeName, args[1].typeName)
             ) 
        end
    end

    for i=1,#propNames do
        if ASS.instanceOf(propTypes[i]) then
            local subCnt = #propTypes[i].__meta__.order
            local defSlice = type(defaults)=="table" and table.sliceArray(defaults,j,j+subCnt-1) or defaults

            if not ASS.instanceOf(args[j]) then
                argSlice, j = table.sliceArray(args,j,j+subCnt-1), j+subCnt-1
            else argSlice = {args[j]} end

            outArgs = table.join(outArgs, {propTypes[i]:getArgs(argSlice, defSlice, coerce)})
        elseif args[j]==nil then
            -- write defaults
            outArgs[i] = type(defaults)=="table" and defaults[j] or defaults
        elseif coerce and type(args[j])~=propTypes[i] then               
            outArgs[i] = self:coerce(args[j], propTypes[i])
        else outArgs[i]=args[j] end
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
        else newObj[key]=val end
    end
    return newObj
end

function ASSBase:typeCheck(...)
    local valTypes, valNames, j, args = self.__meta__.types, self.__meta__.order, 1, {...}
    for i=1,#valNames do
        if ASS.instanceOf(valTypes[i]) then
            if ASS.instanceOf(args[j]) then   -- argument and expected type are both ASSObjects, defer type checking to object
                self[valNames[i]]:typeCheck(args[j])
            else  -- collect expected number of arguments for target ASSObject
                local subCnt = #valTypes[i].__meta__.order
                valTypes[i]:typeCheck(unpack(table.sliceArray(args,j,j+subCnt-1)))
                j=j+subCnt-1
            end
        else    
            assert(type(args[j])==valTypes[i] or args[j]==nil or valTypes[i]=="nil",
                   string.format("Error: bad type for argument #%d (%s). Expected %s, got %s.", i, valNames[i], valTypes[i], type(args[j]))) 
        end
        j=j+1
    end
    return unpack(args)
end

function ASSBase:get()
    local vals, names, valCnt = {}, self.__meta__.order, 1
    for i=1,#names do
        if ASS.instanceOf(self[names[i]]) then
            for j,subVal in pairs({self[names[i]]:get()}) do 
                vals[valCnt], valCnt = subVal, valCnt+1
            end
        else
            vals[valCnt], valCnt = self[names[i]], valCnt+1
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
        local i, j, drawingState, ovrStart, ovrEnd = 1, 1, ASS:createTag("drawing",0)
        while i<=#line.text do
            ovrStart, ovrEnd = line.text:find("{.-}",i)
            if ovrStart then
                if ovrStart>i then
                    local substr = line.text:sub(i,ovrStart-1)
                    sections[j], j = drawingState.value==0 and ASSLineTextSection(substr) or ASSLineDrawingSection{str=substr, scale=drawingState}, j+1
                end
                sections[j] = ASSLineTagSection(line.text:sub(ovrStart+1,ovrEnd-1))
                -- remove drawing tags from the tag sections so we don't have to keep state in sync with ASSLineDrawingSection
                local drawingTags = sections[j]:removeTags("drawing")
                if #sections[j].tags == 0 and #drawingTags>0 then
                    sections[j], j = nil, j-1
                end
                drawingState = drawingTags[#drawingTags] or drawingState
                i = ovrEnd +1
            else
                local substr = line.text:sub(i)
                sections[j] = drawingState.value==0 and ASSLineTextSection(substr) or ASSLineDrawingSection{str=substr, scale=drawingState}
                break
            end
            j=j+1
        end
    end
    self.line, self.sections = line, self:typeCheck(sections)
    self:updateRefs()
    return self
end

function ASSLineContents:updateRefs(prevCnt)
    if prevCnt~=#self.sections then
        for i=1,#self.sections do
            self.sections[i].prevSection = self.sections[i-1]
            self.sections[i].parent = self
            self.sections[i].index = i
        end
        return true
    else return false end
end

function ASSLineContents:getString(coerce, classes)
    local defDrawingState = ASS:createTag("drawing",0)
    local j, str, sections, prevDrawingState, secType, prevSecType = 1, {}, self.sections, defDrawingState

    for i=1,#sections do
        secType, lastSecType = ASS.instanceOf(sections[i], ASS.classes.lineSection, classes), secType
        if secType == ASSLineTextSection or secType == ASSLineDrawingSection then
            -- determine whether we need to enable or disable drawing mode and insert the appropriate tags
            local drawingState = secType==ASSLineDrawingSection and sections[i].scale or defDrawingState
            if drawingState ~= prevDrawingState then
                if prevSecType==ASSLineTagSection then
                    table.insert(str,j-1,drawingState:getTagString())
                    j=j+1
                else
                    str[j], str[j+1], str[j+2], j = "{", drawingState:getTagString(), "}", j+3
                end
                prevDrawingState = drawingState
            end
            str[j] = sections[i]:getString()

        elseif secType == ASSLineTagSection or secType==ASSLineCommentSection then
            str[j], str[j+1], str[j+2], j =  "{", sections[i]:getString(), "}", j+2

        else 
            assert(coerce, string.format("Error: invalid %s section #%d. Expected {%s}, got a %s.\n", 
                 self.typeName, i, table.concat(table.pluck(ASS.classes.lineSection, "typeName"), ", "),
                 type(sections[i])=="table" and sections[i].typeName or type(sections[i]))
            )
        end
        prevSecType, j = secType, j+1
    end
    return table.concat(str)
end

function ASSLineContents:get(sectionClasses, start, end_, relative)
    local result, j = {}, 1
    self:callback(function(section,sections,i)
        result[j], j = section:copy(), j+1
    end, sectionClasses, start, end_, relative)
    return result
end

function ASSLineContents:callback(callback, sectionClasses, start, end_, relative, reverse)
    local prevCnt = #self.sections
    start = default(start,1)
    end_ = default(end_, start>=1 and math.max(prevCnt,1) or -1)
    reverse = relative and start<0 or reverse

    assert(math.isInt(start) and math.isInt(end_), 
           string.format("Error: arguments 'start' and 'end' to callback() must be integers, got %s and %s.", type(start), type(end_)))
    assert((start>0)==(end_>0) and start~=0 and end_~=0, 
           string.format("Error: arguments 'start' and 'end' to callback() must be either both >0 or both <0, got %d and %d.", start, end_))
    assert(start <= end_, string.format("Error: condition 'start' <= 'end' not met, got %d <= %d", start, end_))

    local j, numRun, sects = 0, 0, self.sections
    if start<0 then
        start, end_ = relative and math.abs(end_) or prevCnt+start+1, relative and math.abs(start) or prevCnt+end_+1
    end

    for i=reverse and prevCnt or 1, reverse and 1 or prevCnt, reverse and -1 or 1 do
        if ASS.instanceOf(sects[i], ASS.classes.lineSection, sectionClasses) then
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
    self.sections = table.trimArray(self.sections)
    self:updateRefs(prevCnt)
    return numRun>0 and numRun or false
end

function ASSLineContents:insertSections(sections,index)
    index = index or #self.sections+1
    if type(sections)~="table" or sections.instanceOf then
        sections = {sections}
    end
    for i=1,#sections do
        assert(ASS.instanceOf(sections[i],ASS.classes.lineSection),
              string.format("Error: can only insert sections of type {%s}, got %s.\n", 
              table.concat(table.select(ASS.classes.lineSection, {"typeName"}), ", "), type(sections[i]))
        )
        table.insert(self.sections, index+i-1, sections[i])
    end
    self:updateRefs()
    return sections
end

function ASSLineContents:removeSections(start, end_)
    local removed = {}
    if not start then
        self.sections, removed = {}, self.sections
    elseif type(start) == "number" then
        end_ = end_ or start
        removed = table.removeRange(self.sections, start, end_)
    elseif type(start) == "table" then
        local toRemove = start.instanceOf and {start=true} or table.arrayToSet(start)
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

function ASSLineContents:modTags(tagNames, callback, start, end_, relative)
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
    end, ASSLineTagSection, not relative and start or nil, not relative and end_ or nil, true, reverse)

    return modCnt>0 and modCnt or false
end

function ASSLineContents:getTags(tagNames, start, end_, relative)
    local tags, i = {}, 1

    self:modTags(tagNames, function(tag)
        tags[i], i = tag, i+1
    end, start, end_, relative)

    return tags
end

function ASSLineContents:removeTags(tags, start, end_, relative)
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
    end, ASSLineTagSection, not relative and start or nil, not relative and end_ or nil, true, reverse)

    return removed
end

function ASSLineContents:insertTags(tags, index, sectionPosition, direct)
    assert(index==nil or math.isInt(index) and index~=0,
           string.format("Error: argument #2 (index) to insertTags() must be an integer != 0, got '%s' of type %s", tostring(index), type(index))
    )
    index = default(index, 1)

    if direct then
        local section = self.sections[index>0 and index or #self.sections-index+1]
        assert(ASS.instanceOf(section, ASSLineTagSection), string.format("Error: can't insert tag in section #%d of type %s.", 
               index, section and section.typeName or "<no section>")
        )
        return section:insertTags(tags, sectionPosition)
    else
        local inserted
        local sectFound = self:callback(function(section)
            inserted = section:insertTags(tags, sectionPosition)
        end, ASSLineTagSection, index, index, true)
        if not sectFound and index==1 then
            inserted = self:insertSections(ASSLineTagSection(),1)[1]:insertTags(tags)
        end
        return inserted
    end
end

function ASSLineContents:insertDefaultTags(tagNames, index, sectionPosition, direct)
    local defaultTags = self:getDefaultTags():filterTags(tagNames)
    return self:insertTags(defaultTags, index, sectionPosition, direct)
end

function ASSLineContents:getEffectiveTags(index, includeDefault, includePrevious, copyTags)
    index, copyTags = default(index,1), default(copyTags, true)
    assert(math.isInt(index) and index~=0,
           string.format("Error: argument #1 (index) to getEffectiveTags() must be an integer != 0, got '%s' of type %s", tostring(index), type(index))
    )
    if index<0 then index = index+#self.sections+1 end
    return self.sections[index]:getEffectiveTags(includeDefault,includePrevious,copyTags)
end

function ASSLineContents:getTagCount()
    local cnt, sects = 0, self.sections
    for i=1,#sects do
        cnt = cnt + (sects[i].tags and #sects[i].tags or 0)
    end
    return cnt
end

function ASSLineContents:stripTags()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineTagSection)
    return self
end

function ASSLineContents:stripText()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineTextSection)
    return self
end

function ASSLineContents:stripComments()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineCommentSection)
    return self
end

function ASSLineContents:stripDrawings()
    self:callback(function(section,sections,i)
        return false
    end, ASSLineDrawingSection)
    return self
end

function ASSLineContents:commit(line)
    line = line or self.line
    line.text, line.undoText = self:getString(), line.text
    line:createRaw()
    return line.text
end

function ASSLineContents:undoCommit(line)
    line = line or self.line
    if line.undoText then
        line.text, line.undoText = line.undoText
        line:createRaw()
        return true
    else return false end
end

function ASSLineContents:cleanTags(level, mergeSect)   -- TODO: optimize it, make it work properly for transforms
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
        end, ASSLineTagSection)
    end

    -- 1: remove empty sections, 2: dedup tags locally, 3: dedup tags globally
    -- 4: remove tags matching style default and not changing state, end: remove empty sections
    local tagListPrev, tagListDef = ASSTagList(nil, self), self:getDefaultTags()
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
            
            return not tagList:isEmpty() and ASSLineTagSection(tagList) or false
        end, ASSLineTagSection)
    end
    return self
end

function ASSLineContents:splitAtTags(cleanLevel, reposition, writeOrigin)
    cleanLevel = default(cleanLevel,3)
    local splitLines = {}
    self:callback(function(section,_,i,j)
        local splitLine = Line(self.line, self.line.parentCollection, {ASS={}})
        splitLine.ASS = ASSLineContents(splitLine, table.insert(self:get(ASSLineTagSection,0,i),section))
        splitLine.ASS:cleanTags(cleanLevel)
        splitLine.ASS:commit()
        splitLines[j] = splitLine
    end, ASSLineTextSection)
    if reposition then self:repositionSplitLines(splitLines, writeOrigin) end
    return splitLines
end

function ASSLineContents:splitAtIntervals(callback, cleanLevel, reposition, writeOrigin)
    cleanLevel = default(cleanLevel,3)
    if type(callback)=="number" then
        local step=callback
        callback = function(idx,len)
            return idx+step
        end
    else assert(type(callback)=="function", "Error: first argument to splitAtIntervals must be either a number or a callback function.\n") end
    
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
            local addTextSection = skip and section:copy() or ASSLineTextSection(text:sub(1,nextIdx-off-1))
            local addSections, lastContents = table.insert(self:get(ASSLineTagSection,lastI+1,i), addTextSection), splitLines[#splitLines].ASS
            lastContents:insertSections(addSections)
        end
            
        while idx <= sectEndIdx do
            nextIdx = math.ceil(callback(idx,len))
            assert(nextIdx>idx, "Error: callback function for splitAtIntervals must always return an index greater than the last index.")
            -- create a new line
            local splitLine = Line(self.line, self.line.parentCollection)
            splitLine.ASS = ASSLineContents(splitLine, self:get(ASSLineTagSection,1,i))
            splitLine.ASS:insertSections(ASSLineTextSection(unicode.sub(text,idx-off,nextIdx-off-1)))
            splitLines[splitCnt], splitCnt = splitLine, splitCnt+1      
            -- check if this section is long enough to fill the new line
            idx = sectEndIdx>=nextIdx-1 and nextIdx or sectEndIdx+1
        end
        lastI = i
    end, ASSLineTextSection)
    
    for i=1,#splitLines do
        splitLines[i].ASS:cleanTags(cleanLevel)
        splitLines[i].ASS:commit()
    end

    if reposition then self:repositionSplitLines(splitLines, writeOrigin) end
    return splitLines
end

function ASSLineContents:repositionSplitLines(splitLines, writeOrigin)
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

local styleDefaultCache = {}

function ASSLineContents:getStyleRef(style)
    if ASS.instanceOf(style, ASSString) then
        style = style:get()
    end
    if style==nil or style=="" then
        style = self.line.styleRef
    elseif type(style)=="string" then
        style = self.line.parentCollection.styles[style] or style
        assert(type(style)=="table", "Error: couldn't find style with name: " .. style .. ".")
    else assert(type(style)=="table" and style.class=="style", 
                "Error: invalid argument #1 (style): expected a style name or a styleRef, got a " .. type(style) .. ".")
    end
    return style
end

function ASSLineContents:getPosition(style, align, forceDefault)
    self.line:extraMetrics()
    local effTags = not (forceDefault and align) and self:getEffectiveTags(-1,false,true,false).tags
    style = self:getStyleRef(style)
    align = align or effTags.align or style.align

    if ASS.instanceOf(align,ASSAlign) then
        align = align:get()
    else assert(type(align)=="number", "Error: argument #1 (align) must be of type number or %s, got a %s.",
         ASSAlign.typeName, ASS.instanceOf(align) or type(align))
    end

    if not forceDefault and effTags.position then
        return effTags.position
    end

    local scriptInfo = util.getScriptInfo(self.line.parentCollection.sub) 
    -- blatantly copied from torque's Line.moon
    vMargin = self.line.margin_t == 0 and style.margin_t or self.line.margin_t
    lMargin = self.line.margin_l == 0 and style.margin_l or self.line.margin_l
    rMargin = self.line.margin_r == 0 and style.margin_r or self.line.margin_r

    return ASS:createTag("position", self.line.defaultXPosition[align%3+1](scriptInfo.PlayResX, lMargin, rMargin), 
                                     self.line.defaultYPosition[math.ceil(align/3)](scriptInfo.PlayResY, vMargin)
    ), ASS:createTag("align", align)
end

function ASSLineContents:getDefaultTags(style, copyTags, useOvrAlign)    -- TODO: cache
    copyTags, useOvrAlign = default(copyTags,true), default(useOvrAlign, true)
    local line = self.line
    style = self:getStyleRef(style)

    -- alignment override tag may affect the default position so we'll have to retrieve it
    local position, align = self:getPosition(style, not useOvrAlign and style.align, true)
    local raw = (useOvrAlign and style.align~=align.value) and style.raw.."_"..align.value or style.raw

    if styleDefaultCache[raw] then
        -- always return at least a fresh ASSTagList object to prevent the cached one from being overwritten
        return copyTags and styleDefaultCache[raw]:copy() or ASSTagList(styleDefaultCache[raw])
    end

    local function styleRef(tag)
        if tag:find("alpha") then 
            return style[tag:gsub("alpha", "color")]:sub(3,4)
        elseif tag:find("color") then
            return style[tag]:sub(5,6), style[tag]:sub(7,8), style[tag]:sub(9,10)
        else return style[tag] end
    end

    local scriptInfo = util.getScriptInfo(self.line.parentCollection.sub)
    local resX, resY = tonumber(scriptInfo.PlayResX), tonumber(scriptInfo.PlayResY)

    local tagList = ASSTagList(nil, self)
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
        clip_vect = ASS:createTag("clip_vect", {ASSDrawMove(0,0), ASSDrawLine(resX,0), ASSDrawLine(resX,resY), ASSDrawLine(0,resY), ASSDrawLine(0,0)}),
        iclip_vect = ASS:createTag("iclip_vect", {ASSDrawMove(0,0), ASSDrawLine(0,0), ASSDrawLine(0,0), ASSDrawLine(0,0), ASSDrawLine(0,0)}),
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
    return copyTags and tagList:copy() or ASSTagList(tagList)
end

function ASSLineContents:getTextExtents(coerce)   -- TODO: account for linebreaks
    local width, other = 0, {0,0,0}
    self:callback(function(section)
        local extents = {section:getTextExtents(coerce)}
        width = width + table.remove(extents,1)
        table.process(other, extents, function(val1,val2)
            return math.max(val1,val2)
        end)
    end, ASSLineTextSection)
    return width, unpack(other)
end

function ASSLineContents:getLineBounds(noCommit)
    return ASSLineBounds(self, noCommit)
end

function ASSLineContents:getMetrics(includeLineBounds, includeTypeBounds, coerce)
    local metr = {ascent=0, descent=0, internal_leading=0, external_leading=0, height=0, width=0}
    local typeBounds = includeTypeBounds and {0,0,0,0}
    local textCnt = self:getSectionCount(ASSLineTextSection)

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

    end, ASSLineTextSection)
    
    if includeTypeBounds then
        typeBounds.width, typeBounds.height = typeBounds[3]-typeBounds[1], typeBounds[4]-typeBounds[2]
        metr.typeBounds = typeBounds
    end

    if includeLineBounds then
        metr.lineBounds, metr.animated = self:getLineBounds()
    end
    return metr
end

function ASSLineContents:getSectionCount(classes)
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

function ASSLineContents:isAnimated()
    local t, line = self:getEffectiveTags(-1, false, true, false).tags, self.line
    local frameCount = aegisub.frame_from_ms(line.end_time) - aegisub.frame_from_ms(line.start_time)
    if frameCount<2 then return false end

    local karaTags = {t.k_fill, t.k_sweep, t.k_sweep_alt, t.k_bord}
    for i=1,#karaTags do
        if karaTags[i] and karaTags[i].value*karaTags[i].__tag.scale < line.duration then
            -- this is broken right now due to incorrect handling of kara tags in getEffectiveTags
            return true
        end
    end

    if t.transform or
    (t.move and not t.move.startPos:equal(t.move.endPos) and t.move.startTime<t.move.endTime) or
    (t.move_simple and not t.move_simple.startPos:equal(t.move_simple.endPos) and t.move_simple.startTime<t.move_simple.endTime) or
    (t.fade and (t.fade.startDuration>0 and not t.fade.startAlpha:equal(t.fade.midAlpha) or 
                 t.fade.endDuration>0 and not t.fade.midAlpha:equal(t.fade.endAlpha))) or
    (t.fade_simple and (t.fade_simple.startDuration>0 and not t.fade_simple.startAlpha:equal(t.fade_simple.midAlpha) or 
                        t.fade_simple.endDuration>0 and not t.fade_simple.midAlpha:equal(t.fade_simple.endAlpha))) then
        return true
    end

    return false
end

function ASSLineContents:reverse()
    local reversed, textCnt = {}, self:getSectionCount(ASSLineTextSection)
    self:callback(function(section,_,_,j)
        reversed[j*2-1] = ASSLineTagSection(section:getEffectiveTags(true,true))
        reversed[j*2] = section:reverse()
    end, ASSLineTextSection, nil, nil, nil, true)
    self.sections = reversed
    self:updateRefs()
    return self:cleanTags(4)
end

ASSLineBounds = createASSClass("ASSLineBounds", ASSBase, {1, 2, "w", "h", "fbf", "animated", "rawText"}, 
                              {"ASSPoint", "ASSPoint", "number", "number", "table", "boolean", "string"})
function ASSLineBounds:new(cnts, noCommit)
    assert(ASS.instanceOf(cnts, ASSLineContents), 
           string.format("Error: argument #1 must be an object of type %s, got a %s.", 
                          ASSLineTagSection.typeName, ASS.instanceOf(cnts) or type(cnts))
    )
    if not noCommit then cnts:commit() end
    local assi, msg = ASSInspector(cnts.line.parentCollection.sub)
    assert(assi, "ASSInspector Error: " .. tostring(msg))

    self.animated = cnts:isAnimated()
    cnts.line.assi_exhaustive = animated

    local bounds, times = assi:getBounds{cnts.line}
    assert(bounds~=nil,"ASSInspector Error: " .. tostring(times))

    if bounds[1]~=false then
        local frame, x2Max, y2Max, x1Min, y1Min = aegisub.frame_from_ms, 0, 0
        self.fbf={off=frame(times[1]), n=#bounds}
        for i=1,self.fbf.n do
            if bounds[i] then
                local x1, y1, w, h = bounds[i].x, bounds[i].y, bounds[i].w, bounds[i].h
                local x2, y2 = x1+w, y1+h
                self.fbf[frame(times[i])] = {ASSPoint{x1,y1}, ASSPoint{x2,y2}, w=w, h=h, hash=bounds[i].hash}
                x1Min, y1Min = math.min(x1, x1Min or x1), math.min(y1, y1Min or y1)
                x2Max, y2Max = math.max(x2, x2Max), math.max(y2, y2Max)
            else self.fbf[frame(times[i])] = {w=0, h=0, hash=false} end
        end
        self[1], self[2], self.w, self.h = ASSPoint{x1Min,y1Min}, ASSPoint{x2Max, y2Max}, x2Max-x1Min, y2Max-y1Min
    else self.w, self.h, self.fbf = 0, 0, {n=0} end
    
    self.rawText = cnts.line.text
    if not noCommit then cnts:undoCommit() end
    return self
end

function ASSLineBounds:equal(other)
    assert(ASS.instanceOf(other, ASSLineBounds), 
           string.format("Error: argument #1 must be an object of type %s, got a %s.", 
                          ASSLineBounds.typeName, ASS.instanceOf(other) or type(other))
    )
    if self.w + other.w == 0 then 
        return true
    elseif self.w~=other.w or self.h~=other.h or self.animated~=other.animated or self.fbf.n~=other.fbf.n then
        return false
    end

    for i=0,self.fbf.n-1 do
        if self.fbf[self.fbf.off+i].hash ~= other.fbf[other.fbf.off+i].hash then
            return false
        end
    end

    return true
end

local ASSStringBase = createASSClass("ASSStringBase", ASSBase, {"value"}, {"string"})
function ASSStringBase:new(args)
    self.value = self:getArgs(args,"",true)
    self:readProps(args)
    return self
end

function ASSStringBase:append(str)
    return self:commonOp("append", function(val,str)
        return val..str
    end, "", str)
end

function ASSStringBase:prepend(str)
    return self:commonOp("prepend", function(val,str)
        return str..val
    end, "", str)
end

function ASSStringBase:replace(pattern, rep, plainMatch, useRegex)
    if plainMatch then
        useRegex, pattern = false, target:patternEscape()
    end
    self.value = useRegex and re.sub(self.value, pattern, rep) or self.value:gsub(pattern, rep)
    return self
end

function ASSStringBase:reverse()
    self.value = unicode.reverse(self.value)
    return self
end

ASSLineTextSection = createASSClass("ASSLineTextSection", ASSStringBase, {"value"}, {"string"})

function ASSLineTextSection:new(value)
    self.value = self:typeCheck(self:getArgs({value},"",true))
    return self
end

function ASSLineTextSection:getString(coerce)
    if coerce then return tostring(self.value)
    else return self:typeCheck(self.value) end
end


function ASSLineTextSection:getEffectiveTags(includeDefault, includePrevious, copyTags)
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
    
    return effTags or ASSTagList(nil, self.parent)
end

function ASSLineTextSection:getStyleTable(name, coerce)
    return self:getEffectiveTags(false,true,false):getStyleTable(self.parent.line.styleRef, name, coerce)
end

function ASSLineTextSection:getTextExtents(coerce)
    return aegisub.text_extents(self:getStyleTable(nil,coerce),self.value)
end

function ASSLineTextSection:getMetrics(includeTypeBounds, coerce)
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

function ASSLineTextSection:getShape(applyRotation, coerce)
    applyRotation = default(applyRotation, false)
    local metr, tagList, shape = self:getMetrics(true)
    local drawing, an = ASSDrawing{raw=shape}, tagList.tags.align:getSet()
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

function ASSLineTextSection:convertToDrawing(applyRotation, coerce)
    local shape = self:getShape(applyRotation, coerce)
    self.value, self.commands, self.scale = nil, shape.commands, shape.scale
    setmetatable(self,ASSLineDrawingSection)
end

function ASSLineTextSection:getYutilsFont(coerce)
    local tagList = self:getEffectiveTags(true,true,false)
    local tags = tagList.tags
    return YUtils.decode.create_font(tags.fontname:getTagParams(coerce), tags.bold:getTagParams(coerce)>0,
                                     tags.italic:getTagParams(coerce)>0, tags.underline:getTagParams(coerce)>0, tags.strikeout:getTagParams(coerce)>0,
                                     tags.fontsize:getTagParams(coerce), tags.scale_x:getTagParams(coerce)/100, tags.scale_y:getTagParams(coerce)/100,
                                     tags.spacing:getTagParams(coerce)
    ), tagList
end

ASSLineCommentSection = createASSClass("ASSLineCommentSection", ASSLineTextSection, {"value"}, {"string"})

ASSLineTagSection = createASSClass("ASSLineTagSection", ASSBase, {"tags"}, {"table"})
ASSLineTagSection.tagMatch = re.compile("\\\\[^\\\\\\(]+(?:\\([^\\)]+\\)[^\\\\]*)?|[^\\\\]+")

function ASSLineTagSection:new(tags, transformableOnly)
    if ASS.instanceOf(tags,ASSTagList) then
        -- TODO: check if it's a good idea to work with refs instead of copies
        local j=1
        self.tags = {}
        if tags.reset then
            self.tags[1], j = tags.reset, 2
        end

        for _,tag in pairs(tags.tags) do
            if not transformableOnly or tag.__tag.transformable or tag.instanceOf[ASSUnknown] then
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
            if not transformableOnly or tag.__tag.transformable or tag.instanceOf[ASSUnknown] then
                self.tags[i], i = tag, i+1
            end
            if end_ < #match then   -- comments inside tag sections are read into ASSUnknowns
                local afterStr = match:sub(end_+1)
                self.tags[i], i = ASS:createTag(afterStr:sub(1,1)=="\\" and "unknown" or "junk", afterStr), i+1
            end
        end
        
        if #self.tags==0 and #tags>0 then    -- no tags found but string not empty -> must be a comment section
            return ASSLineCommentSection(tags)
        end
    elseif tags==nil then self.tags={}
    elseif ASS.instanceOf(tags, ASSLineTagSection) then
        self.parent = tags.parent
        if transformableOnly then
            local j=1
            self.tags = {}
            for i=1,#tags.tags do
                if tags.tags[i].__tag.transformable or tags.tags[i].instanceOf[ASSUnknown]then
                    self.tags[j], j = tags.tags[i], j+1
                end
            end
        else
            self.tags = util.copy(tags.tags)
        end
    else self.tags = self:typeCheck(self:getArgs({tags})) end
    return self
end

function ASSLineTagSection:callback(callback, tagNames, start, end_, relative, reverse)
    local tagSet, prevCnt = {}, #self.tags
    start = default(start,1)
    end_ = default(end_, start>=1 and math.max(prevCnt,1) or -1)
    reverse = relative and start<0 or reverse

    assert(math.isInt(start) and math.isInt(end_), 
           string.format("Error: arguments 'start' and 'end' to callback() must be integers, got %s and %s.", type(start), type(end_)))
    assert((start>0)==(end_>0) and start~=0 and end_~=0, 
           string.format("Error: arguments 'start' and 'end' to callback() must be either both >0 or both <0, got %d and %d.", start, end_))
    assert(start <= end_, string.format("Error: condition 'start' <= 'end' not met, got %d <= %d", start, end_))

    if type(tagNames)=="string" then tagNames={tagNames} end
    if tagNames then
        assert(type(tagNames)=="table", "Error: argument 2 to callback must be either a table of strings or a single string, got " .. type(tagNames))
        for i=1,#tagNames do
            tagSet[tagNames[i]] = true
        end
    end

    local j, numRun, tags, tagsDeleted = 0, 0, self.tags, false
    if start<0 then
        start, end_ = relative and math.abs(end_) or prevCnt+start+1, relative and math.abs(start) or prevCnt+end_+1
    end

    for i=reverse and prevCnt or 1, reverse and 1 or prevCnt, reverse and -1 or 1 do
        if not tagNames or tagSet[tags[i].__tag.name] then
            j=j+1
            if (relative and j>=start and j<=end_) or (not relative and i>=start and i<=end_) then
                local result = callback(tags[i],self.tags,i,j)
                numRun = numRun+1
                if result==false then
                    tags[i], tagsDeleted = nil, true
                elseif type(result)~="nil" and result~=true then
                    tags[i] = result
                end
            end
        end
    end
    self.tags = tagsDeleted and table.trimArray(tags) or tags
    return numRun>0 and numRun or false
end

function ASSLineTagSection:modTags(tagNames, callback, start, end_, relative)
    return self:callback(callback, tagNames, start, end_, relative)
end

function ASSLineTagSection:getTags(tagNames, start, end_, relative)
    local tags = {}
    self:callback(function(tag)
        tags[#tags+1] = tag
    end, tagNames, start, end_, relative)
    return tags
end

function ASSLineTagSection:remove()
    if not self.parent then return self end
    return self.parent:removeSections(self)
end

function ASSLineTagSection:removeTags(tags, start, end_, relative)
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
    if tags~=nil and (type(tags)~="table" or ASS.instanceOf(tags)) then 
        tags = {tags}
    end

    local tagNames, tagObjects, removed, reverse = {}, {}, {}, start<0
    -- build sets
    if tags and #tags>0 then
        for i=1,#tags do 
            if ASS.instanceOf(tags[i]) then
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
                removed[#removed+1] = tag
                return false
            end
        end
    end, nil, not relative and start or nil, not relative and end_ or nil, false, reverse)

    return removed, matched
end

function ASSLineTagSection:insertTags(tags, index)
    local prevCnt, inserted = #self.tags, {}
    index = default(index,math.max(prevCnt,1))
    assert(math.isInt(index) and index~=0,
           string.format("Error: argument 2 (index) must be an integer != 0, got '%s' of type %s", tostring(index), type(index))
    )
    
    if type(tags)=="table" then
        if tags.instanceOf[ASSLineTagSection] then
            tags = tags.tags
        elseif tags.instanceOf[ASSTagList] then
            tags = ASSLineTagSection(tags).tags
        elseif tags.instanceOf then tags = {tags} end
        else error("Error: argument 1 (tags) must be one of the following: a tag object, a table of tag objects, an ASSLineTagSection or an ASSTagList; got a "
                   .. type(tags) .. ".")
        end

    for i=1,#tags do
        local cls = ASS.instanceOf(tags[i])
        if not cls then
            -- TODO: check if it's actually a tag object
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
        inserted[i] = self.tags[insertIdx] 
    end
    return #inserted>1 and inserted or inserted[1]
end

function ASSLineTagSection:insertDefaultTags(tagNames, index)
    local defaultTags = self.parent:getDefaultTags():getTags(tagNames)
    return self:insertTags(defaultTags, index)
end

function ASSLineTagSection:getString(coerce)
    -- TODO: optimize
    local tagString = ""
    self:callback(function(tag)
        tagString = tagString .. tag:getTagString(coerce)
    end)
    return tagString
end

function ASSLineTagSection:getEffectiveTags(includeDefault, includePrevious, copyTags)   -- TODO: properly handle transforms
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
    -- tag list of this section
    local tagList = copyTags and ASSTagList(self):copy() or ASSTagList(self)
    return effTags and effTags:merge(tagList, false) or tagList
end

ASSLineTagSection.getStyleTable = ASSLineTextSection.getStyleTable

ASSTagList = createASSClass("ASSTagList", ASSBase, {"tags", "transforms" ,"reset", "startTime", "endTime", "accel"},
                            {"table", "table", ASSString, ASSTime, ASSTime, ASSNumber})

function ASSTagList:new(tags, contentRef)
    if ASS.instanceOf(tags, ASSLineTagSection) then
        self.tags, self.transforms, self.contentRef = {}, {}, tags.parent
        local trIdx, transforms, ovrTransTags, transTags = 1, {}, {}

        tags:callback(function(tag)
            local props = tag.__tag

            -- Discard all previous non-global tags when a reset is encountered (including all transformed tags)
            -- Vectorial clips are not "global" but can't be reset
            if props.name == "reset" then 
                self.tags, self.reset = self:getGlobal(true), tag

                for i=1,#transforms do
                    local keep = false
                    transforms[i].tags:callback(function(tag)
                        if tag.instanceOf[ASSClipRect] then 
                            keep = true 
                        else return false end
                    end)
                    if not keep then transforms[i] = nil end
                end

            -- Transforms are stored in a separate table because there can be more than one.
            -- When the list is converted back into an ASSTagSection, the transforms are written to its end,
            -- so we have to make sure transformed tags are not overridden afterwards:
            -- If a transform is encountered any entries in the overridden transforms list
            -- are marked as limited to all previous transforms in the transforms list.
            elseif tag.instanceOf[ASSTransform] then
                transforms[trIdx] = ASSTransform{tag, transformableOnly=true}   -- we need a shallow copy of the transform to filter
                transTags, trIdx = transforms[trIdx].tags.tags, trIdx+1
                for j=1,#transTags do
                    if ovrTransTags[transTags[j].__tag.name] then
                        ovrTransTags[transTags[j].__tag.name] = trIdx-1
                    end
                end

            -- Discard all except the first instance of global tags.
            -- This expects all global tags to be non-transformable which is true for ASSv4+
            elseif not (self.tags[props.name] and props.global) then
                self.tags[props.name] = tag
                if tag.__tag.transformable then
                    ovrTransTags[tag.__tag.name] = -1
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
                    if ovrEnd==-1 or ovrEnd>i then
                        return false
                    else transTagCnt = transTagCnt+1 end
                end)
                -- write final transforms table
                if transTagCnt>0 then
                    self.transforms[t], t = transforms[i], t+1
                end
            end
        end

    elseif ASS.instanceOf(tags, ASSTagList) then
        self.tags, self.reset, self.transforms = util.copy(tags.tags), tags.reset, util.copy(tags.transforms)
        self.contentRef = tags.contentRef
    elseif tags==nil then
        self.tags, self.transforms = {}, {}
    else error(string.format("Error: an %s can only be constructed from an %s or %s; got a %s.", 
                              ASSTagList.typeName, ASSLineTagSection.typeName, ASSTagList.typeName,
                              ASS.instanceOf(tags) and tags.typeName or type(tags))
         ) 
    end
    self.contentRef = contentRef or self.contentRef
    return self
end

function ASSTagList:get()
    local flatTagList = {}
    for name,tag in pairs(self.tags) do
        flatTagList[name] = tag:get()
    end
    return flatTagList
end

function ASSTagList:isTagTransformed(tagName)
    local set = {}
    for i=1,#self.transforms do
        for j=1,#self.transforms[i].tags.tags do
            set[self.transforms[i].tags.tags[j].__tag.name] = true
        end
    end
    return tagName and set[tagName] or set
end

function ASSTagList:merge(tagLists, copyTags, returnOnly, overrideGlobalTags, expandResets)
    copyTags = default(copyTags, true)
    if ASS.instanceOf(tagLists, ASSTagList) then
        tagLists = {tagLists}
    end

    local merged, ovrTransTags, resetIdx, seenTransform = ASSTagList(self), {}, 0, #self.transforms>0
    if expandResets and self.reset then
        local expReset = merged.contentRef:getDefaultTags(merged.reset)
        merged.tags = merged:getDefaultTags(merged.reset):merge(merged.tags, false)
    end

    for i=1,#tagLists do
        assert(ASS.instanceOf(tagLists[i],ASSTagList), 
               string.format("Error: can only merge %s objects, got a %s for argument #%d.", ASSTagList.typeName, type(tagLists[i]), i)
        )

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
            if not (merged.tags[name] and tag.__tag.global) or overrideGlobalTags then
                merged.tags[name] = tag
                -- mark transformable tags in previous transform lists as overridden
                if seenTransform and tag.__tag.transformable then
                    ovrTransTags[tag.__tag.name] = i
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
                local transform = i==0 and transforms[j] or ASSTransform{transforms[j]}
                local transTagCnt = 0

                transform.tags:callback(function(tag)
                    local ovrEnd = ovrTransTags[tag.__tag.name] or 0
                    -- remove transforms overwritten by resets or the override table
                    if resetIdx>i and not tag.instanceOf[ASSClipRect] or ovrEnd>i then
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

function ASSTagList:intersect(tagLists, copyTags, returnOnly) -- returnOnly note: only provided because copying the tag list before diffing may be much slower
    copyTags = default(copyTags, true)
    if ASS.instanceOf(tagLists, ASSTagList) then
        tagLists = {tagLists}
    end

    local intersection = ASSTagList(self, self.contentRef)
    for i=1,#tagLists do
        assert(ASS.instanceOf(tagLists[i],ASSTagList), 
               string.format("Error: can only intersect %s objects, got a %s for argument #%d.", ASSTagList.typeName, type(tagLists[i]), i)
        )
        for name,tag in pairs(intersection.tags) do
            intersection.tags[name] = tag:equal(tagLists[i].tags[name]) and tag or nil
        end
        if intersection.reset and not intersection.reset:equal(tagLists[i].reset) then
            intersection.reset = nil
        end
    end
    if copyTags then intersection=intersection:copy() end
    if not returnOnly then 
        self.tags, self.reset = intersection.tags, intersection.reset
        return self
    else return intersection end
end

function ASSTagList:diff(other, returnOnly, ignoreGlobalState) -- returnOnly note: only provided because copying the tag list before diffing may be much slower
    assert(ASS.instanceOf(other,ASSTagList),
           string.format("Error: can only diff %s objects, got a %s.", ASSTagList.typeName, type(other))
    )

    local diff, ownReset = ASSTagList(nil, self.contentRef), self.reset

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

        -- since global tags can't be overwritten, only treat global tags that are also present in the other tag list as different
        if global and not other.tags[name]
        -- all local tags transformed in the previous section will change state (no matter the tag values) when used in this section,
        -- unless this section begins with a reset, in which case only rectangular clips are kept
        or not (global or ownReset and not tag.instanceOf[ASSClipRect]) and otherTransSet[name] 
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

function ASSTagList:filterTags(tagNames, tagProps, returnOnly)
    if type(tagNames)=="string" then tagNames={tagNames} end
    assert(not tagNames or type(tagNames)=="table", 
           "Error: argument 1 to selectTags() must be either a single or a table of tag names, got a " .. type(tagNames))
    
    local filtered = ASSTagList(nil, self.contentRef)
    local selected, transTypes, retTrans = {}, ASS.tagTypes.ASSTransform
    local propCnt = tagProps and table.length(tagProps) or 0
    
    if not tagNames and not (tagProps or #tagProps==0) then 
        return returnOnly and self:copy() or self
    elseif not tagNames then
        tagNames = ASS.tagTypes.all
    elseif #tagNames==0 then
        return filtered
    end

    for i=1,#tagNames do
        local name, propMatch = tagNames[i], true
        local selfTag = name=="reset" and self.reset or self.tags[name]
        assert(type(name)=="string", 
               string.format("Error: invalid tag name #%d '(%s)'. expected a string, got a %s", i, tostring(name), type(name))
        )

        if propCnt~=0 and selfTag then
            local _, propMatchCnt = table.intersect(tagProps, self.tags[name].__tag)
            propMatch = propMatchCnt == propCnt
        end

        if not (propMatch and selfTag) then
            -- do nothing
        elseif name == "reset" then
            filtered.reset = selfTag
        elseif transTypes[name] then
            retTrans = true         -- TODO: pseudo transform name
        elseif self.tags[name] then
            filtered.tags[name] = selfTag
        end
    end

    if returnOnly then
        if retTransforms then filtered.transforms = util.copy(self.transforms) end
        return filtered
    end

    self.tags, self.reset, self.transforms = filtered.tags, filtered.reset, retTrans and self.transforms or {}
    return self
end

function ASSTagList:isEmpty()
    return table.length(self.tags)<1 and not self.reset and #self.transforms==0
end

function ASSTagList:getGlobal(includeRectClips)
    local global = {}
    for name,tag in pairs(self.tags) do
        global[name] = (includeRectClips and tag.__tag.globalOrRectClip or tag.__tag.global) and tag or nil
    end
    return global
end
--------------------- Override Tag Classes ---------------------

ASSTagBase = createASSClass("ASSTagBase", ASSBase)

function ASSTagBase:commonOp(method, callback, default, ...)
    local args = {self:getArgs({...}, default, false)}
    local j, res, valNames = 1, {}, self.__meta__.order
    for i=1,#valNames do
        if ASS.instanceOf(self[valNames[i]]) then
            local subCnt = #self[valNames[i]].__meta__.order
            local subArgs = unpack(table.sliceArray(args,j,j+subCnt-1))
            res=table.join(res,{self[valNames[i]][method](self[valNames[i]],subArgs)})
            j=j+subCnt
        else 
            self[valNames[i]]=callback(self[valNames[i]],args[j])
            res[j], j = self[valNames[i]], j+1
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

function ASSTagBase:readProps(args)
    if type(args[1])=="table" and args[1].instanceOf and args[1].instanceOf[self.class] then
        for k, v in pairs(args[1].__tag) do
            self.__tag[k] = v
        end
    elseif args.tagProps then 
        for key, val in pairs(args.tagProps) do
            self.__tag[key] = val
        end
    end
end

function ASSTagBase:getTagString(coerce)
    return self.disabled and "" or ASS:formatTag(self, self:getTagParams(coerce))
end

function ASSTagBase:equal(ASSTag)  -- checks equalness only of the relevant properties
    if ASS.instanceOf(ASSTag)~=ASS.instanceOf(self) or self.__tag.name~=ASSTag.__tag.name then
        return false
    end

    local vals1, vals2 = {self:get()}, {ASSTag:get()}
    if #vals1~=#vals2 then return false end
    for i=1,#vals1 do
        if type(vals1[i])=="table" and #table.intersectInto(vals1[i],vals2[i]) ~= #vals2[i] then
            return false
        elseif type(vals1[i])~="table" and vals1[i]~=vals2[i] then return false end
    end
    return true
end

ASSNumber = createASSClass("ASSNumber", ASSTagBase, {"value"}, {"number"}, {base=10, precision=3, scale=1})

function ASSNumber:new(args)
    self:readProps(args)
    self.value = self:getArgs(args,0,true)
    self:typeCheck(self.value)
    if self.__tag.positive then self:checkPositive(self.value) end
    if self.__tag.range then self:checkRange(self.__tag.range[1], self.__tag.range[2], self.value) end
    if self.__tag.mod then self.value = self.value % self.__tag.mod end
    return self
end

function ASSNumber:getTagParams(coerce, precision)

    precision = precision or self.__tag.precision
    local val = self.value
    if coerce then
        self:coerceNumber(val,0)
    else
        assert(precision <= self.__tag.precision, string.format("Error: output wih precision %d is not supported for %s (maximum: %d).\n", 
               precision,self.typeName,self.__tag.precision))
        self:typeCheck(self.value)
        if self.__tag.positive then self:checkPositive(val) end
        if self.__tag.range then self:checkRange(self.__tag.range[1], self.__tag.range[2],val) end
    end
    if self.__tag.mod then val = val % self.__tag.mod end
    return math.round(val,self.__tag.precision)
end

function ASSNumber.cmp(a, mode, b)
    local modes = {
        ["<"] = function() return a<b end,
        [">"] = function() return a>b end,
        ["<="] = function() return a<=b end,
        [">="] = function() return a>=b end
    }

    local errStr = "Error: operand %d must be a number or an object of (or based on) the %s class, got a %s."
    if type(a)=="table" and (a.instanceOf[ASSNumber] or a.baseClasses[ASSNumber]) then
        a = a:get()
    else assert(type(a)=="number", string.format(errStr, 1, ASSNumber.typeName, ASS.instanceOf(a) and a.typeName or type(a))) end

    if type(b)=="table" and (b.instanceOf[ASSNumber] or b.baseClasses[ASSNumber]) then
        b = b:get()
    else assert(type(b)=="number", string.format(errStr, 1, ASSNumber.typeName, ASS.instanceOf(b) and b.typeName or type(b))) end

    return modes[mode]()
end

function ASSNumber.__lt(a,b) return ASSNumber.cmp(a, "<", b) end
function ASSNumber.__le(a,b) return ASSNumber.cmp(a, "<=", b) end


ASSPoint = createASSClass("ASSPoint", ASSTagBase, {"x","y"}, {ASSNumber, ASSNumber})
function ASSPoint:new(args)
    local x, y = self:getArgs(args,0,true)
    self:readProps(args)
    self.x, self.y = ASSNumber{x}, ASSNumber{y}
    return self
end

function ASSPoint:getTagParams(coerce, precision)
    return self.x:getTagParams(coerce, precision), self.y:getTagParams(coerce, precision)
end

-- TODO: ASSPosition:move(ASSPoint) -> return \move tag

ASSTime = createASSClass("ASSTime", ASSNumber, {"value"}, {"number"}, {precision=0})
-- TODO: implement adding by framecount

function ASSTime:getTagParams(coerce, precision)
    precision = precision or 0
    local val = self.value
    if coerce then
        precision = math.min(precision,0)
        val = self:coerceNumber(0)
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
function ASSColor:new(args)
    local b,g,r = self:getArgs(args,nil,true)
    self:readProps(args)
    self.r, self.g, self.b = ASSHex{r}, ASSHex{g}, ASSHex{b}
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
function ASSFade:new(args)
    if args.raw and #args.raw==7 then -- \fade
        local a, r, num = {}, args.raw, tonumber
        a[1], a[2], a[3], a[4], a[5], a[6], a[7] = num(r[5])-num(r[4]), num(r[7])-num(r[6]), r[4], r[7], r[1], r[2], r[3]
        args.raw = a
    end 
    startDuration, endDuration, startTime, endTime, startAlpha, midAlpha, endAlpha = self:getArgs(args,{0,0,0,0,255,0,255},true)

    self:readProps(args)
    if self.__tag.simple == nil then
        self.__tag.simple = self:setSimple(args.simple)
    end

    self.startDuration, self.endDuration = ASSDuration{startDuration}, ASSDuration{endDuration}
    self.startTime, self.endTime = ASSTime{startTime}, ASSTime{endTime}
    self.startAlpha, self.midAlpha, self.endAlpha = ASSHex{startAlpha}, ASSHex{midAlpha}, ASSHex{endAlpha}

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

function ASSFade:setSimple(state)
    if state==nil then
        state = self.startTime==0 and self.endTime==0 and self.startAlpha==255 and self.midAlpha==0 and self.endAlpha==255
    end
    self.__tag.simple, self.__tag.name = state, state and "fade_simple" or "fade"
    return state
end

ASSMove = createASSClass("ASSMove", ASSTagBase,
    {"startPos", "endPos", "startTime", "endTime"},
    {ASSPoint,ASSPoint,ASSTime,ASSTime}
)
function ASSMove:new(args)
    local startX, startY, endX, endY, startTime, endTime = self:getArgs(args, 0, true)

    assert(startTime<=endTime, string.format("Error: argument #4 (endTime) to %s may not be smaller than argument #3 (starTime), got %d>=%d.", 
                                             self.typeName, endTime, startTime)
    )

    if self.__tag.simple == nil then
        self.__tag.simple = self:setSimple(args.simple)
    end
    self:readProps(args)

    self.startPos, self.endPos = ASSPoint{startX, startY}, ASSPoint{endX, endY}
    self.startTime, self.endTime = ASSTime{startTime}, ASSTime{endTime}
    return self
end

function ASSMove:getTagParams(coerce)
    if self.__tag.simple or self.__tag.name=="move_simple" then
        return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)})
    else
        local t1,t2 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
        if not coerce then
             assert(t1<=t2, string.format("Error: move times must evaluate to t1<=t2, got %d<=%d.\n", t1,t2))
        end
        return returnAll({self.startPos:getTagParams(coerce)}, {self.endPos:getTagParams(coerce)},
                         {math.min(t1,t2)}, {math.max(t2,t1)})
    end
end

function ASSMove:setSimple(state)
    if state==nil then
        state = self.startTime==0 and self.endTime==0
    end
    self.__tag.simple, self.__tag.name = state, state and "move_simple" or "move"
    return state
end

ASSString = createASSClass("ASSString", {ASSTagBase, ASSStringBase}, {"value"}, {"string"})

function ASSString:getTagParams(coerce)
    return coerce and tostring(self.value) or self:typeCheck(self.value)
end
ASSString.add, ASSString.mul, ASSString.pow = ASSString.append, nil, nil


ASSToggle = createASSClass("ASSToggle", ASSTagBase, {"value"}, {"boolean"})
function ASSToggle:new(args)
    self.value = self:getArgs(args,false,true)
    self:readProps(args)
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

function ASSAlign:centerV()
    if self.value<=3 then self:up()
    elseif self.value>=7 then self:down() end
end

function ASSAlign:centerH()
    if self.value%3==1 then self:right()
    elseif self.value%3==0 then self:left() end
end

function ASSAlign:getSet(pos)
    local val = self.value
    local set = { top = val>=7, centerV = val>3 and val<7, bottom = val<=3,
                  left = val%3==1, centerH = val%3==2, right = val%3==0 }
    return pos==nil and set or set[pos]
end

function ASSAlign:isTop() return self:getSet("top") end
function ASSAlign:isCenterV() return self:getSet("centerV") end
function ASSAlign:isBottom() return self:getSet("bottom") end
function ASSAlign:isLeft() return self:getSet("left") end
function ASSAlign:isCenterH() return self:getSet("centerH") end
function ASSAlign:isRight() return self:getSet("right") end

ASSWeight = createASSClass("ASSWeight", ASSTagBase, {"weightClass","bold"}, {ASSNumber,ASSToggle})
function ASSWeight:new(args)
    local weight, bold = self:getArgs(args,{0,false},true)
                    -- also support signature ASSWeight{bold} without weight
    if args.raw or (#args==1 and not ASS.instanceOf(args[1], ASSWeight)) then
        weight, bold = weight~=1 and weight or 0, weight==1
    end
    self:readProps(args)
    self.bold = ASSToggle{bold}
    self.weightClass = ASSNumber{weight, tagProps={positive=true, precision=0}}
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

function ASSWeight:toggle()
    self.bold:toggle()
end

function ASSWeight:setWeight(weightClass)
    self.bold:set(false)
    self.weightClass:set(weightClass or 400)
end

ASSWrapStyle = createASSClass("ASSWrapStyle", ASSIndexed, {"value"}, {"number"}, {range={0,3}, default=0})


ASSClipRect = createASSClass("ASSClipRect", ASSTagBase, {"topLeft", "bottomRight"}, {ASSPoint, ASSPoint})

function ASSClipRect:new(args)
    local left, top, right, bottom = self:getArgs(args, 0, true)
    self:readProps(args)

    self.topLeft = ASSPoint{left, top}
    self.bottomRight = ASSPoint{right, bottom}
    self:setInverse(self.__tag.inverse or false)
    return self
end

function ASSClipRect:getTagParams(coerce)
    self:setInverse(self.__tag.inverse or false)
    return returnAll({self.topLeft:getTagParams(coerce)}, {self.bottomRight:getTagParams(coerce)})
end

function ASSClipRect:setInverse(state)
    state = type(state)==nil and true or state
    self.__tag.inverse = state
    self.__tag.name = state and "iclip_rect" or "clip_rect"
    return state
end

function ASSClipRect:toggleInverse()
    return self:setInverse(not self.__tag.inverse)
end


--------------------- Drawing Classes ---------------------

ASSDrawing = createASSClass("ASSDrawing", ASSTagBase, {"commands"}, {"table"})
function ASSDrawing:new(args)
    -- TODO: support alternative signature for ASSLineDrawingSection
    local cmdMap = ASS.classes.drawingCommandMappings
    
    self.commands = {}
    -- construct from a compatible object
    -- note: does copy
    if ASS.instanceOf(args[1], ASSDrawing, nil, true) then
        local copy = args[1]:copy()
        self.commands, self.scale = copy.commands, copy.scale
        self.__tag.inverse = copy.__tag.inverse
    -- construct from a single string of drawing commands
    elseif args.raw or args.str then
        self.scale = ASS:createTag("drawing", args.scale or 1)
        local cmdParts, cmdType, prmCnt, i, j = (args.str or args.raw[1]):split(" "), "", 0, 1, 1
        while i<=#cmdParts do
            if cmdMap[cmdParts[i]]==ASSDrawClose then
                self.commands[j] = ASSDrawClose()
                self.commands[j].parent, i, j = self, i+1, j+1
            elseif cmdMap[cmdParts[i]] then
                cmdType = cmdParts[i]
                prmCnt, i = cmdMap[cmdType].__defProps.ords, i+1
            else
                local prms = table.sliceArray(cmdParts,i,i+prmCnt-1)
                self.commands[j] = cmdMap[cmdType](unpack(prms))
                self.commands[j].parent = self
                i, j = i+prmCnt, j+1
            end
        end
    else
    -- construct from valid drawing commands, also accept tables of drawing commands
    -- note: doesn't copy
        self.scale = ASS:createTag("drawing", args.scale or 1)
        local j=1
        for i=1,#args do
            if ASS.instanceOf(args[i],ASS.classes.drawingCommands) then
                self.commands[j], j = args[i], j+1
            elseif type(args[i])=="table" and not args[i].instanceOf then
                for k=1,#args[i] do
                    assert(ASS.instanceOf(args[i][k],ASS.classes.drawingCommands), 
                           string.format("Error: argument #%d to %s contains invalid drawing objects (#%d is a %s).",
                                         i, self.typeName, k, ASS.instanceOf(args[i][k]) or type(args[i][k])
                           ))
                    self.commands[j], j = args[i][k], j+1
                end
            else error(string.format("Error: argument #%d to %s is not a valid drawing object, got a %s.",
                                      i, self.typeName, ASS.instanceOf(args[i]) or type(args[i])))
            end
        end
    end
    self:readProps(args)
    return self
end

function ASSDrawing:getTagParams(coerce)
    local cmds, cmdStr, j, lastCmdType = self.commands, {}, 1
    for i=1,#cmds do
        if lastCmdType~=cmds[i].__tag.name then
            lastCmdType = cmds[i].__tag.name
            cmdStr[j], j = lastCmdType, j+1
        end
        local params = table.concat({cmds[i]:get(coerce)}," ")
        if params~="" then 
            cmdStr[j], j = params, j+1
        end
    end
    return table.concat(cmdStr, " "), self.scale:getTagParams(coerce)
end

function ASSDrawing:commonOp(method, callback, default, x, y) -- drawing commands only have x and y in common
    if ASS.instanceOf(x, ASSPoint) then
        x, y = x:get()
    end
    local res = {}
    for i=1,#self.commands do
        local subCnt = #self.commands[i].__meta__.order
        res = table.join(res,{self.commands[i][method](self.commands[i],x,y)})
    end
    return unpack(res)
end

function ASSDrawing:flatten(coerce)
    local flatStr = YUtils.shape.flatten(self:getTagParams(coerce))
    local flattened = ASSDrawing{raw=flatStr, tagProps=self.__tag}
    self.commands = flattened.commands
    return self, flatStr
end

function ASSDrawing:getLength()
    local totalLen,lens = 0, {}
    for i=1,#self.commands do
        local len = self.commands[i]:getLength(self.commands[i-1])
        lens[i], totalLen = len, totalLen+len
    end
    self.length = totalLen
    return totalLen,lens
end

function ASSDrawing:getCommandAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local cmds, currTotalLen, nextTotalLen = self.commands,  0
    for i=1,#cmds do
        nextTotalLen = currTotalLen + cmds[i].length
        if nextTotalLen-len > -0.001 and cmds[i].length>0 and not (cmds[i].instanceOf[ASSDrawMove] or cmds[i].instanceOf[ASSDrawMoveNc]) then
            return cmds[i], math.max(len-currTotalLen,0)
        else currTotalLen = nextTotalLen end
    end
    return false
    -- error(string.format("Error: length requested (%02f) is exceeding the total length of the shape (%02f)",len,currTotalLen))
end

function ASSDrawing:getPositionAtLength(len, noUpdate, useCurveTime)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen  = self:getCommandAtLength(len, true)
    if not cmd then return false end
    return cmd:getPositionAtLength(remLen, true, useCurveTime)
end

function ASSDrawing:getAngleAtLength(len, noUpdate)
    if not (noUpdate and self.length) then self:getLength() end
    local cmd, remLen = self:getCommandAtLength(len, true)
    if not cmd then return false end

    if cmd.instanceOf[ASSDrawBezier] then
        cmd = cmd.flattened:getCommandAtLength(remLen, true)
    end
    return cmd:getAngle(nil,true)
end

function ASSDrawing:outline(x,y,mode)
    y, mode = default(y,x), default(mode, "round")
    local outline = YUtils.shape.to_outline(YUtils.shape.flatten(self:getTagParams()),x,y,mode)
    self.commands = ASS.instanceOf(self)({outline}).commands
end
function ASSDrawing:rotate(angle)
    angle = default(angle,0)
    if ASS.instanceOf(angle,ASSNumber) then
        angle = angle:getTagParams(coerce)
    else assert(type(angle)=="number", 
         string.format("Error: argument #1 (angle) to rotate() must be either a number or a %s object, got a %s",
         ASSNumber.typeName, ASS.instanceOf(angle) and ASS.instanceOf(angle).typeName or type(angle)))
    end 

    if angle%360~=0 then
        local shape = self:getTagParams()
        local bound = {YUtils.shape.bounding(shape)}
        local rotMatrix = YUtils.math.create_matrix().
                          translate((bound[3]-bound[1])/2,(bound[4]-bound[2])/2,0).rotate("z",angle).
                          translate(-bound[3]+bound[1]/2,(-bound[4]+bound[2])/2,0)
        shape = YUtils.shape.transform(shape,rotMatrix)
        self.commands = ASSDrawing{raw=shape}.commands
    end
    return self
end

function ASSDrawing:get()
    local commands, j = {}, 1
    for i=1,#self.commands do
        commands[j] = self.commands[i].__tag.name
        local params = {self.commands[i]:get()}
        table.joinInto(commands, params)
        j=j+#params+1
    end
    return commands, self.scale:get()
end

function ASSDrawing:getSection()
    local section = ASSLineDrawingSection{}
    section.commands, section.scale = self.commands, self.scale
    return section
end

ASSDrawing.set, ASSDrawing.mod = nil, nil  -- TODO: check if these can be remapped/implemented in a way that makes sense, maybe work on strings


ASSClipVect = createASSClass("ASSClipVect", ASSDrawing, {"commands","scale"}, {"table", ASSNumber}, {}, {ASSDrawing})
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


ASSLineDrawingSection = createASSClass("ASSLineDrawingSection", ASSDrawing, {"commands","scale"}, {"table", ASSNumber}, {}, {ASSDrawing, ASSClipVect})
ASSLineDrawingSection.getStyleTable = ASSLineTextSection.getStyleTable
ASSLineDrawingSection.getEffectiveTags = ASSLineTextSection.getEffectiveTags
ASSLineDrawingSection.getString = ASSLineDrawingSection.getTagParams
ASSLineDrawingSection.getTagString = nil

function ASSLineDrawingSection:getBounds(coerce)
    local bounds = {YUtils.shape.bounding(self:getString())}
    bounds.width = (bounds[3] or 0)-(bounds[1] or 0)
    bounds.height = (bounds[4] or 0)-(bounds[2] or 0)
    return bounds
end


--------------------- Unsupported Tag Classes and Stubs ---------------------

ASSUnknown = createASSClass("ASSUnknown", ASSString, {"value"}, {"string"})
ASSUnknown.add, ASSUnknown.sub, ASSUnknown.mul, ASSUnknown.pow = nil, nil, nil, nil

ASSTransform = createASSClass("ASSTransform", ASSTagBase, {"tags", "startTime", "endTime", "accel"}, 
                                                          {ASSLineTagSection, ASSTime, ASSTime, ASSNumber})

function ASSTransform:new(args)
    self:readProps(args)
    local types, tagName = ASS.tagTypes.ASSTransform, self.__tag.name
    if args.raw then
        local r = {}
        if tagName == types[1] then        -- \t(<accel>,<style modifiers>)
            r[1], r[4] = args.raw[1], args.raw[2]
        elseif stagName == types[2] then    -- \t(<t1>,<t2>,<accel>,<style modifiers>)
            r[1], r[2], r[3], r[4] = args.raw[4], args.raw[1], args.raw[2], args.raw[3]
        elseif tagName == types[4] then    -- \t(<t1>,<t2>,<style modifiers>)
            r[1], r[2], r[3] = args.raw[3], args.raw[1], args.raw[2]
        else r = args.raw end
        args.raw = r
    end
    tags, startTime, endTime, accel = self:getArgs(args,{"",0,0,1},true)

    self.tags, self.accel = ASSLineTagSection(tags,args.transformableOnly), ASSNumber{accel, tagProps={positive=true}}
    self.startTime, self.endTime = ASSTime{startTime}, ASSTime{endTime}
    return self
end

function ASSTransform:changeTagType(type_)
    local types = ASS.tagTypes.ASSTransform
    if not type_ then
        local noTime = self.startTime==0 and self.endTime==0
        self.__tag.name = self.accel==1 and (noTime and types[3] or types[4]) or noTime and types[1] or types[3]
        self.__tag.typeLocked = false
    else
        assert(types[type], "Error: invalid transform type: " .. tostring(type))
        self.__tag.name, self.__tag.typeLocked = type_, true
    end
    return self.__tag.name, self.__tag.typeLocked
end

function ASSTransform:getTagParams(coerce)
    local types, tagName = ASS.tagTypes.ASSTransform, self.__tag.name

    if not self.__tag.typeLocked then
        self:changeTagType()
    end

    local t1, t2 = self.startTime:getTagParams(coerce), self.endTime:getTagParams(coerce)
    if coerce then
        t2 = util.max(t1, t2)
    else assert(t1<=t2, string.format("Error: transform start time must not be greater than the end time, got %d <= %d", t1, t2)) end

    if tagName == types[3] then
        return self.tags:getString(coerce)
    elseif tagName == types[1] then
        return self.accel:getTagParams(coerce), self.tags:getString(coerce)
    elseif tagName == types[4] then
        return t1, t2, self.tags:getString(coerce)
    elseif tagName == types[2] then
        return t1, t2, self.accel:getTagParams(coerce), self.tags:getString(coerce)
    else error("Error: invalid transform type: " .. tostring(type)) end

end
--------------------- Drawing Command Classes ---------------------

ASSDrawBase = createASSClass("ASSDrawBase", ASSTagBase, {}, {})
function ASSDrawBase:new(...)
    local args = {...}
    args = {self:getArgs(args, 0, true)}

    if self.compatible[ASSPoint] then
        self.x, self.y = ASSNumber{args[1]}, ASSNumber{args[2]}
    else
        for i=1,#args,2 do
            local j = (i+1)/2
            self[self.__meta__.order[j]] = self.__meta__.types[j]{args[i],args[i+1]}
        end
    end
    return self
end

function ASSDrawBase:getTagParams(coerce)
    local params, parts = self.__meta__.order, {}
    for i=2,#params*2,2 do
        parts[i], parts[i+1] = self[params[i/2]]:getTagParams(coerce)
    end
    parts[1] = self.__tag.name
    return table.concat(parts, " ")
end

function ASSDrawBase:getLength(prevCmd) 
    -- get end coordinates (cursor) of previous command
    local x0, y0 = 0, 0
    if prevCmd and prevCmd.__tag.name == "b" then
        x0, y0 = prevCmd.p3:get()
    elseif prevCmd then x0, y0 = prevCmd:get() end

    -- save cursor for further processing
    self.cursor = ASSPoint{x0, y0}

    local name, len = self.__tag.name, 0
    if name == "b" then
        local shapeSection = ASSDrawing{ASSDrawMove(self.cursor:get()),self}
        self.flattened = ASSDrawing{str=YUtils.shape.flatten(shapeSection:getTagParams())} --save flattened shape for further processing
        len = self.flattened:getLength()
    elseif name =="m" or name == "n" then len=0
    elseif name =="l" then
        local x, y = self:get()
        len = YUtils.math.distance(x-x0, y-y0)
    end
    -- save length for further processing
    self.length = len
    return len
end

function ASSDrawBase:getPositionAtLength(len, noUpdate, useCurveTime)
    if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
    local name, pos = self.__tag.name
    if name == "b" and useCurveTime then
        local px, py = YUtils.math.bezier(math.min(len/self.length,1), {{self.cursor:get()},{self.p1:get()},{self.p2:get()},{self.p3:get()}})
        pos = ASSPoint{px, py}
    elseif name == "b" then
        pos = self:getFlattened(true):getPositionAtLength(len, true)   -- we already know this data is up-to-date because self.parent:getLength() was run
    elseif name == "l" then
        pos = ASSPoint{self:copy():ScaleToLength(len,true)}
    elseif name == "m" then
        pos = ASSPoint{self}
    end
    pos.__tag.name = "position"
    return pos
end

ASSDrawMove = createASSClass("ASSDrawMove", ASSDrawBase, {"x", "y"}, {ASSNumber, ASSNumber}, {name="m", ords=2}, {ASSPoint})
ASSDrawMoveNc = createASSClass("ASSDrawMoveNc", ASSDrawBase, {"x", "y"}, {ASSNumber, ASSNumber}, {name="n", ords=2}, {ASSDrawMove, ASSPoint})
ASSDrawLine = createASSClass("ASSDrawLine", ASSDrawBase, {"x", "y"}, {ASSNumber, ASSNumber}, {name="l", ords=2}, {ASSPoint, ASSDrawMove, ASSDrawMoveNc})
ASSDrawBezier = createASSClass("ASSDrawBezier", ASSDrawBase, {"p1","p2","p3"}, {ASSPoint, ASSPoint, ASSPoint}, {name="b", ords=6})
ASSDrawClose = createASSClass("ASSDrawClose", ASSDrawBase, {}, {}, {name="c", ords=0})
--- TODO: b-spline support

function ASSDrawLine:ScaleToLength(len,noUpdate)
    if not (self.length and self.cursor and noUpdate) then self.parent:getLength() end
    local scaled = self.cursor:copy()
    scaled:add(YUtils.math.stretch(returnAll(
        {ASSPoint{self}:sub(self.cursor)},
        {0, len})
    ))
    self:set(scaled:get())
    return self:get()
end

function ASSDrawLine:getAngle(ref, noUpdate)
    if not (ref or (self.cursor and noUpdate)) then self.parent:getLength() end
    local ref, rx, ry = ref or self.cursor
    assert(type(ref)=="table", "Error: argument ref to getAngle() must be of type table, got " .. type(ref) .. ".\n")
    if ref.instanceOf[ASSDrawBezier] then
        rx, ry = ref.p3:get()
    elseif not ref.instanceOf then
        rx, ry = ref[1], ref[2]
    elseif ref.compatible[ASSPoint] then
        rx, ry = ref:get()
    else error("Error: argument ref to getAngle() must either be an ASSDraw object, an ASSPoint or a table containing coordinates x and y.\n")
    end
    local dx, dy = self.x.value-rx, self.y.value-ry
    return ASS:createTag("angle", 360 - math.deg(math.atan2(dy,dx)))
end

function ASSDrawBezier:commonOp(method, callback, default, ...)
    local args, j, res, valNames = {...}, 1, {}, self.__meta__.order
    if #args<=2 then -- special case to allow common operation on all x an y values of a vector drawing
        args[1], args[2] = args[1] or 0, args[2] or 0
        args = table.join(args,args,args)
    end
    args = {self:getArgs(args, default, false)}
    for i=1,#valNames do
        local subCnt = #self[valNames[i]].__meta__.order
        local subArgs = table.sliceArray(args,j,j+subCnt-1)
        table.joinInto(res, {self[valNames[i]][method](self[valNames[i]],unpack(subArgs))})
        j=j+subCnt
    end
    return unpack(res)
end

function ASSDrawBezier:getFlattened(noUpdate)
    if not (noUpdate and self.flattened) then
        if not (noUpdate and self.cursor) then
            self.parent:getLength()
        end
        local shapeSection = ASSDrawing{ASSDrawMove(self.cursor:get()),self}
        self.flattened = ASSDrawing{str=YUtils.shape.flatten(shapeSection:getTagParams())}
    end
    return self.flattened
end



----------- Tag Mapping -------------

ASSFoundation = createASSClass("ASSFoundation")
function ASSFoundation:new()
    local tagMap = {
        scale_x= {overrideName="\\fscx", type=ASSNumber, pattern="\\fscx([%d%.]+)", format="\\fscx%.3N", props={transformable=true}},
        scale_y = {overrideName="\\fscy", type=ASSNumber, pattern="\\fscy([%d%.]+)", format="\\fscy%.3N", props={transformable=true}},
        align = {overrideName="\\an", type=ASSAlign, pattern="\\an([1-9])", format="\\an%d", props={global=true}},
        angle = {overrideName="\\frz", type=ASSNumber, pattern="\\frz?([%-%d%.]+)", format="\\frz%.3N", props={transformable=true, mod=360}}, 
        angle_y = {overrideName="\\fry", type=ASSNumber, pattern="\\fry([%-%d%.]+)", format="\\fry%.3N", default={0}, props={transformable=true, mod=360}},
        angle_x = {overrideName="\\frx", type=ASSNumber, pattern="\\frx([%-%d%.]+)", format="\\frx%.3N", default={0}, props={transformable=true, mod=360}}, 
        outline = {overrideName="\\bord", type=ASSNumber, props={positive=true, transformable=true}, pattern="\\bord([%d%.]+)", format="\\bord%.2N"}, 
        outline_x = {overrideName="\\xbord", type=ASSNumber, props={positive=true, transformable=true}, pattern="\\xbord([%d%.]+)", format="\\xbord%.2N"}, 
        outline_y = {overrideName="\\ybord", type=ASSNumber,props={positive=true, transformable=true}, pattern="\\ybord([%d%.]+)", format="\\ybord%.2N"}, 
        shadow = {overrideName="\\shad", type=ASSNumber, pattern="\\shad([%-%d%.]+)", format="\\shad%.2N", props={transformable=true}}, 
        shadow_x = {overrideName="\\xshad", type=ASSNumber, pattern="\\xshad([%-%d%.]+)", format="\\xshad%.2N", props={transformable=true}}, 
        shadow_y = {overrideName="\\yshad", type=ASSNumber, pattern="\\yshad([%-%d%.]+)", format="\\yshad%.2N", props={transformable=true}}, 
        reset = {overrideName="\\r", type=ASSString, pattern="\\r([^\\}]*)", format="\\r%s", props={transformable=true}}, 
        alpha = {overrideName="\\alpha", type=ASSHex, pattern="\\alpha&H(%x%x)&", format="\\alpha&H%02X&", default={0}, props={transformable=true}}, 
        alpha1 = {overrideName="\\1a", type=ASSHex, pattern="\\1a&H(%x%x)&", format="\\1a&H%02X&", props={transformable=true}}, 
        alpha2 = {overrideName="\\2a", type=ASSHex, pattern="\\2a&H(%x%x)&", format="\\2a&H%02X&", props={transformable=true}}, 
        alpha3 = {overrideName="\\3a", type=ASSHex, pattern="\\3a&H(%x%x)&", format="\\3a&H%02X&", props={transformable=true}}, 
        alpha4 = {overrideName="\\4a", type=ASSHex, pattern="\\4a&H(%x%x)&", format="\\4a&H%02X&", props={transformable=true}}, 
        color = {overrideName="\\c", type=ASSColor, props={name="color1", transformable=true}},
        color1 = {overrideName="\\1c", friendlyName="\\1c & \\c", type=ASSColor, pattern="\\1?c&H(%x%x)(%x%x)(%x%x)&", format="\\1c&H%02X%02X%02X&",  props={transformable=true}},
        color2 = {overrideName="\\2c", type=ASSColor, pattern="\\2c&H(%x%x)(%x%x)(%x%x)&", format="\\2c&H%02X%02X%02X&", props={transformable=true}},
        color3 = {overrideName="\\3c", type=ASSColor, pattern="\\3c&H(%x%x)(%x%x)(%x%x)&", format="\\3c&H%02X%02X%02X&", props={transformable=true}},
        color4 = {overrideName="\\4c", type=ASSColor, pattern="\\4c&H(%x%x)(%x%x)(%x%x)&", format="\\4c&H%02X%02X%02X&", props={transformable=true}},
        clip_vect = {overrideName="\\clip", friendlyName="\\clip (Vector)", type=ASSClipVect, pattern="\\clip%(([mnlbspc] .-)%)", 
                     format="\\clip(%s)", props={global=true}}, 
        iclip_vect = {overrideName="\\iclip", friendlyName="\\iclip (Vector)", type=ASSClipVect, props={inverse=true, global=true}, 
                      pattern="\\iclip%(([mnlbspc] .-)%)", format="\\iclip(%s)", default={"m 0 0 l 0 0 0 0 0 0 0 0"}},
        clip_rect = {overrideName="\\clip", friendlyName="\\clip (Rectangle)", type=ASSClipRect, props={transformable=true, global=false}, 
                     pattern="\\clip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\clip(%.2N,%.2N,%.2N,%.2N)"}, 
        iclip_rect = {overrideName="\\iclip", friendlyName="\\iclip (Rectangle)", type=ASSClipRect, props={inverse=true, global=false, transformable=true}, 
                      pattern="\\iclip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\iclip(%.2N,%.2N,%.2N,%.2N)", default={0,0,0,0}}, 
        drawing = {overrideName="\\p", type=ASSNumber, props={positive=true, precision=0}, pattern="\\p(%d+)", format="\\p%d", default={0}}, 
        blur_edges = {overrideName="\\be", type=ASSNumber, props={positive=true, transformable=true}, pattern="\\be([%d%.]+)", format="\\be%.2N", default={0}}, 
        blur = {overrideName="\\blur", type=ASSNumber, props={positive=true, transformable=true}, pattern="\\blur([%d%.]+)", format="\\blur%.2N", default={0}}, 
        shear_x = {overrideName="\\fax", type=ASSNumber, pattern="\\fax([%-%d%.]+)", format="\\fax%.2N", default={0}, props={transformable=true}}, 
        shear_y = {overrideName="\\fay", type=ASSNumber, pattern="\\fay([%-%d%.]+)", format="\\fay%.2N", default={0}, props={transformable=true}}, 
        bold = {overrideName="\\b", type=ASSWeight, pattern="\\b(%d+)", format="\\b%d"}, 
        italic = {overrideName="\\i", type=ASSToggle, pattern="\\i([10])", format="\\i%d"}, 
        underline = {overrideName="\\u", type=ASSToggle, pattern="\\u([10])", format="\\u%d"},
        strikeout = {overrideName="\\s", type=ASSToggle, pattern="\\s([10])", format="\\s%d"},
        spacing = {overrideName="\\fsp", type=ASSNumber, pattern="\\fsp([%-%d%.]+)", format="\\fsp%.2N", props={transformable=true}},
        fontsize = {overrideName="\\fs", type=ASSNumber, props={positive=true, transformable=true}, pattern="\\fs([%d%.]+)", format="\\fs%.2N"},
        fontname = {overrideName="\\fn", type=ASSString, pattern="\\fn([^\\}]*)", format="\\fn%s"},
        k_fill = {overrideName="\\k", type=ASSDuration, props={scale=10}, pattern="\\k([%d]+)", format="\\k%d", default={0}},
        k_sweep = {overrideName="\\kf", type=ASSDuration, props={scale=10}, pattern="\\kf([%d]+)", format="\\kf%d", default={0}},
        k_sweep_alt = {overrideName="\\K", type=ASSDuration, props={scale=10}, pattern="\\K([%d]+)", format="\\K%d", default={0}},
        k_bord = {overrideName="\\ko", type=ASSDuration, props={scale=10}, pattern="\\ko([%d]+)", format="\\ko%d", default={0}},
        position = {overrideName="\\pos", type=ASSPoint, pattern="\\pos%(([%-%d%.]+),([%-%d%.]+)%)", format="\\pos(%.3N,%.3N)", props={global=true}},
        move_simple = {overrideName="\\move", friendlyName="\\move (Simple)", type=ASSMove, props={simple=true, global=true},  
                       pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\move(%.3N,%.3N,%.3N,%.3N)"},
        move = {overrideName="\\move", type=ASSMove, friendlyName="\\move (w/ Time)", props={global=true}, 
                pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),(%d+),(%d+)%)", format="\\move(%.3N,%.3N,%.3N,%.3N,%.3N,%.3N)"},
        origin = {overrideName="\\org", type=ASSPoint, pattern="\\org%(([%-%d%.]+),([%-%d%.]+)%)", format="\\org(%.3N,%.3N)", props={global=true}},
        wrapstyle = {overrideName="\\q", type=ASSWrapStyle, pattern="\\q(%d)", format="\\q%d", default={0}, props={global=true}},
        fade_simple = {overrideName="\\fad", type=ASSFade, props={simple=true, global=true}, pattern="\\fad%((%d+),(%d+)%)",
                       format="\\fad(%d,%d)", default={0,0}},
        fade = {overrideName="\\fade", type=ASSFade, pattern="\\fade%((.-)%)", format="\\fade(%d,%d,%d,%d,%d,%d,%d)",
                default={255,0,255,0,0,0,0}, props={global=true}},
        transform_simple = {overrideName="\\t", type=ASSTransform, pattern="\\t%(([^,]+)%)", format="\\t(%s)"}, 
        transform_accel = {overrideName="\\t", type=ASSTransform, pattern="\\t%(([%d%.]+),([^,]+)%)", format="\\t(%.2N,%s)"}, 
        transform_time = {overrideName="\\t", type=ASSTransform, pattern="\\t%(([%-%d]+),([%-%d]+),([^,]+)%)", format="\\t(%.2N,%.2N,%s)"}, 
        transform_complex = {overrideName="\\t", type=ASSTransform, pattern="\\t%(([%-%d]+),([%-%d]+),([%d%.]+),([^,]+)%)", format="\\t(%.2N,%.2N,%.2N,%s)"}, 
        unknown = {type=ASSUnknown, format="%s", friendlyName="Unknown Tag"},
        junk = {type=ASSUnknown, format="%s", friendlyName="Junk"}
    }

    local toFriendlyName, toTagName, i = {}, {}

    for name,tag in pairs(tagMap) do
        -- insert tag name into props
        tag.props = tag.props or {}
        tag.props.name = tag.props.name or name
        -- generate properties for treating rectangular clips as global tags
        tag.props.globalOrRectClip = tag.props.global or tag.type==ASSClipRect
        -- fill in missing friendly names
        tag.friendlyName = tag.friendlyName or tag.overrideName
        -- populate friendly name <-> tag name conversion tables
        if tag.friendlyName then
            toFriendlyName[name], toTagName[tag.friendlyName] = tag.friendlyName, name 
        end
    end

    self.tagMap, self.toFriendlyName, self.toTagName = tagMap, toFriendlyName, toTagName

    self.classes = {
        lineSection = {ASSLineTextSection, ASSLineTagSection, ASSLineDrawingSection, ASSLineCommentSection},
        drawingCommandMappings = {
            m = ASSDrawMove,
            n = ASSDrawMoveNc,
            l = ASSDrawLine,
            b = ASSDrawBezier,
            c = ASSDrawClose
        }
    }
    self.classes.drawingCommands = table.values(self.classes.drawingCommandMappings)

    -- TODO: dynamically generate this table
    self.tagTypes = {
        all = table.keys(self.tagMap),
        clips = {"clip_rect", "iclip_rect", "clip_vect", "iclip_vect"},
        ASSTransform = {"transform_accel", "transform_complex", "transform_simple", "transform_time", "transform"},
        ASSClipRect = {"clip_rect", "iclip_rect"}
    }

    for _,tagType in pairs(self.tagTypes) do
        for i=1,#tagType do
            tagType[tagType[i]] = true
        end
    end

    return self
end

function ASSFoundation:getTagNames(overrideName)
    if self.tagMap[overrideName] then return name
    else
        local tagNames = {}
        for key,val in pairs(self.tagMap) do
            tagNames[#tagNames+1] = val.overrideName==name and key
        end
    end
    return tagNames
end

function ASSFoundation:mapTag(name)
    assert(type(name)=="string", "Error: argument 1 to mapTag() must be a string, got a " .. type(name))
    return assert(self.tagMap[name],"Error: can't find tag " .. name)
end

function ASSFoundation:createTag(name, ...)
    local tag = self:mapTag(name)
    return tag.type{tagProps=tag.props, ...} 
end

function ASSFoundation:getTagFromString(str)
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
    return ASSUnknown{str, tagProps=tagType.props}, 1, #str
end

function ASSFoundation:formatTag(tagRef, ...)
    return self:mapTag(tagRef.__tag.name).format:formatFancy(...)
end

function ASSFoundation.instanceOf(val, classes, filter, includeCompatible)
    local clsSetObj = type(val)=="table" and val.instanceOf

    if not clsSetObj then
        return false
    elseif classes==nil then
        return table.keys(clsSetObj)[1], includeCompatible and table.keys(val.compatible)
    elseif type(classes)~="table" or classes.instanceOf then
        classes = {classes}
    end

    if type(filter)=="table" then
        if filter.instanceOf then 
            filter={[filter]=true} 
        elseif #filter>0 then 
            filter = table.set(filter)
        end
    end
    for i=1,#classes do 
        if (clsSetObj[classes[i]] or includeCompatible and val.compatible[classes[i]]) and (not filter or filter[classes[i]]) then
            return classes[i]
        end
    end
    return false
end

function ASSFoundation.parse(line)
    line.ASS = ASSLineContents(line)
    return line.ASS
end

ASS = ASSFoundation()