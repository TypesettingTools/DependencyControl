-- ConfigView tests: hive accessor and defaults proxy.
-- Called from Tests.moon as: (require "...test.ConfigView")!
->
  ConfigHandler = require "l0.DependencyControl.ConfigHandler"
  ConfigView    = require "l0.DependencyControl.ConfigView"

  {
    _description: "Tests for the ConfigView hive accessor and defaults proxy."

    -- new

    new_orphan: (ut) ->
      view = ConfigView nil, "section"
      ut\assertEquals view.__hivePath[1], "section"
      ut\assertEquals #view.__hivePath, 1
      ut\assertNil view.__configHandler
      ut\assertEquals view.userConfig, {}
      ut\assertNil view.file

    new_withHandler: (ut) ->
      handler = ConfigHandler nil
      handler.filePath = "/test/config.json"
      handler.config = {section: {key: "value"}}
      view = ConfigView handler, {"section"}
      ut\assertEquals view.__configHandler, handler
      ut\assertEquals view.userConfig.key, "value"
      ut\assertEquals view.file, "/test/config.json"

    new_stringHivePath: (ut) ->
      view = ConfigView nil, "mySection"
      ut\assertEquals view.__hivePath[1], "mySection"
      ut\assertEquals #view.__hivePath, 1

    new_tableHivePath: (ut) ->
      view = ConfigView nil, {"a", "b"}
      ut\assertEquals view.__hivePath[1], "a"
      ut\assertEquals view.__hivePath[2], "b"

    -- isOverlappingView

    isOverlappingView_differentHandler: (ut) ->
      handler1 = ConfigHandler nil
      handler2 = ConfigHandler nil
      view1 = ConfigView handler1, {"section"}
      view2 = ConfigView handler2, {"section"}
      result, err = view1\isOverlappingView view2
      ut\assertNil result
      ut\assertString err

    isOverlappingView_root: (ut) ->
      handler = ConfigHandler nil
      root  = ConfigView handler, {}
      child = ConfigView handler, {"section"}
      ut\assertTrue root\isOverlappingView child

    isOverlappingView_overlap: (ut) ->
      handler = ConfigHandler nil
      parent = ConfigView handler, {"a", "b"}
      child  = ConfigView handler, {"a", "b", "c"}
      ut\assertTrue parent\isOverlappingView child

    isOverlappingView_disjoint: (ut) ->
      handler = ConfigHandler nil
      viewA = ConfigView handler, {"a"}
      viewB = ConfigView handler, {"b"}
      ut\assertFalse viewA\isOverlappingView viewB

    -- config proxy: read/write behavior

    config_readUser: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {key: "userValue"}}
      view = ConfigView handler, {"section"}, {key: "defaultValue"}
      ut\assertEquals view.config.key, "userValue"

    config_readDefault: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {}}
      view = ConfigView handler, {"section"}, {key: "defaultValue"}
      ut\assertEquals view.config.key, "defaultValue"

    config_write: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {}}
      view = ConfigView handler, {"section"}
      view.config.newKey = "written"
      ut\assertEquals view.userConfig.newKey, "written"

    -- refresh: re-links userConfig to handler's current hive table

    refresh_success: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {key: "initial"}}
      view = ConfigView handler, {"section"}
      ut\assertEquals view.userConfig.key, "initial"
      handler.config.section = {key: "updated"}  -- replace table, not just value
      view\refresh!
      ut\assertEquals view.userConfig.key, "updated"

    -- import

    import_simple: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {}}
      view = ConfigView handler, {"section"}
      changesMade = view\import {key: "value", num: 42}
      ut\assertTrue changesMade
      ut\assertEquals view.userConfig.key, "value"
      ut\assertEquals view.userConfig.num, 42

    import_updateOnly: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {existing: "old"}}
      view = ConfigView handler, {"section"}, {existing: "default"}
      view\import {existing: "new", notExisting: "skip"}, nil, true
      ut\assertEquals view.userConfig.existing, "new"
      ut\assertNil view.userConfig.notExisting

    import_skipPrivate: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {}}
      view = ConfigView handler, {"section"}
      view\import {pub: "ok", _priv: "hidden"}
      ut\assertEquals view.userConfig.pub, "ok"
      ut\assertNil view.userConfig._priv

    -- load / save / delete: stub handler methods, verify delegation

    load_noFilePath: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {}}
      view = ConfigView handler, {"section"}
      ut\assertFalse view\load!

    load_delegatesToHandler: (ut) ->
      handler = ConfigHandler nil
      handler.filePath = "/test/config.json"
      handler.config = {section: {}}
      loadStub = (ut\stub handler, "load")\returns true
      view = ConfigView handler, {"section"}
      result = view\load 500
      ut\assertTrue result
      loadStub\assertCalledOnce!

    save_noFilePath: (ut) ->
      handler = ConfigHandler nil
      handler.config = {section: {}}
      view = ConfigView handler, {"section"}
      ut\assertFalse view\save!

    save_delegatesToHandler: (ut) ->
      handler = ConfigHandler nil
      handler.filePath = "/test/config.json"
      handler.config = {section: {}}
      saveStub = (ut\stub handler, "save")\returns true
      view = ConfigView handler, {"section"}
      result = view\save 250
      ut\assertTrue result
      saveStub\assertCalledOnce!

    delete_purgesAndSaves: (ut) ->
      handler = ConfigHandler nil
      handler.filePath = "/test/config.json"
      handler.config = {section: {key: "value"}}
      newHive = {}
      purgeStub = (ut\stub handler, "purgeHive")\returns newHive
      saveStub  = (ut\stub handler, "save")\returns true
      view = ConfigView handler, {"section"}
      result = view\delete!
      ut\assertTrue result
      purgeStub\assertCalledOnce!
      saveStub\assertCalledOnce!
      ut\assertEquals view.userConfig, newHive

    _order: {
      "new_orphan", "new_withHandler", "new_stringHivePath", "new_tableHivePath",
      "isOverlappingView_differentHandler", "isOverlappingView_root",
      "isOverlappingView_overlap", "isOverlappingView_disjoint",
      "config_readUser", "config_readDefault", "config_write",
      "refresh_success",
      "import_simple", "import_updateOnly", "import_skipPrivate",
      "load_noFilePath", "load_delegatesToHandler",
      "save_noFilePath", "save_delegatesToHandler",
      "delete_purgesAndSaves"
    }
  }
