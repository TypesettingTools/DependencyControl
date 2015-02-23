local common = require("l0.ASSFoundation.Common")
local util = require("aegisub.util")

return function (typeName, baseClasses, order, types, tagProps, compatibleClasses, customIndex)
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

    cls.__index = customIndex and customIndex or cls
    cls.instanceOf, cls.typeName, cls.class = {[cls] = true}, typeName, cls
    cls.__meta__ = {order = order, types = types}
    cls.__defProps = table.merge(cls.__defProps or {},tagProps or {})

    -- compatible classes
    cls.compatible = table.arrayToSet(compatibleClasses)
    -- set mutual compatibility in reference classes
    for i=1,#compatibleClasses do
        compatibleClasses[i].compatible[cls] = true
    end
    cls.compatible[cls] = true

    cls.getRawArgCnt = function(self)
        local cnt, meta = 0, self.__meta__
        if not meta.types then return 0 end
        for i=1,#meta.types do
            cnt = cnt + (type(meta.types[i])=="table" and meta.types[i].class and meta.types[i]:getRawArgCnt() or 1)
        end
        return cnt
    end
    cls.__meta__.rawArgCnt = cls:getRawArgCnt()

    return cls
end