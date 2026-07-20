Logger = require "l0.DependencyControl.Logger"
constants = require "l0.DependencyControl.Constants"
Common = require "l0.DependencyControl.Common"
SemanticVersion = require "l0.DependencyControl.SemanticVersion"
ReleaseNotes = require "l0.DependencyControl.release-notes"

defaultLogger = Logger fileBaseName: "#{constants.DEPCTRL_SHORT_NAME}.ScriptUpdateRecord"

---@class FeedFileData
---@field name string Filename relative to the base URL.
---@field url? string Absolute download URL after template variable expansion.
---@field platform? string Target platform filter (e.g. "Windows-x64"); absent means all platforms.

---@class FeedChannelData
---@field version string Semantic version string of this release.
---@field files? FeedFileData[] Files provided by this release.
---@field platforms? string[] Platforms supported by this channel; absent means all platforms.
---@field default? boolean Whether this is the default channel.
---@field released? string ISO 8601 release date string (e.g. "2024-01-31" or "2024-01-31T23:59:00Z")
---@field fileBaseUrl? string Base URL prepended to file names during template expansion.

---@class FeedScriptData
---@field name string Display name of the script.
---@field channels table<string, FeedChannelData> Available update channels keyed by channel name.
---@field changelog? table<string, string|string[]> Version-keyed changelog entries; values are a single string or a list of strings.
---@field author? string Script author.
---@field url? string Project or homepage URL.
---@field feed? string URL of the script's primary update feed.

---@class FeedData
---@field name? string Display name of the feed.
---@field baseUrl? string Base URL used for template variable expansion across all entries.
---@field knownFeeds? table<string, string> Named registry of other feed URLs for cross-feed references.
---@field macros table<string, FeedScriptData> Automation scripts indexed by namespace.
---@field modules table<string, FeedScriptData> Modules indexed by namespace.

---Feed-specific update information for a single script in a selected channel.
---
---Fields of the underlying [FeedScriptData](lua://FeedScriptData) (name, changelog, etc.)
---are readable directly on the instance, and the active channel's
---[FeedChannelData](lua://FeedChannelData) fields (version, files, platforms, etc.) are
---exposed directly on the instance once a channel is selected.
---@class ScriptUpdateRecord
---@field namespace string Script namespace.
---@field data FeedScriptData Shallow copy of the raw script entry from the feed.
---@field config {c: {activeChannel?: string, lastChannel?: string, channels?: string[]}}
---@field moduleName string|false Namespace string for modules; false for automation scripts.
---@field logger Logger
---@field activeChannel? string Name of the currently active update channel.
---@field version? string Release version of the active channel (set by setChannel).
---@field files FeedFileData[] Platform-filtered file list for the active channel (set by setChannel).
---@field platforms? string[] Platforms supported by the active channel (set by setChannel).
class ScriptUpdateRecord
  msgs = {
    errors: {
      noActiveChannel: "No active channel."
    }
    changelog: {
      header: "Changelog for %s v%s (released %s):"
      verTemplate: "v %s:"
    }
  }

  -- Shared per-class metatable for the @data __index fallback; initialised lazily on first instantiation.
  instanceMetaTable = nil

  ---Creates an update record for a single script entry in a feed.
  ---@param namespace string
  ---@param data FeedScriptData
  ---@param config? {c: {activeChannel?: string}}
  ---@param scriptType ScriptType
  ---@param autoChannel? boolean Select the default channel on construction (default true).
  ---@param logger? Logger
  new: (@namespace, data, @config = {c:{}}, scriptType, autoChannel = true, @logger = defaultLogger) =>
    @data = {k, v for k, v in pairs data}
    @moduleName = scriptType == Common.ScriptType.Module and @namespace

    unless instanceMetaTable
      meta = getmetatable @
      instanceMetaTable = {__index: (t, k) ->
        v = meta[k]
        return v if v != nil
        d = rawget t, "data"
        return d and d[k]
      }
    setmetatable @, instanceMetaTable

    @setChannel! if autoChannel


  ---Returns all available channel names for this script and the default channel.
  ---@return string[] channels
  ---@return string? defaultChannel
  getChannels: =>
    channels, default = {}
    for name, channel in pairs @data.channels
      channels[#channels+1] = name
      if channel.default and not default
        default = name

    return channels, default

  ---Selects the active update channel and exposes its fields on this instance.
  ---@param channelName? string Channel to activate; defaults to config.c.activeChannel.
  ---@return boolean success
  ---@return string activeChannel
  setChannel: (channelName = @config.c.activeChannel) =>
    with @config.c
      .channels, default = @getChannels!
      .lastChannel or= channelName or default
      channelData = @data.channels[.lastChannel]
      @activeChannel = .lastChannel
      return false, @activeChannel unless channelData
      @[k] = v for k, v in pairs channelData

    @files = @files and [file for file in *@files when not file.platform or file.platform == Common.platform] or {}
    return true, @activeChannel

  ---Checks whether this script's active channel supports the current platform.
  ---@return boolean supported
  ---@return string platform
  checkPlatform: =>
    @logger\assert @activeChannel, msgs.errors.noActiveChannel
    return not @platforms or (Common.makeSet @platforms)[Common.platform], Common.platform

  ---Formats changelog entries from the current version down to a minimum version, grouping each
  ---version's entries into marker categories (Bug Fixes, New Features, …) with a glyph heading.
  ---@param versionRecord any Unused; present for API compatibility.
  ---@param minVer? number|string Oldest version to include (default 0, i.e. all).
  ---@return string changelog Formatted multi-line string, or "" if nothing to show. A version whose entries carry no markers lists them flat, without category headings.
  getChangelog: (versionRecord, minVer = 0) =>
    return "" unless "table" == type @changelog
    maxVer = SemanticVersion\toPacked @version
    minVer = SemanticVersion\toPacked minVer

    changelog = {}
    for ver, entry in pairs @changelog
      verNum = SemanticVersion\toPacked ver
      -- skip a malformed changelog version key. feed changelog keys aren't schema-validated, so toPacked
      -- returns false for them, and toString(false) or comparing false >= minVer would otherwise raise
      continue unless verNum
      if verNum >= minVer and verNum <= maxVer
        changelog[#changelog+1] = {verNum, SemanticVersion\toString(verNum), entry}

    return "" if #changelog == 0
    table.sort changelog, (a,b) -> a[1]>b[1]

    msg = {msgs.changelog.header\format @name, SemanticVersion\toString(@version), @released or "<no date>"}
    for chg in *changelog
      chg[3] = {chg[3]} if type(chg[3]) ~= "table"
      continue if #chg[3] == 0
      msg[#msg+1] = @logger\format msgs.changelog.verTemplate, 1, chg[2]
      block = ReleaseNotes.renderLog chg[3]
      msg[#msg+1] = block unless block == ""

    return table.concat msg, "\n"
