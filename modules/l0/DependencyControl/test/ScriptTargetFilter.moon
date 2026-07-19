-- ScriptTargetFilter tests: include/exclude rules, matching, and fluent construction.
-- Called from test.moon as: (controls\requireTest "ScriptTargetFilter")!
() ->
  Common = require "l0.DependencyControl.Common"
  ScriptTargetFilter = require "l0.DependencyControl.ScriptTargetFilter"
  Module = Common.ScriptType.Module
  Automation = Common.ScriptType.Automation

  {
    _description: "Tests for ScriptTargetFilter: include/exclude rules, matching, and chaining."

    include_singleNamespace: (ut) ->
      f = ScriptTargetFilter!\include Module, "l0.DependencyControl"
      ut\assertTrue f\matches Module, "l0.DependencyControl"
      ut\assertFalse f\matches Module, "l0.Other"
      ut\assertFalse f\matches Automation, "l0.DependencyControl"

    includeAll_singleType: (ut) ->
      f = ScriptTargetFilter!\includeAll Module
      ut\assertTrue f\matches Module, "anything"
      ut\assertFalse f\matches Automation, "anything"

    includeAll_everything: (ut) ->
      f = ScriptTargetFilter!\includeAll!
      ut\assertTrue f\matches Module, "x"
      ut\assertTrue f\matches Automation, "y"

    matches_noRuleIsFalse: (ut) ->
      ut\assertFalse ScriptTargetFilter!\matches Module, "x"

    exclude_takesPrecedenceOverAll: (ut) ->
      f = ScriptTargetFilter!\includeAll(Module)\exclude Module, "l0.Skip"
      ut\assertTrue f\matches Module, "l0.Keep"
      ut\assertFalse f\matches Module, "l0.Skip"

    exclude_overridesInclude: (ut) ->
      f = ScriptTargetFilter!\include(Module, "l0.X")\exclude Module, "l0.X"
      ut\assertFalse f\matches Module, "l0.X"

    chaining_returnsSelf: (ut) ->
      f = ScriptTargetFilter!
      ut\assertEquals f\include(Module, "a"), f
      ut\assertEquals f\includeAll(Module), f
      ut\assertEquals f\exclude(Module, "b"), f

    scriptTypes_listsTypesWithRules: (ut) ->
      types = ScriptTargetFilter!\includeAll(Module)\scriptTypes!
      ut\assertEquals #types, 1
      ut\assertEquals types[1], Module

    scriptTypes_empty: (ut) ->
      ut\assertEquals #(ScriptTargetFilter!\scriptTypes!), 0

    new_fromSpecBooleanAll: (ut) ->
      f = ScriptTargetFilter {[Module]: true}
      ut\assertTrue f\matches Module, "x"
      ut\assertFalse f\matches Automation, "x"

    new_fromSpecIncludeExclude: (ut) ->
      f = ScriptTargetFilter {[Module]: {include: {"l0.A", "l0.B"}, exclude: {"l0.B"}}}
      ut\assertTrue f\matches Module, "l0.A"
      ut\assertFalse f\matches Module, "l0.B"
      ut\assertFalse f\matches Module, "l0.C"

    _order: {
      "include_singleNamespace", "includeAll_singleType", "includeAll_everything",
      "matches_noRuleIsFalse", "exclude_takesPrecedenceOverAll", "exclude_overridesInclude",
      "chaining_returnsSelf", "scriptTypes_listsTypesWithRules", "scriptTypes_empty",
      "new_fromSpecBooleanAll", "new_fromSpecIncludeExclude"
    }
  }
