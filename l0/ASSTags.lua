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

        if type(valTypes[i])=="table" and valTypes[i].instanceOf then
            local subCnt = #valTypes[i].__meta__.order
            outArgs = table.join(outArgs, {valTypes[i]:getArgs(table.sliceArray(args,j,j+subCnt-1), default, coerce)})
            j=j+subCnt-1

        elseif coerce then
            local tagProps = self.__tag or self.__defProps
            local map = {
                number = function() return tonumber(args[j],tagProps.base or 10)*(tagProps.scale or 1) end,
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
        if type(val)=="table" and val.instanceOf then
            newObj[key] = val:copy()
        elseif key=="__tag" or (meta and table.find(self.__meta__.order,key) and type(val)=="table") then
            newObj[key]=ASSBase.copy(val)
        else newObj[key]=val end
    end
    return newObj
end

function ASSBase:typeCheck(...)
    local valTypes, j, args = self.__meta__.types, 1, {...}
    --assert(#valNames >= #args, string.format("Error: too many arguments. Expected %d, got %d.\n",#valNames,#args))
    for i,valName in ipairs(self.__meta__.order) do
        if type(valTypes[i])=="table" and valTypes[i].instanceOf then
            if type(args[j])=="table" and args[j].instanceOf then
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
        if type(self[valName])=="table" and self[valName].instanceOf then
            for _,cval in pairs({self[valName]:get()}) do vals[#vals+1]=cval end
        else 
            vals[#vals+1] = self[valName]
        end
    end
    return unpack(vals)
end

function ASSBase:remove(returnCopy)
    local copy = returnCopy and ASSBase:copy() or true
    self = nil
    return copy
end

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
    return self
end

function ASSLineContents:getString(coerce, noTags, noText)
    local str = ""
    for i,section in ipairs(self.sections) do
        if section.instanceOf[ASSLineTextSection] and not noText then
            str = str .. section:getString()
        elseif section.instanceOf[ASSLineTagSection] and not noTags then
            str =  string.format("%s{%s}",str,section:getString())
        else 
            eval(coerce, string.format("Error: %s section #%d is not a %d or %d.\n", self.typeName, i, ASSLineTextSection.typeName, ASSLineTagSection.typeName)) 
        end
    end
    return str
end

function ASSLineContents:get(noTags, noText, start, end_, relative)
    local start, end_, result, j = start or 1, end_ or #self.sections, {}, 1
    self:callback(function(section,sections,i)
        if relative and j>=start and j<=end_ then
            table.insert(result,section:copy())
        elseif i>=start and i<=end_ then
            table.insert(result, section:copy())
        end
        j=j+1
    end, noTags, noText)
    return result
end

function ASSLineContents:callback(callback, noTags, noText)
    local hasRun = false
    for i,section in ipairs(self.sections) do
        if (section.instanceOf[ASSLineTagSection] and not noTags) or (section.instanceOf[ASSLineTextSection] and not noText) then
            local result, hasRun = callback(section,self.sections,i), true
            if result==false then
                self.sections[i]:remove()
            elseif type(result)~="nil" and result~=true then
                self.sections[i] = result
            end
        end
    end
    self.sections = table.trimArray(self.sections)
    return hasRun
end

function ASSLineContents:stripTags()
    self:callback(function(section,sections,i)
        return false
    end, false, true)
    return self
end

function ASSLineContents:stripText()
    self:callback(function(section,sections,i)
        return false
    end, true, false)
    return self
end

function ASSLineContents:commit(line)
    line = line or self.line
    line.text = self:getString()
    return line.text
end

function ASSLineContents:deduplicateTags() -- STUB! TODO: actually make it deduplicate tags and not just merge sections
    local lastTagSection, numMerged = 1, 0
    self:callback(function(section,sections,i)
        if i==lastTagSection+numMerged+1 then
            sections[lastTagSection].value = sections[lastTagSection].value .. section.value -- FIXFORTAGCHANGES
            numMerged = numMerged+1
            return false
        else 
            lastTagSection, numMerged = i, 0 
        end
    end, false, true)
end

function ASSLineContents:splitAtTags()
    local splitLines = {}
    self:callback(function(section,sections,i)
        local splitLine = Line(self.line)
        splitLine.ASS = ASSLineContents(splitLine, table.insert(self:get(false,true,0,i),section))
        splitLine.ASS:deduplicateTags()
        splitLine.ASS:commit()
        table.insert(splitLines,splitLine)
    end,true)
    return splitLines
end

function ASSLineContents:splitAtIntervals(callback)
    if type(callback)=="number" then
        local step=callback
        callback = function(idx,len)
            return idx+step
        end
    else assert(type(callback)=="function", "Error: first argument to splitAtIntervals must be either a number or a callback function.\n") end
    
    local len, idx, sectEndIdx, nextIdx, lastI = self:copy():stripTags():getString(), 1, 0, 0
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
            local addSections, lastContents = table.insert(self:get(false,true,lastI+1,i), addTextSection), splitLines[#splitLines].ASS
            lastContents.sections = table.join(lastContents.sections, addSections)
            lastContents:commit()
        end
            
        while idx <= sectEndIdx do
            nextIdx = math.ceil(callback(idx,len))
            assert(nextIdx>idx, "Error: callback function for splitAtIntervals must always return an index greater than the last index.")
            -- create a new line
            local splitLine = Line(self.line)
            splitLine.ASS = ASSLineContents(splitLine, self:get(false,true,0,i))
            table.insert(splitLine.ASS.sections, ASSLineTextSection(text:sub(idx-off,nextIdx-off-1)))
            splitLine.ASS:deduplicateTags()
            splitLine.ASS:commit()
            table.insert(splitLines,splitLine)        

            -- check if this section is long enough to fill the new line
            idx = sectEndIdx>=nextIdx-1 and nextIdx or sectEndIdx+1
        end
        lastI = i
    end,true)
    return splitLines
end

function ASSLineContents:getStyleDefaults()
    local function styleRef(tag)
        if tag:find("alpha") then 
            local alpha = true
            tag = tag:gsub("alpha", "color")
        end
        if tag:find("color") then
            return alpha and {self.line.styleRef[tag]:sub(3,4)} or {self.line.styleRef[tag]:sub(5,10)}
        else return  {self.line.styleRef[tag]} end
    end

    local scriptInfo = util.getScriptInfo(self.line.parentCollection.sub)
    local resX, resY = scriptInfo.PlayResX, scriptInfo.PlayResY
    self.line:extraMetrics()

    local styleDefaults = {
        scaleX = ASS.tagMap.scaleX.type(styleRef("scale_x")),
        scaleY = ASS.tagMap.scaleY.type(styleRef("scale_y")),
        align = ASS.tagMap.align.type(styleRef("align")),
        angleZ = ASS.tagMap.angleZ.type(styleRef("angle")),
        outline = ASS.tagMap.outline.type(styleRef("outline")),
        outlineX = ASS.tagMap.outlineX.type(styleRef("outline")),
        outlineY = ASS.tagMap.outlineY.type(styleRef("outline")),
        shadow = ASS.tagMap.shadow.type(styleRef("shadow")),
        shadowX = ASS.tagMap.shadowX.type(styleRef("shadow")),
        shadowY = ASS.tagMap.shadowY.type(styleRef("shadow")),
        alpha1 = ASS.tagMap.alpha1.type(styleRef("alpha1")),
        alpha2 = ASS.tagMap.alpha2.type(styleRef("alpha2")),
        alpha3 = ASS.tagMap.alpha3.type(styleRef("alpha3")),
        alpha4 = ASS.tagMap.alpha4.type(styleRef("alpha4")),
        alpha4 = ASS.tagMap.alpha4.type(styleRef("alpha4")),
        color1 = ASS.tagMap.color1.type(styleRef("color1")),
        color2 = ASS.tagMap.color2.type(styleRef("color2")),
        color3 = ASS.tagMap.color3.type(styleRef("color3")),
        color4 = ASS.tagMap.color4.type(styleRef("color4")),
        clip = ASS.tagMap.clip.type({0,0,resX,resY}),
        clipVect = ASS.tagMap.clipVect.type({string.format("m 0 0 l %s 0 %s %s 0 %s 0 0",resX,resX,resY,resY)}),
        iclipVect = ASS.tagMap.iclipVect.type({"m 0 0 l 0 0 0 0 0 0 0 0"}),
        clipRect = ASS.tagMap.clipRect.type({0,0,resX,resY}),
        iclipRect = ASS.tagMap.iclipRect.type({0,0,0,0}),
        bold = ASS.tagMap.bold.type(styleRef("bold")),
        italic = ASS.tagMap.italic.type(styleRef("italic")),
        underline = ASS.tagMap.underline.type(styleRef("underline")),
        strikeout = ASS.tagMap.strikeout.type(styleRef("strikeout")),
        spacing = ASS.tagMap.spacing.type(styleRef("spacing")),
        fontSize = ASS.tagMap.fontSize.type(styleRef("fontsize")),
        fontName = ASS.tagMap.fontName.type(styleRef("fontname")),
        position = ASS.tagMap.position.type({self.line:getDefaultPosition()}),
        moveSmpl = ASS.tagMap.moveSmpl.type({self.line.xPosition, self.line.yPosition, self.line.xPosition, self.line.yPosition}),
        move = ASS.tagMap.move.type({self.line.xPosition, self.line.yPosition, self.line.xPosition, self.line.yPosition}),
        org = ASS.tagMap.org.type({self.line.xPosition, self.line.yPosition}),
    }

    for key,val in pairs(ASS.tagMap) do
        if val.default then styleDefaults[key]=val.default end
    end

    return styleDefaults
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

ASSLineCommentSection = createASSClass("ASSLineCommentSection", ASSLineTextSection, {"value"}, {"string"})

ASSLineTagSection = createASSClass("ASSLineTagSection", ASSBase, {"tags"}, {"table"})   -- ATTENTION: this is a dummy and will be replaced soon
function ASSLineTagSection:new(tags)
    tags = self:getArgs({tags})
    if type(tags)=="string" then
        self.tags = {}
        for tag in re.gfind(tags, "\\\\[^\\\\\\(]+(?:\\([^\\)]+\\))?") do
            table.insert(self.tags, ASS:getTagFromString(tag))
        end
        if #self.tags==0 and #tags>0 then    -- no tags found but string not empty -> must be a comment section
            return ASSLineCommentSection(tags)
        end
    elseif tags==nil then self.tags={}
    else self.tags = self:typeCheck(tags) end
    return self
end

function ASSLineTagSection:callback(callback, tagTypes)
    local tagSet = {}
    if type(tagTypes)=="string" then tagTypes={tagTypes} end
    if tagTypes then
        assert(type(tagTypes)=="table", "Error: argument 2 to callback must be either a table of strings or a single string, got " .. type(tagTypes))
        for _,tagType in pairs(tagTypes) do
            tagSet[ASS.getInternalTagName()] = true
        end
    end

    local hasRun = false
    for i,tag in ipairs(self.tags) do
        if (not tagTypes or tagSet[tag.__tag.name]) then
            local result, hasRun = callback(tag,self.tags,i), true
            if result==false then
                self.tags[i]:remove()
            elseif type(result)~="nil" and result~=true then
                self.tags[i] = result
            end
        end
    end
    self.tags = table.trimArray(self.tags)
    return hasRun
end

function ASSLineTagSection:getString(coerce)
    local tagString = ""
    self:callback(function(tag)
        tagString = tagString .. tag:getTagString(coerce)
    end)
    return tagString
end

--------------------- Override Tag Classes ---------------------

ASSTagBase = createASSClass("ASSTagBase",ASSBase)

function ASSTagBase:commonOp(method, callback, default, ...)
    local args = {self:getArgs({...}, default, false)}
    local j, res = 1, {}
    for _,valName in ipairs(self.__meta__.order) do
        if type(self[valName])=="table" and self[valName].instanceOf then
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
        return self.startAlpha, self.midAlpha, self.endAlpha, 
               math.min(t1,t2), util.clamp(t2,t1,t3), math.clamp(t3,t2,t4), math.max(t4,t3)
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
        self.__tag.name = "moveSmpl"
    else self.__tag.simple = false end

    self.startPos = ASSPosition(startPosX,startPosY)
    self.endPos = ASSPosition(endPosX,endPosY)
    self.startTime = ASSTime(startTime)
    self.endTime = ASSTime(endTime)
    return self
end

function ASSMove:getTagParams(coerce)
    if self.__tag.simple or self.__tag.name=="moveSmpl" then
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
    aegisub.log("Public announcement: ------------\n")
    aegisub.log(self.__tag.name .."\n")
    aegisub.log("Public announcement: ------------\n")
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
    self.__tag.name = state and "iclipRect" or "clipRect"
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
    self.__tag.name = state and "iclipVect" or "clipVect"
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

ASSClipVect.set, ASSClipVect.mod, ASSClipVect.get = nil, nil, nil  -- TODO: check if these can be remapped/implemented in a way that makes sense, maybe work on strings


--------------------- Drawing Command Classes ---------------------

ASSDrawBase = createASSClass("ASSDrawBase", ASSTagBase, {}, {})
function ASSDrawBase:new(...)
    local args = {...}
    if type(args[1]) == "table" then
        self.parentCollection = args[2]
        args = {self:getArgs(args[1], nil, true)}
    end
    for i,arg in ipairs(args) do
        if i>#self.__meta__.order then
            self.parentCollection = arg
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
    if not (self.length and self.cursor and noUpdate) then self.parentCollection:getLength() end
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
    if not (self.length and self.cursor and noUpdate) then self.parentCollection:getLength() end
    local scaled = self.cursor:copy()
    scaled:add(YUtils.math.stretch(returnAll(
        {ASSPosition(self:get()):sub(self.cursor)},
        {0, len})
    ))
    self:set(scaled:get())
    return self:get()
end

function ASSDrawLine:getAngle(ref, noUpdate)
    if not (ref or (self.cursor and noUpdate)) then self.parentCollection:getLength() end
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
    self.tagMap = {
        scaleX= {friendlyName="\\fscx", type=ASSNumber, pattern="\\fscx([%d%.]+)", format="\\fscx%.3N"},
        scaleY = {friendlyName="\\fscy", type=ASSNumber, pattern="\\fscy([%d%.]+)", format="\\fscy%.3N"},
        align = {friendlyName="\\an", type=ASSAlign, pattern="\\an([1-9])", format="\\an%d"},
        angleZ = {friendlyName="\\frz", type=ASSNumber, pattern="\\frz?([%-%d%.]+)", format="\\frz%.3N"}, 
        angleY = {friendlyName="\\fry", type=ASSNumber, pattern="\\fry([%-%d%.]+)", format="\\frz%.3N", default=0},
        angleX = {friendlyName="\\frx", type=ASSNumber, pattern="\\frx([%-%d%.]+)", format="\\frz%.3N", default=0}, 
        outline = {friendlyName="\\bord", type=ASSNumber, props={positive=true}, pattern="\\bord([%d%.]+)", format="\\bord%.2N"}, 
        outlineX = {friendlyName="\\xbord", type=ASSNumber, props={positive=true}, pattern="\\xbord([%d%.]+)", format="\\xbord%.2N"}, 
        outlineY = {friendlyName="\\ybord", type=ASSNumber,props={positive=true}, pattern="\\ybord([%d%.]+)", format="\\ybord%.2N"}, 
        shadow = {friendlyName="\\shad", type=ASSNumber, pattern="\\shad([%-%d%.]+)", format="\\shad%.2N"}, 
        shadowX = {friendlyName="\\xshad", type=ASSNumber, pattern="\\xshad([%-%d%.]+)", format="\\xshad%.2N"}, 
        shadowY = {friendlyName="\\yshad", type=ASSNumber, pattern="\\yshad([%-%d%.]+)", format="\\yshad%.2N"}, 
        reset = {friendlyName="\\r", type=ASSString, pattern="\\r([^\\}]*)", format="\\r%s", default=""}, 
        alpha = {friendlyName="\\alpha", type=ASSHex, pattern="\\alpha&H(%x%x)&", format="\\alpha&H%02X&", default=0}, 
        alpha1 = {friendlyName="\\1a", type=ASSHex, pattern="\\1a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        alpha2 = {friendlyName="\\2a", type=ASSHex, pattern="\\2a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        alpha3 = {friendlyName="\\3a", type=ASSHex, pattern="\\3a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        alpha4 = {friendlyName="\\4a", type=ASSHex, pattern="\\4a&H(%x%x)&", format="\\alpha&H%02X&"}, 
        color = {friendlyName="\\c", type=ASSColor, pattern="\\c&H(%x%x)(%x%x)(%x%x)&", format="\\c&H%02X%02X%02X&"},
        color1 = {friendlyName="\\1c", type=ASSColor, pattern="\\1c&H(%x%x)(%x%x)(%x%x)&", format="\\1c&H%02X%02X%02X&"},
        color2 = {friendlyName="\\2c", type=ASSColor, pattern="\\2c&H(%x%x)(%x%x)(%x%x)&", format="\\2c&H%02X%02X%02X&"},
        color3 = {friendlyName="\\3c", type=ASSColor, pattern="\\3c&H(%x%x)(%x%x)(%x%x)&", format="\\3c&H%02X%02X%02X&"},
        color4 = {friendlyName="\\4c", type=ASSColor, pattern="\\4c&H(%x%x)(%x%x%)(x%x)&", format="\\4c&H%02X%02X%02X&"},
        clipVect = {friendlyName="\\clip (Vect)", type=ASSClipVect, pattern="\\clip%(([mnlbspc] .-)%)", format="\\clip(%s)"}, 
        iclipVect = {friendlyName="\\iclip (Vect)", type=ASSClipVect, props={inverse=true}, pattern="\\iclip%(([mnlbspc] .-)%)", format="\\iclip(%s)", default={"m 0 0 l 0 0 0 0 0 0 0 0"}},
        clipRect = {friendlyName="\\clip (Rect)", type=ASSClipRect, pattern="\\clip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\clip(%.2N,%.2N,%.2N,%.2N)"}, 
        iclipRect = {friendlyName="\\iclip (Rect)", type=ASSClipRect, props={inverse=true}, pattern="\\iclip%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\iclip(%.2N,%.2N,%.2N,%.2N)", default={0,0,0,0}},
        be = {friendlyName="\\be", type=ASSNumber, props={positive=true}, pattern="\\be([%d%.]+)", format="\\be%.2N", default=0}, 
        blur = {friendlyName="\\blur", type=ASSNumber, props={positive=true}, pattern="\\blur([%d%.]+)", format="\\blur%.2N", default=0}, 
        fax = {friendlyName="\\fax", type=ASSNumber, pattern="\\fax([%-%d%.]+)", format="\\fax%.2N", default=0}, 
        fay = {friendlyName="\\fay", type=ASSNumber, pattern="\\fay([%-%d%.]+)", format="\\fay%.2N", default=0}, 
        bold = {friendlyName="\\b", type=ASSWeight, pattern="\\b(%d+)", format="\\b%d"}, 
        italic = {friendlyName="\\i", type=ASSToggle, pattern="\\i([10])", format="\\i%d"}, 
        underline = {friendlyName="\\u", type=ASSToggle, pattern="\\u([10])", format="\\u%d"},
        strikeout = {friendlyName="\\s", type=ASSToggle, pattern="\\s([10])", format="\\s%d"},
        spacing = {friendlyName="\\fsp", type=ASSNumber, pattern="\\fsp([%-%d%.]+)", format="\\fsp%.2N"},
        fontsize = {friendlyName="\\fs", type=ASSNumber, props={positive=true}, pattern="\\fs([%d%.]+)", format="\\fs%.2N"},
        fontname = {friendlyName="\\fn", type=ASSString, pattern="\\fn([^\\}]*)", format="\\fn%s"},
        kFill = {friendlyName="\\k", type=ASSDuration, props={scale=10}, pattern="\\k([%d]+)", format="\\k%d", default=0},
        kSweep = {friendlyName="\\kf", type=ASSDuration, props={scale=10}, pattern="\\kf([%d]+)", format="\\kf%d", default=0},
        kSweepAlt = {friendlyName="\\K", type=ASSDuration, props={scale=10}, pattern="\\K([%d]+)", format="\\K%d", default=0},
        kBord = {friendlyName="\\ko", type=ASSDuration, props={scale=10}, pattern="\\ko([%d]+)", format="\\ko%d", default=0},
        position = {friendlyName="\\pos", type=ASSPosition, pattern="\\pos%(([%-%d%.]+),([%-%d%.]+)%)", format="\\pos(%.2N,%.2N)"},
        moveSmpl = {friendlyName=nil, type=ASSMove, props={simple=true}, pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)%)", format="\\move(%.2N,%.2N,%.2N,%.2N)"},
        move = {friendlyName="\\move", type=ASSMove, pattern="\\move%(([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),([%-%d%.]+),(%d+),(%d+)%)", format="\\move(%.2N,%.2N,%.2N,%.2N,%.2N,%.2N)"},
        org = {friendlyName="\\org", type=ASSPosition, pattern="\\org%(([%-%d%.]+),([%-%d%.]+)%)", format="\\org(%.2N,%.2N)"},
        wrap = {friendlyName="\\q", type=ASSWrapStyle, pattern="\\q(%d)", format="\\q%d", default=0},
        fadeSmpl = {friendlyName="\\fad", type=ASSFade, props={simple=true}, pattern="\\fad%((%d+),(%d+)%)", format="\\fad(%d,%d)", default={0,0}},
        fade = {friendlyName="\\fade", type=ASSFade, pattern="\\fade?%((.-)%)", format="\\fade(%d),(%d),(%d),(%d),(%d),(%d),(%d)", default={255,0,255,0,0,0,0}},
        transform = {friendlyName="\\t", type=ASSTransform, pattern="\\t%((.-)%)"},
    }
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
    return self.tagMap[assert(name,"Error: can't find tag " .. name)]
end

function ASSFoundation:getTagFromString(str)
    for name,tag in pairs(self.tagMap) do
        if tag.pattern then
            local prms={str:match(tag.pattern)}
            if #prms>0 then
                return tag.type(prms,table.merge(tag.props or {},{name=name}))
            end
        end
    end
    return false
end

function ASSFoundation:formatTag(tagRef, ...)
    return self:mapTag(tagRef.__tag.name).format:formatFancy(...)
end

ASS = ASSFoundation()


