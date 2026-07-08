-- ScriptUpdateRecord tests: channel management and update record accessors.
-- Called from Tests.moon as: (require "...test.ScriptUpdateRecord")!
->
  Common             = require "l0.DependencyControl.Common"
  ScriptUpdateRecord = require "l0.DependencyControl.ScriptUpdateRecord"

  {
    _description: "Tests for ScriptUpdateRecord channel management and update record accessors."

    getChannels_basic: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}}, nightly: {version: "2.0.0", files: {}}}, name: "TestScript"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
      channels, default = sur\getChannels!
      ut\assertEquals #channels, 2
      ut\assertEquals default, "release"

    getChannels_noDefault: (ut) ->
      data = {channels: {alpha: {version: "1.0.0", files: {}}, beta: {version: "2.0.0", files: {}}}, name: "TestScript"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
      _, default = sur\getChannels!
      ut\assertNil default

    setChannel_valid: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}}, nightly: {version: "2.0.0", files: {}}}, name: "TestScript"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
      success, channel = sur\setChannel "nightly"
      ut\assertTrue success
      ut\assertEquals channel, "nightly"
      ut\assertEquals sur.version, "2.0.0"

    setChannel_invalid: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "TestScript"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module, false
      success, channel = sur\setChannel "nonexistent"
      ut\assertFalse success
      ut\assertEquals channel, "nonexistent"

    checkPlatform_noConstraint: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "T"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      result, platform = sur\checkPlatform!
      ut\assertTrue result
      ut\assertString platform

    checkPlatform_currentPlatform: (ut) ->
      -- platforms in channel data is copied to the instance via setChannel
      data = {channels: {release: {default: true, version: "1.0.0", files: {}, platforms: {Common.platform}}}, name: "T"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      result, _ = sur\checkPlatform!
      ut\assertTrue result

    checkPlatform_notMatching: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}, platforms: {"nonexistent-arch"}}}, name: "T"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      result, _ = sur\checkPlatform!
      ut\assertFalsy result

    getChangelog_noTable: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "T", changelog: "not a table"}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      ut\assertEquals sur\getChangelog(nil), ""

    getChangelog_inRange: (ut) ->
      data = {
        channels: {release: {default: true, version: "1.0.0", files: {}}},
        name: "TestScript",
        changelog: {["1.0.0"]: {"Initial release"}, ["0.5.0"]: {"Beta"}}
      }
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      result = sur\getChangelog nil
      ut\assertString result
      ut\assertContains result, "TestScript"
      ut\assertContains result, "Initial release"

    getChangelog_allOutOfRange: (ut) ->
      data = {channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "T", changelog: {["1.0.0"]: {"Initial release"}}}
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      ut\assertEquals sur\getChangelog(nil, "2.0.0"), ""

    -- a malformed changelog version key (unvalidated feed data) is skipped, not crashed on
    getChangelog_skipsMalformedKey: (ut) ->
      data = {
        channels: {release: {default: true, version: "1.0.0", files: {}}}, name: "TestScript"
        changelog: {["1.0.0"]: {"Initial release"}, ["not-a-version"]: {"Bogus"}}
      }
      sur = ScriptUpdateRecord "test.NS", data, {c:{}}, Common.ScriptType.Module
      result = sur\getChangelog nil
      ut\assertContains result, "Initial release"   -- valid entry still rendered
      ut\assertString result                         -- and no crash on the malformed key

    _order: {
      "getChannels_basic", "getChannels_noDefault",
      "setChannel_valid", "setChannel_invalid",
      "checkPlatform_noConstraint", "checkPlatform_currentPlatform", "checkPlatform_notMatching",
      "getChangelog_noTable", "getChangelog_inRange", "getChangelog_allOutOfRange",
      "getChangelog_skipsMalformedKey"
    }
  }
