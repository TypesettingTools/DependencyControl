return function(ASS, ASSFInst, yutilsMissingMsg, createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils)
    local Contour = createASSClass("Draw.Contour", ASS.Base, {"commands"}, {"table"}, nil, nil, function(tbl, key)
        if key=="isCW" then
            return tbl:getDirection()
        else return getmetatable(tbl)[key] end
    end)
    Contour.add, Contour.sub, Contour.mul, Contour.div, Contour.mod, Contour.pow =
    ASS.Tag.Base.add, ASS.Tag.Base.sub, ASS.Tag.Base.mul, ASS.Tag.Base.div, ASS.Tag.Base.mod, ASS.Tag.Base.pow

    function Contour:new(args)
        local cmds, clsSet = {}, ASS.Draw.commands
        for i=1,#args do
            assertEx(type(args[i])=="table" and args[i].instanceOf and clsSet[args[i].class],
                     "argument #%d is not a valid drawing command object (%s).", i, args[i].typeName or type(args[i]))
            if i==1 then
                assertEx(args[i].instanceOf[ASS.Draw.Move], "first drawing command of a contour must be of class %s, got a %s.",
                         ASS.Draw.Move.typeName, args[i].typeName)
            end
            cmds[i] = args[i]
            cmds[i].parent = self
        end
        self.commands = cmds
        return self
    end

    function Contour:callback(callback, commandTypes, getPoints)
        local cmdSet = {}
        if type(commandTypes)=="string" or ASS:instanceOf(commandTypes) then commandTypes={commandTypes} end
        if commandTypes then
            assertEx(type(commandTypes)=="table", "argument #2 must be either a table of strings or a single string, got a %s.",
                     type(commandTypes))
            for i=1,#commandTypes do
                cmdSet[commandTypes[i]] = true
            end
        end

        local j, cmdsDeleted = 1, false
        for i=1,#self.commands do
            local cmd = self.commands[i]
            if not commandTypes or cmdSet[cmd.__tag.name] or cmdSet[cmd.class] then
                if getPoints and not cmd.compatible[ASS.Point] then
                    local pointsDeleted = false
                    for p=1,#cmd.__meta__.order do
                        local res = callback(cmd[cmd.__meta__.order[p]], self.commands, i, j, cmd, p)
                        j=j+1
                        if res==false then
                            cmdsDeleted, pointsDeleted = true, true   -- deleting a single point causes the whole command to be deleted
                        elseif res~=nil and res~=true then
                            local class = cmd.__meta__.types[p]
                            cmd[cmd.__meta__.order[p]] = res.instanceOf[class] and res or class{res}
                        end
                    end
                    if pointsDeleted then self.commands[i] = nil end
                else
                    local res = callback(cmd, self.commands, i, j)
                    j=j+1
                    if res==false then
                        self.commands[i], cmdsDeleted = nil, true
                    elseif res~=nil and res~=true then
                        self.commands[i] = res
                    end
                end
            end
        end
        if cmdsDeleted then self.commands = table.reduce(self.commands) end
        if j>1 then
            self.length, self.isCW = nil, nil
            if self.parent then self.parent.length=nil end
        end
    end

    function Contour:expand(x, y)
        x = default(x,1)
        y = default(y,x)

        assertEx(type(x)=="number" and type(y)=="number", "x and y must be a number or nil, got x=%s (%s) and y=%s (%s).",
                 tostring(x), type(x), tostring(y), type(y))
        if x==0 and y==0 then return self end
        assertEx(x>=0 and y>=0 or x<=0 and y<=0,
                 "cannot expand and inpand at the same time (sign must be the same for x and y); got x=%d, y=%d.", x, y)

        local newCmds, sameDir = {}
        if x<0 or y<0 then
            x, y = math.abs(x), math.abs(y)
            sameDir = not self.isCW
        else sameDir = self.isCW end
        local outline = self:getOutline(x, y)

        -- may violate the "one move per contour" principle
        self.commands, self.length, self.isCW = {}, nil, nil

        for i=sameDir and 2 or 1, #outline.contours, 2 do
            self:insertCommands(outline.contours[i].commands, -1, true)
        end

        return self
    end

    function Contour:insertCommands(cmds, index, acceptMoves)
        local prevCnt, inserted, clsSet = #self.commands, {}, ASS.Draw.commands
        index = default(index, math.max(prevCnt,1))
        assertEx(math.isInt(index) and index~=0,
               "argument #2 (index) must be an integer != 0, got '%s' of type %s.", tostring(index), type(index))
        assertEx(type(cmds)=="table",
               "argument #1 (cmds) must be either a drawing command object or a table of drawing commands, got a %s.", type(cmds))

        if cmds.class==Contour then
            accceptMoves, cmds = true, cmds.commands
        elseif cmds.instanceOf then cmds = {cmds} end

        for i=1,#cmds do
            local cmdIsTbl, cmd = type(cmds[i])=="table", cmds[i]
            assertEx(cmdIsTbl and cmd.class, "command #%d must be a drawing command object, got a %s",
                     i, cmdIsTbl and cmd.typeName or type(cmd))
            assertEx(clsSet[cmd.class] and (not cmd.instanceOf[ASS.Draw.Move] or acceptMoves),
                     "command #%d must be a drawing command object, but not a %s; got a %s", ASS.Draw.Move.typeName, cmd.typeName)

            local insertIdx = index<0 and prevCnt+index+i+1 or index+i-1
            table.insert(self.commands, insertIdx, cmd)
            cmd.parent = self
            inserted[i] = self.commands[insertIdx]
        end
        if #cmds>0 then
            self.length, self.isCW = nil, nil
            if self.parent then self.parent.length = nil end
        end
        return #cmds>1 and inserted or inserted[1]
    end

    function Contour:flatten(coerce)
        assert(YUtils, yutilsMissingMsg)
        local flatStr = YUtils.shape.flatten(self:getTagParams(coerce))
        local flattened = ASS.Draw.DrawingBase{str=flatStr, tagProps=self.__tag}
        self.commands = flattened.contours[1].commands
        return self, flatStr
    end

    function Contour:get()
        local commands, j = {}, 1
        for i=1,#self.commands do
            commands[j] = self.commands[i].__tag.name
            local params = {self.commands[i]:get()}
            table.joinInto(commands, params)
            j=j+#params+1
        end
        return commands
    end

    function Contour:getCommandAtLength(len, noUpdate)
        if not (noUpdate and self.length) then self:getLength() end
        local currTotalLen, nextTotalLen = 0
        for i=1,#self.commands do
            local cmd = self.commands[i]
            nextTotalLen = currTotalLen + cmd.length
            if nextTotalLen-len > -0.001 and cmd.length>0
            and not (cmd.instanceOf[ASS.Draw.Move] or cmd.instanceOf[ASS.Draw.MoveNc]) then
                return cmd, math.max(len-currTotalLen,0)
            else currTotalLen = nextTotalLen end
        end
        return false
        -- error(string.format("Error: length requested (%02f) is exceeding the total length of the shape (%02f)",len,currTotalLen))
    end

    function Contour:getDirection()
        local angle, vec = ASS:createTag("angle", 0)
        assertEx(self.commands[1].instanceOf[ASS.Draw.Move], "first drawing command must be a %s, got a %s.",
                 ASS.Draw.Move.typeName, self.commands[1].typeName)

        local p0, p1 = self.commands[1]
        self:callback(function(point, cmds, i, j, cmd, p)
            if j==2 then p1 = point
            elseif j>2 then
                local vec0, vec1 = p1:copy():sub(p0), point:copy():sub(p1)
                angle:add(vec1:getAngle(vec0, true))
                p0, p1 = p1, point
            end
        end, nil, true)
        self.isCW = angle>=0
        return self.isCW
    end

    function Contour:getExtremePoints(allowCompatible)
        local top, left, bottom, right
        for i=1,#self.commands do
            local pts = self.commands[i]:getPoints(allowCompatible)
            for i=1,#pts do
                if not top or top.y > pts[i].y then top=pts[i] end
                if not left or left.x > pts[i].x then left=pts[i] end
                if not bottom or bottom.y < pts[i].y then bottom=pts[i] end
                if not right or right.x < pts[i].x then right=pts[i] end
            end
        end
        return {top=top, left=left, bottom=bottom, right=right, w=right.x-left.x, h=bottom.y-top.y,
                bounds={left.x.value, top.y.value, right.x.value, bottom.y.value}}
    end

    function Contour:getLength()
        local totalLen, lens = 0, {}
        for i=1,#self.commands do
            local len = self.commands[i]:getLength(self.commands[i-1])
            lens[i], totalLen = len, totalLen+len
        end
        self.length = totalLen
        return totalLen, lens
    end

    function Contour:getPositionAtLength(len, noUpdate, useCurveTime)
        if not (noUpdate and self.length) then self:getLength() end
        local cmd, remLen  = self:getCommandAtLength(len, true)
        if not cmd then return false end
        return cmd:getPositionAtLength(remLen, true, useCurveTime), cmd
    end

    function Contour:getAngleAtLength(len, noUpdate)
        if not (noUpdate and self.length) then self:getLength() end
        local cmd, remLen = self:getCommandAtLength(len, true)
        if not cmd then return false end

        local fCmd = cmd.instanceOf[ASS.Draw.Bezier] and cmd.flattened:getCommandAtLength(remLen, true) or cmd
        return fCmd:getAngle(nil, false, true), cmd
    end

    function Contour:getTagParams(scale, caller, coerce)
        scale = (scale or self.parent and self.parent.scale):get() or 1

        -- make contours subject to delayed deletion disappear
        if caller and caller.toRemove and caller.toRemove[self] then
            return ""
        end

        local cmdStr, j, lastCmdType = {}, 1
        for i=1,#self.commands do
            local cmd = self.commands[i]
            if lastCmdType ~= cmd.__tag.name then
                lastCmdType = cmd.__tag.name
                cmdStr[j], j = lastCmdType, j+1
            end
            local params={cmd:getTagParams(coerce)}
            for p=1,#params do
                cmdStr[j] = scale>1 and params[p]*(2^(scale-1)) or params[p]
                j = j+1
            end
        end
        return table.concat(cmdStr, " ")
    end

    function Contour:commonOp(method, callback, default, x, y) -- drawing commands only have x and y in common
        if ASS:instanceOf(x, ASS.Point, nil, true) then
            x, y = x:get()
        end

        for i=1,#self.commands do
            self.commands[i][method](self.commands[i],x,y)
        end
        return self
    end

    function Contour:getOutline(x, y, mode, splitContours)
        assert(YUtils, yutilsMissingMsg)
        y, mode = default(y,x), default(mode, "round")
        local outline = YUtils.shape.to_outline(YUtils.shape.flatten(self:getTagParams()),x,y,mode)
        return (self.parent and self.parent.class or ASS.Draw.DrawingBase){str=outline, splitContours=splitContours}
    end

    function Contour:outline(x, y, mode)
        -- may violate the "one move per contour" principle
        self.commands = self:getOutline(x, y, mode, false).contours[1].commands
        self.length, self.isCW = nil, nil
    end

    function Contour:rotate(angle)
        ASS.Draw.DrawingBase.rotate(self, angle)
        self.commands = self.contours[1]  -- rotating a contour should produce no additional contours
        self.contours = nil
        return self
    end

    function Contour:getFullyCovered(contour, scriptInfo, parentCollection)
        if not scriptInfo and parentCollection then
            local parentContents
            scriptInfo, parentContents = ASS:getScriptInfo(self)
            parentCollection = parentContents and parentContents.line.parentCollection or LineCollection(ASSFInst.cache.lastSub)
        end

        local bs, bo = self:getExtremePoints().bounds, contour:getExtremePoints().bounds
        local bounds = {math.min(bs[1],bo[1]), math.min(bs[2],bo[2]), math.max(bs[3], bo[3]), math.max(bs[4],bo[4])}
        local w, h, safe = bounds[3]-bounds[1], bounds[4]-bounds[2], 1.05
        local sx, sy = w*safe/scriptInfo.PlayResX, h*safe/scriptInfo.PlayResY
        -- move contours as close as possible to point of origin
        -- and proportionally scale it to fully fit the render surface
        local a = self:copy():sub(bounds[1], bounds[2])
        local b = contour:copy():sub(bounds[1], bounds[2])

        if sx>1 or sy>1 then
            local fac = math.max(sx,sy)
            a:div(fac, fac)
            b:div(fac, fac)
        end

        local tags = ASS.defaults.drawingTestTags
        -- create line with both contours and get reference line bounds
        local section = ASS.Section.Drawing{a, b}
        local testLineCnts = ASS:createLine{{tags, section}, parentCollection}.ASS
        -- create lines with only one of the two contours
        local lbAB = ASS.LineBounds(testLineCnts)
        testLineCnts.sections[2].contours[2] = nil
        local lbA = ASS.LineBounds(testLineCnts)
        testLineCnts.sections[2].contours[1] = b
        local lbB = ASS.LineBounds(testLineCnts)
        -- compare the render results of both single contours to the reference
        -- if one is identical to the reference it is covering up the other one (or the other one is 0-width)
        return lbAB:equal(lbA) and contour or lbAB:equal(lbB) and self or false
    end

    function Contour:reverseDirection()
        local revCmds, n = {self.commands[1]}, #self.commands
        for i=n,2,-1 do
            revCmds[n-i+2] = self.commands[i]
        end
        self.isCW, self.commands = nil, revCmds
        return self
    end

    return Contour
end