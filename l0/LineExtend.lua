local meta = getmetatable(Line)
meta.__index.mapTag = function(self, tagName)
    local function getStyleRef(tag)
        if tag:find("alpha") then 
            local alpha = true
            tag = tag:gsub("alpha", "color")
        end
        if tag:find("color") then
            return alpha and {self.styleRef[tag]:sub(3,4)} or {self.styleRef[tag]:sub(5,10)}
        else return  {self.styleRef[tag]} end
    end

    if not  self.tagMap then
        local sI = util.getScriptInfo(self.parentCollection.sub)
        local resX, resY = sI.PlayResX, sI.PlayResY
        self:extraMetrics(self.styleRef)
        self.tagMap = {
            scaleX= {friendlyName="\\fscx", type="ASSNumber", pattern="\\fscx([%d%.]+)", format="\\fscx%.3N", default=getStyleRef("scale_x")},
            scaleY = {friendlyName="\\fscy", type="ASSNumber", pattern="\\fscy([%d%.]+)", format="\\fscy%.3N", default=getStyleRef("scale_y")},
            align = {friendlyName="\\an", type="ASSAlign", pattern="\\an([1-9])", format="\\an%d", default=getStyleRef("align")},
            angleZ = {friendlyName="\\frz", type="ASSNumber", pattern="\\frz?([%-%d%.]+)", format="\\frz%.3N", default=getStyleRef("angle")}, 
            angleY = {friendlyName="\\fry", type="ASSNumber", pattern="\\fry([%-%d%.]+)", format="\\frz%.3N", default=0},
            angleX = {friendlyName="\\frx", type="ASSNumber", pattern="\\frx([%-%d%.]+)", format="\\frz%.3N", default=0}, 
            outline = {friendlyName="\\bord", type="ASSNumber", props={positive=true}, pattern="\\bord([%d%.]+)", format="\\bord%.2N", default=getStyleRef("outline")}, 
            outlineX = {friendlyName="\\xbord", type="ASSNumber", props={positive=true}, pattern="\\xbord([%d%.]+)", format="\\xbord%.2N", default=getStyleRef("outline")}, 
            outlineY = {friendlyName="\\ybord", type="ASSNumber",props={positive=true}, pattern="\\ybord([%d%.]+)", format="\\ybord%.2N", default=getStyleRef("outline")}, 
            shadow = {friendlyName="\\shad", type="ASSNumber", pattern="\\shad([%-%d%.]+)", format="\\shad%.2N", default=getStyleRef("shadow")}, 
            shadowX = {friendlyName="\\xshad", type="ASSNumber", pattern="\\xshad([%-%d%.]+)", format="\\xshad%.2N", default=getStyleRef("shadow")}, 
            shadowY = {friendlyName="\\yshad", type="ASSNumber", pattern="\\yshad([%-%d%.]+)", format="\\yshad%.2N", default=getStyleRef("shadow")}, 
            reset = {friendlyName="\\r", type="ASSString", pattern="\\r([^\\}]*)", format="\\r%s", default=""}, 
            alpha = {friendlyName="\\alpha", type="ASSHex", pattern="\\alpha&H(%x%x)&", format="\\alpha&H%02X&", default=0}, 
            alpha1 = {friendlyName="\\1a", type="ASSHex", pattern="\\1a&H(%x%x)&", format="\\alpha&H%02X&", default=getStyleRef("alpha1")}, 
            alpha2 = {friendlyName="\\2a", type="ASSHex", pattern="\\2a&H(%x%x)&", format="\\alpha&H%02X&", default=getStyleRef("alpha2")}, 
            alpha3 = {friendlyName="\\3a", type="ASSHex", pattern="\\3a&H(%x%x)&", format="\\alpha&H%02X&", default=getStyleRef("alpha3")}, 
            alpha4 = {friendlyName="\\4a", type="ASSHex", pattern="\\4a&H(%x%x)&", format="\\alpha&H%02X&", default=getStyleRef("alpha4")}, 
            color = {friendlyName="\\c", type="ASSColor", pattern="\\c&H(%x+)&", format="\\c&H%02X%02X%02X&", default=getStyleRef("color1")}, 
            color1 = {friendlyName="\\1c", type="ASSColor", pattern="\\1c&H(%x+)&", format="\\1c&H%02X%02X%02X&", default=getStyleRef("color1")},
            color2 = {friendlyName="\\2c", type="ASSColor", pattern="\\2c&H(%x+)&", format="\\2c&H%02X%02X%02X&", default=getStyleRef("color2")}, 
            color3 = {friendlyName="\\3c", type="ASSColor", pattern="\\3c&H(%x+)&", format="\\3c&H%02X%02X%02X&", default=getStyleRef("color3")},
            color4 = {friendlyName="\\4c", type="ASSColor", pattern="\\4c&H(%x+)&", format="\\4c&H%02X%02X%02X&", default=getStyleRef("color4")},
            clip = {friendlyName="\\clip", type="ASSClip", pattern="\\clip%((.-)%)", format="\\clip(%s)", default={0,0,resX,resY}},  -- matches all clips, not used for formatting
            iclip = {friendlyName="\\iclip", type="ASSClip", props={inverse=true}, pattern="\\iclip%((.-)%)", format="\\clip(%s)", default={0,0,0,0}}, -- matches all iclips, not used for formatting
            clipVect = {friendlyName="\\clip (Vect)", type="ASSClipVect", pattern="\\clip%(([mnlbspc] .-)%)", format="\\clip(%s)", default={string.format("m 0 0 l %s 0 %s %s 0 %s 0 0",resX,resX,resY,resY)}}, 
            iclipVect = {friendlyName="\\iclip (Vect)", type="ASSClipVect", props={inverse=true}, pattern="\\iclip%(([mnlbspc] .-)%)", format="\\iclip(%s)", default={"m 0 0 l 0 0 0 0 0 0 0 0"}},
            clipRect = {friendlyName="\\clip (Rect)", type="ASSClipRect", pattern="\\clip%(([%-%d%.]+,[%-%d%.]+,[%-%d%.]+,[%-%d%.]+)%)", format="\\clip(%.2N,%.2N,%.2N,%.2N)", default={0,0,resX,sI.resY}}, 
            iclipRect = {friendlyName="\\iclip (Rect)", type="ASSClipRect", props={inverse=true}, pattern="\\iclip%(([%-%d%.]+,[%-%d%.]+,[%-%d%.]+,[%-%d%.]+)%)", format="\\iclip(%.2N,%.2N,%.2N,%.2N)", default={0,0,0,0}},
            be = {friendlyName="\\be", type="ASSNumber", props={positive=true}, pattern="\\be([%d%.]+)", format="\\be%.2N", default=0}, 
            blur = {friendlyName="\\blur", type="ASSNumber", props={positive=true}, pattern="\\blur([%d%.]+)", format="\\blur%.2N", default=0}, 
            fax = {friendlyName="\\fax", type="ASSNumber", pattern="\\fax([%-%d%.]+)", format="\\fax%.2N", default=0}, 
            fay = {friendlyName="\\fay", type="ASSNumber", pattern="\\fay([%-%d%.]+)", format="\\fay%.2N", default=0}, 
            bold = {friendlyName="\\b", type="ASSWeight", pattern="\\b(%d+)", format="\\b%d", default=getStyleRef("bold")}, 
            italic = {friendlyName="\\i", type="ASSToggle", pattern="\\i([10])", format="\\i%d", default=getStyleRef("italic")}, 
            underline = {friendlyName="\\u", type="ASSToggle", pattern="\\u([10])", format="\\u%d", default=getStyleRef("underline")},
            spacing = {friendlyName="\\fsp", type="ASSNumber", pattern="\\fsp([%-%d%.]+)", format="\\fsp%.2N", default=getStyleRef("spacing")},
            fontsize = {friendlyName="\\fs", type="ASSNumber", props={positive=true}, pattern="\\fs([%d%.]+)", format="\\fsp%.2N", default=getStyleRef("fontsize")},
            fontname = {friendlyName="\\fn", type="ASSString", pattern="\\fn([^\\}]*)", format="\\fn%s", default=getStyleRef("fontname")},
            kFill = {friendlyName="\\k", type="ASSDuration", props={scale=10}, pattern="\\k([%d]+)", format="\\k%d", default=0},
            kSweep = {friendlyName="\\kf", type="ASSDuration", props={scale=10}, pattern="\\kf([%d]+)", format="\\kf%d", default=0},
            kSweepAlt = {friendlyName="\\K", type="ASSDuration", props={scale=10}, pattern="\\K([%d]+)", format="\\K%d", default=0},
            kBord = {friendlyName="\\ko", type="ASSDuration", props={scale=10}, pattern="\\ko([%d]+)", format="\\ko%d", default=0},
            position = {friendlyName="\\pos", type="ASSPosition", pattern="\\pos%(([%-%d%.]+,[%-%d%.]+)%)", format="\\pos(%.2N,%.2N)", default={self:getDefaultPosition()}},
            moveSmpl = {friendlyName=nil, type="ASSMove", props={simple=true}, format="\\move(%.2N,%.2N,%.2N,%.2N)", default={self.xPosition, self.yPosition, self.xPosition, self.yPosition}}, -- only for output formatting
            move = {friendlyName="\\move", type="ASSMove", pattern="\\move%(([%-%d%.,]+)%)", format="\\move(%.2N,%.2N,%.2N,%.2N,%.2N,%.2N)", default={self.xPosition, self.yPosition, self.xPosition, self.yPosition}},
            org = {friendlyName="\\org", type="ASSPosition", pattern="\\org([%-%d%.]+,[%-%d%.]+)", format="\\org(%.2N,%.2N)", default={self.xPosition, self.yPosition}},
            wrap = {friendlyName="\\q", type="ASSWrapStyle", pattern="\\q(%d)", format="\\q%d", default=0},
            fadeSmpl = {friendlyName="\\fad", type="ASSFade", props={simple=true}, pattern="\\fad%((%d+,%d+)%)", format="\\fad(%d,%d)", default={0,0}},
            fade = {friendlyName="\\fade", type="ASSFade", pattern="\\fade?%((.-)%)", format="\\fade(%d,%d,%d,%d,%d,%d,%d)", default={255,0,255,0,0,0,0}},
            transform = {friendlyName="\\t", type="ASSTransform", pattern="\\t%((.-)%)"},
        }
    end

    if not self.tagMap[tagName] then 
        for key,val in pairs(self.tagMap) do
            if val.friendlyName == tagName then 
                tagName = key
            break end
        end
    end

    assert(self.tagMap[tagName], string.format("Error: can't find tag %s.\n",tagName))
    return self.tagMap[tagName], tagName
end

meta.__index.getDefaultTag = function (self,tagName)
    local tagData, tagName = self:mapTag(tagName)  -- make sure to not pass friendlyNames into ASSTypes
    return _G[tagData.type](tagData.default, table.merge(tagData.props or {},{name=tagName}))
end

meta.__index.addTag = function(self,tagName,val,pos)
    if type(val) == "table" and val.instanceOf then
        tagName = tagName or val.__tag.name
    else
        local tagData = self:mapTag(tagName)
        if val==nil then val=self:getDefaultTag(tagName) end
    end

    local _,linePos = self.text:find("{.-}")
    if linePos then 
        self.text = self.text:sub(0,linePos-1)..self:getTagString(nil,val)..self.text:sub(linePos,self.text:len())
    else
        self.text = string.format("{%s}%s", self:getTagString(tagName,val), self.text)
    end

    return val
    -- TODO: pos: +n:n-th override tag; 0:first override tag and after resets -n: position in line
end

meta.__index.getTagString = function(self,tagName,val)
    if type(val) == "table" and val.instanceOf then
        tagName = tagName or val.__tag.name
        return self:mapTag(tagName).format:formatFancy(val:getTag(true))
    else
        return re.sub(self:mapTag(tagName).format,"(%.*?[A-Za-z],?)+","%s"):formatFancy(tostring(val))
    end
end

meta.__index.getTags = function(self,tagName,asStrings)
    local tagData, tagName = self:mapTag(tagName) -- make sure to not pass friendlyNames into ASSTypes
    local tags={}
    for tag in self.text:gmatch("{.-" .. tagData.pattern .. ".-}") do
        prms={}
        for prm in tag:gmatch("([^,]+)") do prms[#prms+1] = prm end
        tags[#tags+1] = asStrings and self:getTagString(tagName,tag) or
                        _G[tagData.type](prms,table.merge(tagData.props or {},{name=tagName}))
    end
    return tags
end

meta.__index.modTag = function(self, tagName, callback, noDefault)
    local tags, orgStrings = self:getTags(tagName), self:getTags(tagName, true)

    if #orgStrings==0 and not noDefault then
        local newTag = self:addTag(tagName,nil)
        tags, orgStrings = {newTag}, {self:getTagString(nil,newTag)}
    end
    
    for i,tag in pairs(callback(tags)) do
        self.text = self.text:gsub(string.patternEscape(orgStrings[i]), self:getTagString(nil,tags[i]), 1)
    end

    return #tags>0
end

setmetatable(Line, meta)