-- config-schema tests: the sectioned defaults tree carries the cross-cutting policy defaults and keeps every
-- section present; the co-located migration lifts the v0.6.3 flat keys into their sections, drops obsolete
-- keys, is idempotent, and preserves unknown keys.
() ->
  schema = require "l0.DependencyControl.config-schema"
  Common = require "l0.DependencyControl.Common"

  {:migrate, :keyMap, :droppedKeys} = schema.migration

  -- the config keys shipped in v0.6.3 (the last release), each of which the migration must handle
  v063Keys = {
    "updaterEnabled", "updateInterval", "traceLevel", "extraFeeds", "tryAllFeeds", "dumpFeeds", "configDir"
    "logMaxFiles", "logMaxAge", "logMaxSize", "updateWaitTimeout", "updateOrphanTimeout", "logDir", "writeLogs"
  }

  {
    _description: "config-schema: cross-cutting sectioned defaults, plus the flat->sectioned migration."

    -- every domain section is present alongside the config schema id
    hasAllSections: (ut) ->
      ut\assertEquals type(schema.CONFIG_SCHEMA_ID_CURRENT), "string"
      ut\assertNotNil schema.sections[name] for name in *{"updates", "feeds", "logging", "paths"}

    -- the logging policy literals (which deliberately differ from Logger's own defaults) and the new cache base
    hasPolicyLiterals: (ut) ->
      ut\assertEquals schema.sections.logging.defaultLevel, 3
      ut\assertTrue schema.sections.logging.toFile
      ut\assertEquals schema.sections.paths.cache, "?user/cache"

    -- a flat v0.6.3 config (no root $schema) has every `config` hive key lifted into its section and renamed.
    -- Each mapped key is asserted against its explicitly-expected target, so a mis-pointed migration is caught.
    migratesFlatKeys: (ut) ->
      c = {config: {
        updaterEnabled: false, updateInterval: 999, updateWaitTimeout: 45, updateOrphanTimeout: 30
        traceLevel: 5, writeLogs: false, logMaxFiles: 12, logMaxAge: 34, logMaxSize: 56
        extraFeeds: {"x"}, configDir: "?user/config", logDir: "?user/log"
      }}
      ut\assertTrue migrate c, nil, schema.CONFIG_SCHEMA_ID_CURRENT
      cfg = c.config
      ut\assertEquals cfg.updates.mode, "off"   -- updaterEnabled: false maps onto the mode domain
      ut\assertEquals cfg.updates.checkInterval, 999
      ut\assertEquals cfg.updates.waitTimeout, 45
      ut\assertEquals cfg.updates.orphanTimeout, 30
      ut\assertEquals cfg.logging.defaultLevel, 5
      ut\assertEquals cfg.logging.toFile, false
      ut\assertEquals cfg.logging.maxFiles, 12
      ut\assertEquals cfg.logging.maxAge, 34
      ut\assertEquals cfg.logging.maxSize, 56
      ut\assertEquals cfg.feeds.extraFeeds, {"x"}
      ut\assertEquals cfg.paths.config, "?user/config"
      ut\assertEquals cfg.paths.log, "?user/log"
      -- the old flat keys are gone
      ut\assertNil cfg.updaterEnabled
      ut\assertNil cfg.traceLevel
      ut\assertNil cfg.extraFeeds

    -- obsolete v0.6.3 settings are dropped, not carried into a section
    dropsObsoleteKeys: (ut) ->
      c = {config: {tryAllFeeds: false, dumpFeeds: true}}
      migrate c, nil, schema.CONFIG_SCHEMA_ID_CURRENT
      ut\assertNil c.config.tryAllFeeds
      ut\assertNil c.config.dumpFeeds

    -- an obsolete pre-$schema `formatVersion` marker in the config hive is dropped on migration
    dropsObsoleteFormatVersion: (ut) ->
      c = {config: {formatVersion: 1, updaterEnabled: true}}
      migrate c, nil, schema.CONFIG_SCHEMA_ID_CURRENT
      ut\assertNil c.config.formatVersion
      ut\assertEquals c.config.updates.mode, "auto-update"   -- updaterEnabled: true maps onto the mode domain

    -- a config that already carries a $schema is sectioned; migrate leaves it untouched
    skipsWhenSchemaPresent: (ut) ->
      c = {["$schema"]: schema.CONFIG_SCHEMA_ID_CURRENT, config: {updates: {mode: "off"}}}
      ut\assertFalse migrate c, schema.CONFIG_SCHEMA_ID_CURRENT, schema.CONFIG_SCHEMA_ID_CURRENT
      ut\assertEquals c.config.updates.mode, "off"   -- unchanged
      ut\assertNil c.config.updates.checkInterval     -- not re-populated with defaults

    -- keys the migration doesn't know about — arbitrary user keys and unreleased post-v0.6.3 keys alike —
    -- are left in place (only dev configs have the latter, and they need no migration)
    preservesUnknownKeys: (ut) ->
      c = {config: {updaterEnabled: true, someUserKey: 42, trustedFeeds: {"t"}}}
      migrate c, nil, schema.CONFIG_SCHEMA_ID_CURRENT
      cfg = c.config
      ut\assertEquals cfg.someUserKey, 42
      ut\assertEquals cfg.trustedFeeds, {"t"}   -- a v0.7.0-dev key: not lifted into a section
      ut\assertNil cfg.feeds
      ut\assertEquals cfg.updates.mode, "auto-update"

    -- a pre-$schema config rewrites each record's boolean `unmanaged` flag into its recordType and drops the
    -- flag; a record without the flag keeps no recordType (loads as managed), and its other fields are untouched
    migratesLegacyUnmanagedFlag: (ut) ->
      c = {
        macros: {
          ["l0.old"]: {unmanaged: true, version: 1}
          ["l0.managed"]: {version: 2}
        }
        modules: {
          ["l0.mod"]: {unmanaged: true}
        }
      }
      migrate c, nil, schema.CONFIG_SCHEMA_ID_CURRENT
      ut\assertEquals c.macros["l0.old"].recordType, Common.RecordType.Unmanaged
      ut\assertNil c.macros["l0.old"].unmanaged        -- flag dropped
      ut\assertEquals c.macros["l0.old"].version, 1    -- sibling fields left alone
      ut\assertNil c.macros["l0.managed"].recordType   -- no flag -> stays managed
      ut\assertEquals c.modules["l0.mod"].recordType, Common.RecordType.Unmanaged
      ut\assertNil c.modules["l0.mod"].unmanaged

    -- the migration handles exactly the v0.6.3 keys: each is either lifted or dropped, and nothing else is
    handlesExactlyV063Keys: (ut) ->
      handled = {k, true for k in *droppedKeys}
      handled[k] = true for k in pairs keyMap
      ut\assertTrue handled[k], "v0.6.3 key '#{k}' is neither migrated nor dropped" for k in *v063Keys
      v063Set = {k, true for k in *v063Keys}
      ut\assertTrue v063Set[k], "migration handles '#{k}', which was not a v0.6.3 key" for k in pairs handled

    _order: {
      "hasAllSections", "hasPolicyLiterals"
      "migratesFlatKeys", "dropsObsoleteKeys", "dropsObsoleteFormatVersion", "skipsWhenSchemaPresent"
      "migratesLegacyUnmanagedFlag", "preservesUnknownKeys", "handlesExactlyV063Keys"
    }
  }
