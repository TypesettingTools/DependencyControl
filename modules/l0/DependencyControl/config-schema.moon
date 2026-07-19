-- The DependencyControl global config: the cross-cutting sectioned defaults and the one-time migration that
-- lifts a flat pre-sectioned config into those sections. A setting read by a single class keeps its default
-- on that class (e.g. Updater.defaultCheckInterval, FileCache.defaultMaxAge). Only settings shared across
-- subsystems default here.

Common = require "l0.DependencyControl.Common"
SemanticVersion = require "l0.DependencyControl.SemanticVersion"

CONFIG_SCHEMA_ID_CURRENT = "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/schemas/config/v0.7.0.json"

-- Per-section defaults. Each section under `sections` is loaded as its own ConfigView with these defaults
-- and handed to the classes of that domain. A section key is kept even when the section has no shared
-- default (e.g. `feeds`), so a view on a section the user hasn't touched still resolves to a table.
sections = {
  updates: {
    blockPrivateHosts: true
  }
  feeds: {}
  logging: {
    defaultLevel: 3
    toFile: true
  }
  paths: {
    config: "?user/config"
    log: "?user/log"
    cache: "?user/cache"
  }
}

-- Old flat config key -> {section, newKey, transform?}, for the one-time lift from the flat pre-sectioned
-- layout into topic sections; a transform maps the old value onto the new key's value domain. Only v0.6.3
-- keys appear here: v0.7.0 was never released, so keys added since need no migration and, if present in a
-- dev config, are simply left in place.
keyMap = {
  updaterEnabled: {"updates", "mode", (enabled) -> enabled and "auto-update" or "off"}
  updateInterval: {"updates", "checkInterval"}
  updateWaitTimeout: {"updates", "waitTimeout"}
  updateOrphanTimeout: {"updates", "orphanTimeout"}
  extraFeeds: {"feeds", "extraFeeds"}
  traceLevel: {"logging", "defaultLevel"}
  writeLogs: {"logging", "toFile"}
  logMaxFiles: {"logging", "maxFiles"}
  logMaxAge: {"logging", "maxAge"}
  logMaxSize: {"logging", "maxSize"}
  configDir: {"paths", "config"}
  logDir: {"paths", "log"}
}

-- v0.6.3 keys removed outright on migration: settings dropped in v0.7.0 with no sectioned replacement.
droppedKeys = {"tryAllFeeds", "dumpFeeds"}

-- pre-0.7 published these packages on an `alpha` channel only, pinning every install to it; v0.7.0 makes
-- `stable` their default. rewrite the pin so those installs track `stable`, scoped to DependencyControl's
-- own packages so a channel deliberately chosen for a third-party feed is left alone.
channelRename = {
  packages: Common.makeSet {"l0.DependencyControl", "l0.DependencyControl.Toolbox"}
  from: "alpha"
  to: "stable"
}

---Migrates a whole config-file table up to the current schema, in place, when its root `$schema` predates it.
---For a pre-`$schema` config it lifts flat `config`-hive keys into topic sections and rewrites each record's
---pre-0.7 `unmanaged` flag into its recordType and its packed-integer version into a semver string; a config
---that already carries a `$schema`, and any keys none of these cover, are left untouched.
---Shaped as ConfigHandler's migration callback: the handler stamps the new `$schema` when this returns true.
---@param config table The whole config-file table, mutated in place (the `config` hive and the record sections).
---@param currentSchemaId? string The `$schema` found in the file, or nil for a pre-`$schema` (flat) config.
---@param targetSchemaId? string The schema being migrated to (unused here; the handler applies it).
---@return boolean migrated Whether a migration was applied.
migrate = (config, currentSchemaId, targetSchemaId) ->
  return false if currentSchemaId -- has a $schema → already sectioned; nothing to lift

  configHive = config.config
  if type(configHive) == "table"
    for oldKey, dest in pairs keyMap
      value = configHive[oldKey]
      continue if value == nil
      section, newKey, transform = dest[1], dest[2], dest[3]
      value = transform value if transform
      configHive[section] = {} unless type(configHive[section]) == "table"
      configHive[section][newKey] = value
      configHive[oldKey] = nil

    configHive[k] = nil for k in *droppedKeys
    configHive.formatVersion = nil -- obsolete pre-`$schema` marker, superseded by the root `$schema`

  -- pre-0.7 stored a record's type as a boolean `unmanaged` flag and its version as a packed integer.
  -- rewrite the flag as a recordType and the version as a semver string
  for section in *Common.ScriptTypeSection.values
    records = config[section]
    continue unless type(records) == "table"
    for namespace, record in pairs records
      continue unless type(record) == "table"
      record.recordType = Common.RecordType.Unmanaged if record.unmanaged
      record.unmanaged = nil
      record.version = SemanticVersion\toString record.version if type(record.version) == "number"
      if channelRename.packages[namespace]
        record.lastChannel = channelRename.to if record.lastChannel == channelRename.from
        record.activeChannel = channelRename.to if record.activeChannel == channelRename.from
  return true

{
  :CONFIG_SCHEMA_ID_CURRENT
  :sections
  migration: {:migrate, :keyMap, :droppedKeys}
}
