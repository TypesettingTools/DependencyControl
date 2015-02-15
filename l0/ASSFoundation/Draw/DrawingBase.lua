return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local DrawingBase = createASSClass("Draw.DrawingBase", ASS.Tag.Base, {"contours"}, {"table"})
    -- TODO: check if these can be remapped/implemented in a way that makes sense, maybe work on strings
    DrawingBase.set, DrawingBase.mod = nil, nil

    function DrawingBase:new(args)
        -- TODO: support alternative signature for ASSLineDrawingSection
        local cmdMap, lastCmdType = ASS.Draw.commandMapping
        -- construct from a compatible object
        -- note: does copy
        if ASS:instanceOf(args[1], DrawingBase, nil, true) then
            local copy = args[1]:copy()
            self.contours, self.scale = copy.contours, copy.scale
            self.__tag.inverse = copy.__tag.inverse
        -- construct from a single string of drawing commands
        elseif args.raw or args.str then
            self.contours = {}
            local str = args.str or args.raw[1]
            if self.class == ASS.Tag.ClipVect then
                local _,sepIdx = str:find("^%d+,")
                self.scale = ASS:createTag("drawing", epIdx and tonumber(str:sub(0,sepIdx-1)) or 1)
                str = sepIdx and str:sub(sepIdx+1) or str
            else self.scale = ASS:createTag("drawing", args.scale or 1) end

            local cmdParts, i, j = str:split(" "), 1, 1
            local contour, c = {}, 1
            while i<=#cmdParts do
                local cmd, cmdType = cmdParts[i], cmdMap[cmdParts[i]]
                if cmdType == ASS.Draw.Move and i>1 and args.splitContours~=false then
                    self.contours[c] = ASS.Draw.Contour(contour)
                    self.contours[c].parent = self
                    contour, j, c = {}, 1, c+1
                end
                if cmdType == ASS.Draw.Close then
                    contour[j] = ASS.Draw.Close()
                elseif cmdType or cmdParts[i]:find("^[%-%d%.]+$") and lastCmdType then
                    if not cmdType then
                        i=i-1
                    else lastCmdType = cmdType end
                    local prmCnt = lastCmdType.__defProps.ords
                    local prms = table.sliceArray(cmdParts,i+1,i+prmCnt)
                    contour[j] = lastCmdType(unpack(prms))
                    i = i+prmCnt
                else error(string.format("Error: Unsupported drawing Command '%s'.", cmdParts[i])) end
                i, j = i+1, j+1
            end
            if #contour>0 then
                self.contours[c] = ASS.Draw.Contour(contour)
                self.contours[c].parent = self
            end

            if self.scale>=1 then
                self:div(2^(self.scale-1),2^(self.scale-1))
            end
        else
        -- construct from valid drawing commands, also accept contours and tables of drawing commands
        -- note: doesn't copy
            self.contours, self.scale = {}, ASS:createTag("drawing", args.scale or 1)
            local contour, c = {}, 1
            local j, cmdSet = 1, ASS.Draw.commands
            for i=1,#args do
                assertEx(type(args[i])=="table",
                         "argument #%d is not a valid drawing object, contour or table, got a %s.", i, type(args[i]))
                if args[i].instanceOf then
                    if args[i].instanceOf[ASS.Draw.Contour] then
                        if #contour>0 then
                            self.contours[c] = ASS.Draw.Contour(contour)
                            self.contours[c].parent, c = self, c+1
                        end
                        self.contours[c], c = args[i], c+1
                        contour, j = {}, 1
                    elseif args[i].instanceOf[ASS.Draw.Move] and i>1 and args.splitContours~=false then
                        self.contours[c], c = ASS.Draw.Contour(contour), c+1
                        contour, j = {args[i]}, 2
                    elseif ASS:instanceOf(args[i], cmdSet) then
                        contour[j], j = args[i], j+1
                    else error(string.format("argument #%d is not a valid drawing object or contour, got a %s.",
                                             i, args[i].class.typeName))
                    end
                else
                    for k=1,#args[i] do
                        assertEx(ASS:instanceOf(args[i][k],ASS.Draw.commands),
                                 "argument #%d to %s contains invalid drawing objects (#%d is a %s).",
                                 i, self.typeName, k, ASS:instanceOf(args[i][k]) or type(args[i][k])
                        )
                        if args[i][k].instanceOf[ASS.Draw.Move] then
                            self.contours[c] = ASS.Draw.Contour(contour)
                            self.contours[c].parent = self
                            contour, j, c = {args[i][k]}, 2, c+1
                        else contour[j], j = args[i][k], j+1 end
                    end
                end
            end
            if #contour>0 then
                self.contours[c] = ASS.Draw.Contour(contour)
                self.contours[c].parent = self
            end
        end
        self:readProps(args)
        return self
    end

    function DrawingBase:callback(callback, start, end_, includeCW, includeCCW)
        local j, rmCnt = 1, 0
        self.toRemove = {}
        includeCW, includeCCW = default(includeCW, true), default(includeCCW, true)

        for i=1,#self.contours do
            local cnt = self.contours[i]
            if (includeCW or not cnt.isCW) and (includeCCW or cnt.isCW) then
                local res = callback(cnt, self.contours, i, j, self.toRemove)
                j=j+1
                if res==false then
                    self.toRemove[cnt], self.toRemove[rmCnt+1], rmCnt = true, i, rmCnt+1
                elseif res~=nil and res~=true then
                    self.contours[i], self.length = res, true
                end
            end
        end

        -- delay removal of contours until the all contours have been processed
        if rmCnt>0 then
            table.removeFromArray(self.contours, self.toRemove)
            self.length = nil
        end
        self.toRemove = {}
    end

    function DrawingBase:modCommands(callback, commandTypes, start, end_, includeCW, includeCCW)
        includeCW, includeCCW = default(includeCW, true), default(includeCCW, true)
        local cmdSet = {}
        if type(commandTypes)=="string" or ASS:instanceOf(commandTypes) then commandTypes={commandTypes} end
        if commandTypes then
            assertEx(type(commandTypes)=="table", "argument #2 must be either a table of strings or a single string, got a %s.",
                     type(commandTypes))
            for i=1,#commandTypes do
                cmdSet[commandTypes[i]] = true
            end
        end

        local matchedCmdCnt, matchedCntsCnt, rmCntsCnt, rmCmdsCnt = 1, 1, 0, 0
        self.toRemove = {}

        for i=1,#self.contours do
            local cnt = self.contours[i]
            if (includeCW or not cnt.isCW) and (includeCCW or cnt.isCW) then
                cnt.toRemove, rmCmdsCnt = {}, 0
                for j=1,#cnt.commands do
                    if not commandTypes or cmdSet[cnt.commands[j].__tag.name] or cmdSet[cnt.commands[j].class] then
                        local res = callback(cnt.commands[j], cnt.commands, j, matchedCmdCnt, i, matchedCntsCnt,
                                             cnt.toRemove, self.toRemove)
                        matchedCmdCnt = matchedCmdCnt + 1
                        if res==false then
                            cnt.toRemove[cnt.commands[j]], cnt.toRemove[rmCmdsCnt+1], rmCmdsCnt = true, j, rmCmdsCnt+1
                        elseif res~=nil and res~=true then
                            cnt.commands[j] = res
                            cnt.length, cnt.isCW, self.length = nil, nil, nil
                        end
                    end
                end
                matchedCntsCnt = matchedCntsCnt + 1
                if rmCmdsCnt>0 then
                    table.removeFromArray(cnt.commands, cnt.toRemove)
                    cnt.length, cnt.isCW, self.length, cnt.toRemove = nil, nil, nil, {}
                    if #cnt.commands == 0 then
                        self.toRemove[cnt], self.toRemove[rmCntsCnt+1], rmCntsCnt = true, i, rmCntsCnt+1
                    end
                end
            end
        end

        -- delay removal of contours until the all contours have been processed
        if rmCntsCnt>0 then
            table.removeFromArray(self.contours, self.toRemove)
            self.length = nil
        end
        self.toRemove = {}
    end

    function DrawingBase:insertCommands(cmds, index)
        local prevCnt, addContour, a, newContour, n = #self.contours, {}, 1
        index = index or prevCnt
        assertEx(math.isInt(index) and index~=0,
                 "argument #2 (index) must be an integer != 0, got '%s' of type %s.", tostring(index), type(index))
        assertEx(type(cmds)=="table",
               "argument #1 (cmds) must be either a drawing command object or a table of drawing commands, got a %s.", type(cmds))

        if index<0 then index=prevCnt+index+1 end
        local cntAtIdx = self.contours[index] or self.contours[prevCnt]
        if cmds.instanceOf then cmds = {cmds} end

        for i=1,#cmds do
            local cmdIsTbl = type(cmds[i])=="table"
            assertEx(cmdIsTbl and cmds[i].instanceOf,"command #%d must be a drawing command object, got a %s",
                     cmdIsTbl and cmd.typeName or type(cmds[i]))
            if cmds[i].instanceOf[ASS.Draw.Move] then
                if newContour then
                    self:insertContours(ASS.Draw.Contour(contour), math.min(index, #self.contours+1))
                end
                newContour, index, n = {cmds[i]}, index+1, 2
            elseif newContour then
                newContour[n], n = cmds[i], n+1
            else addContour[a], a = cmds[i], a+1 end
        end
        if #addContour>0 then cntAtIdx:insertCommands(addContour) end
        if newContour then
            self:insertContours(ASS.Draw.Contour(contour), math.min(index, #self.contours+1))
        end
    end

    function DrawingBase:insertContours(cnts, index)
        index = index or #self.contours+1

        assertEx(type(cnts)=="table", "argument #1 (cnts) must be either a single contour object or a table of contours, got a %s.",
                 type(cnts))

        if cnts.compatible and cnts.compatible[DrawingBase] then
            cnts = cnts:copy().contours
        elseif cnts.instanceOf then cnts = {cnts} end

        for i=1,#cnts do
            assertEx(ASS:instanceOf(cnts[i], ASS.Draw.Contour), "can only insert objects of class %s, got a %s.",
                     ASS.Draw.Contour.typeName, type(cnts[i])=="table" and cnts[i].typeName or type(cnts[i]))

            table.insert(self.contours, index+i-1, cnts[i])
            cnts[i].parent = self
        end
        if #cnts>0 then self.length = nil end

        return cnts
    end

    function DrawingBase:getTagParams(coerce)
        local cmdStr, j = {}, 1
        for i=1,#self.contours do
            cmdStr[i] = self.contours[i]:getTagParams(self.scale, self, coerce)
        end
        return table.concat(cmdStr, " "), self.scale:getTagParams(coerce)
    end

    function DrawingBase:commonOp(method, callback, default, x, y) -- drawing commands only have x and y in common
        for i=1,#self.contours do
            self.contours[i]:commonOp(method, callback, default, x, y)
        end
        return self
    end

    function DrawingBase:drawRect(tl, br) -- TODO: contour direction
        local rect = ASS.Draw.Contour{ASS.Draw.Move(tl), ASS.Draw.Line(br.x, tl.y),
                                      ASS.Draw.Line(br), ASS.Draw.Line(tl.x, br.y)}
        self:insertContours(rect)
        return self, rect
    end

    function DrawingBase:expand(x, y)
        local holes, other, covered = self:getHoles()
        self:removeContours(covered)
        for i=1,#holes do
            holes[i]:expand(-x,-y)
        end
        for i=1,#other do
            other[i]:expand(x,y)
        end
        return self
    end

    function DrawingBase:flatten(coerce)
        local flatStr, _ = {}
        for i=1,#self.contours do
            _, flatStr[i] = self.contours[i]:flatten(coerce)
        end
        return self, table.concat(flatStr, " ")
    end

    function DrawingBase:getLength()
        local totalLen, lens = 0, {}
        for i=1,#self.contours do
            local len, lenParts = self.contours[i]:getLength()
            table.joinInto(lens, lenParts)
            totalLen = totalLen+len
        end
        self.length = totalLen
        return totalLen, lens
    end

    function DrawingBase:getCommandAtLength(len, noUpdate)
        if not (noUpdate and self.length) then self:getLength() end
        local currTotalLen = 0
        for i=1,#self.contours do
            local cnt = self.contours[i]
            if currTotalLen+cnt.length-len > -0.001 and cnt.length>0 then
                local cmd, remLen = cnt:getCommandAtLength(len, noUpdate)
                assert(cmd or i==#self.contours, "Unexpected Error: command at length not found in target contour.")
                return cmd, remLen, cnt, i
            else currTotalLen = currTotalLen + cnt.length - len end
        end
        return false
        -- error(string.format("Error: length requested (%02f) is exceeding the total length of the shape (%02f)",len,currTotalLen))
    end

    function DrawingBase:getPositionAtLength(len, noUpdate, useCurveTime)
        if not (noUpdate and self.length) then self:getLength() end
        local cmd, remLen, cnt  = self:getCommandAtLength(len, true)
        if not cmd then return false end
        return cmd:getPositionAtLength(remLen, true, useCurveTime), cmd, cnt
    end

    function DrawingBase:getAngleAtLength(len, noUpdate)
        if not (noUpdate and self.length) then self:getLength() end
        local cmd, remLen, cnt = self:getCommandAtLength(len, true)
        if not cmd then return false end

        local fCmd = cmd.instanceOf[ASS.Draw.Bezier] and cmd.flattened:getCommandAtLength(remLen, true) or cmd
        return fCmd:getAngle(nil, false, true), cmd, cnt
    end

    function DrawingBase:getExtremePoints(allowCompatible)
        if #self.contours==0 then return {w=0, h=0} end
        local ext = self.contours[1]:getExtremePoints(allowCompatible)

        for i=2,#self.contours do
            local pts = self.contours[i]:getExtremePoints(allowCompatible)
            if ext.top.y > pts.top.y then ext.top=pts.top end
            if ext.left.x > pts.left.x then ext.left=pts.left end
            if ext.bottom.y < pts.bottom.y then ext.bottom=pts.bottom end
            if ext.right.x < pts.right.x then ext.right=pts.right end
        end
        ext.w, ext.h = ext.right.x-ext.left.x, ext.bottom.y-ext.top.y
        return ext
    end

    function DrawingBase:outline(x,y,mode)
        self.contours = self:getOutline(x,y,mode).contours
        self.length = nil
    end

    function DrawingBase:getOutline(x,y,mode)
        assert(YUtils, yutilsMissingMsg)
        y, mode = default(y,x), default(mode, "round")
        local outline = YUtils.shape.to_outline(YUtils.shape.flatten(self:getTagParams()),x,y,mode)
        return self.class{str=outline}
    end

    function DrawingBase:removeContours(cnts, start, end_, includeCW, includeCCW)
        local cntsType = type(cnts)
        if not cnts and not start and not end_ and includeCW==nil and includeCCW==nil then
            local removed = self.contours
            self.contours, self.length = {}, nil
            return removed
        elseif not cnts or cntsType=="number" or cntsType=="table" and cnts.class==ASS.Draw.Contour then
            self:callback(function(cnt,_,i)
                return cnts and cnts~=i and cnts~=cnt
            end, start, end_, includeCW, includeCCW)
        else assertEx(cntsType=="table" and not cnts.class,
                      "argument #1 must be either an %s object, an index, nil or a table of contours/indexes; got a %s.",
                      ASS.Draw.Contour.typeName, cntsType=="table" and cnts.typeName or cntsType)
        end

        local cntsSet = table.arrayToSet(cnts)
        self:callback(function(cnt,_,i)
            return not cntsSet[cnt] and not cntsSet[i]
        end, start, end_, includeCW, includeCCW)
    end


    function DrawingBase:getFullyCoveredContours()
        local scriptInfo, parentContents = ASS:getScriptInfo(self)
        local parentCollection = parentContents and parentContents.line.parentCollection or LineCollection(ASSFInst.cache.lastSub)
        local covCnts, c = {}, 0

        self:callback(function(cnt, cnts, i)
            if covCnts[cnt] then return end
            for j=i+1,#cnts do
                if not (covCnts[cnt] or covCnts[cnts[j]]) and cnts[j].isCW==cnt.isCW then
                    local covered = cnt:getFullyCovered(cnts[j], scriptInfo, parentCollection)
                    if covered then
                        covCnts[covered], c = true, c+1
                        covCnts[c] = covered==cnt and i or j
                    end
                end
            end
        end)
        return covCnts
    end

    function DrawingBase:getHoles()
        local scriptInfo, parentContents = ASS:getScriptInfo(self)
        local parentCollection = parentContents and parentContents.line.parentCollection or LineCollection(ASSFInst.cache.lastSub)

        local bounds, safe = self:getExtremePoints(), 1.05
        local scaleFac = math.max(bounds.w.value*safe/scriptInfo.PlayResX, bounds.h.value*safe/scriptInfo.PlayResY)

        local testDrawing = ASS.Section.Drawing{self}
        testDrawing:modCommands(function(cmd)
            cmd:sub(bounds.left.x, bounds.top.y)
            if scaleFac>1 then cmd:div(scaleFac, scaleFac) end
            -- snap drawing commands to the pixel grid to avoid false positives
            -- when using the absence of opaque pixels in the clipped drawing to determine
            -- whether the contour is a hole
            cmd:ceil(0,0)
        end)

        local testLineCnts = ASS:createLine{{ASS.Section.Tag(ASS.defaults.drawingTestTags), testDrawing}, parentCollection}.ASS
        local testTagCnt = #testLineCnts.sections[1].tags

        local covered, holes, other, h, o = self:getFullyCoveredContours(), {}, {}, 1, 1
        local coveredSet = table.arrayToSet(covered)
        testDrawing:callback(function(cnt, _, i)
            if not coveredSet[self.contours[i]] then
                testLineCnts.sections[1].tags[testTagCnt+1] = ASS:createTag("clip_vect", cnt)
                if not ASS.LineBounds(testLineCnts).firstFrameIsSolid then
                    -- clipping the drawing to the contour produced no solid pixels (only subpixel residue)
                    -- most likely means the contour is a hole
                    holes[h], h = self.contours[i], h+1
                else other[o], o = self.contours[i], o+1 end
            end
        end)

        return holes, other, covered
    end

    function DrawingBase:rotate(angle)
        angle = default(angle,0)
        if ASS:instanceOf(angle,ASS.Number) then
            angle = angle:getTagParams(coerce)
        else assertEx(type(angle)=="number", "argument #1 (angle) must be either a number or a %s object, got a %s.",
             ASS.Number.typeName, ASS:instanceOf(angle) and ASS:instanceOf(angle).typeName or type(angle))
        end

        if angle%360~=0 then
            assert(YUtils, yutilsMissingMsg)
            local shape = self:getTagParams()
            local bound = {YUtils.shape.bounding(shape)}
            local rotMatrix = YUtils.math.create_matrix().
                              translate((bound[3]-bound[1])/2,(bound[4]-bound[2])/2,0).rotate("z",angle).
                              translate(-bound[3]+bound[1]/2,(-bound[4]+bound[2])/2,0)
            shape = YUtils.shape.transform(shape,rotMatrix)
            self.contours = DrawingBase{raw=shape}.contours
        end
        return self
    end

    function DrawingBase:get()
        local commands, j = {}, 1
        for i=1, #self.contours do
            table.joinInto(commands, self.contours[i]:get())
        end
        return commands, self.scale:get()
    end

    function DrawingBase:getSection()
        local section = ASS.Section.Drawing{}
        section.contours, section.scale = self.contours, self.scale
        return section
    end

    return DrawingBase
end
