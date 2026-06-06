Common = require "l0.DependencyControl.Common"

-- all concrete script types (the ScriptType table also holds a `name` lookup sub-table)
scriptTypeList = [v for k, v in pairs Common.ScriptType when k != "name"]
table.sort scriptTypeList

--- Selects which packages a feed operation should process, by script type and namespace.
-- Construct it from a spec table, or empty and build it up fluently — every builder method
-- returns self so calls can be chained. Because modules and automation scripts aren't required
-- to have unique namespaces, rules are keyed by script type first.
--
-- @usage ScriptTargetFilter!\include(Common.ScriptType.Module, "l0.DependencyControl")
-- @usage ScriptTargetFilter!\includeAll Common.ScriptType.Module   -- every module
-- @usage ScriptTargetFilter!\includeAll!                            -- everything
-- @usage ScriptTargetFilter {[Common.ScriptType.Module]: {include: {"l0.DependencyControl"}}}
-- @class ScriptTargetFilter
class ScriptTargetFilter
    @scriptTypeList = scriptTypeList

    --- @param[opt] spec table  {[scriptType] = true | {include: {ns, ...}, exclude: {ns, ...}}}
    new: (spec) =>
        @rules = {}  -- [scriptType] = {all: bool, include: {ns -> true}, exclude: {ns -> true}}
        if spec
            for scriptType, rule in pairs spec
                if rule == true
                    @includeAll scriptType
                else
                    @include scriptType, ns for ns in *(rule.include or {})
                    @exclude scriptType, ns for ns in *(rule.exclude or {})

    --- Lazily creates and returns the rule table for a script type.
    -- @local
    ruleFor: (scriptType) =>
        @rules[scriptType] or= {include: {}, exclude: {}}
        @rules[scriptType]

    --- Includes a single namespace of the given script type.
    -- @return ScriptTargetFilter self
    include: (scriptType, namespace) =>
        @ruleFor(scriptType).include[namespace] = true
        @

    --- Includes every namespace of the given script type, or — when called without an
    --- argument — every namespace of every script type.
    -- @return ScriptTargetFilter self
    includeAll: (scriptType) =>
        if scriptType
            @ruleFor(scriptType).all = true
        else
            @includeAll t for t in *@@scriptTypeList
        @

    --- Excludes a single namespace of the given script type (takes precedence over includes).
    -- @return ScriptTargetFilter self
    exclude: (scriptType, namespace) =>
        @ruleFor(scriptType).exclude[namespace] = true
        @

    --- Returns the script types this filter would process (those carrying any rule), sorted.
    -- @return {scriptType, ...}
    scriptTypes: =>
        [t for t in *@@scriptTypeList when @rules[t]]

    --- Tests whether a script of the given type and namespace should be processed.
    -- @return boolean
    matches: (scriptType, namespace) =>
        rule = @rules[scriptType]
        return false unless rule
        return false if rule.exclude[namespace]
        return true if rule.all
        rule.include[namespace] or false
