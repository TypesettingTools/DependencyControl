-- Additional UpdateFeed tests: getModuleVersion, getFileDeployPath, walkFiles, deployFiles.
-- Called from Tests.moon as: (require "...test.UpdateFeed") basePath, DepCtrl
(basePath, DepCtrl) ->
  Common            = require "l0.DependencyControl.Common"
  FileOps           = require "l0.DependencyControl.FileOps"
  UpdateFeed        = require "l0.DependencyControl.UpdateFeed"
  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"

  {
    _description: "Additional UpdateFeed tests: getModuleVersion, getFileDeployPath, walkFiles, deployFiles."

    -- getModuleVersion

    getModuleVersion_defaultChannel: (ut) ->
      feed = {
        data: {modules: {"test.NS": {channels: {
          release: {default: true, version: "1.2.3", files: {}}
          nightly: {version: "2.0.0", files: {}}
        }}}},
        __class: UpdateFeed
      }
      ut\assertEquals UpdateFeed.getModuleVersion(feed, "test.NS"), "1.2.3"

    getModuleVersion_fallback: (ut) ->
      feed = {
        data: {modules: {"test.NS": {channels: {alpha: {version: "2.0.0", files: {}}}}}},
        __class: UpdateFeed
      }
      ut\assertEquals UpdateFeed.getModuleVersion(feed, "test.NS"), "2.0.0"

    getModuleVersion_missing: (ut) ->
      feed = {data: {modules: {}}, __class: UpdateFeed}
      ut\assertNil UpdateFeed.getModuleVersion feed, "no.Such.NS"

    -- getFileDeployPath

    getFileDeployPath_module: (ut) ->
      (ut\stub aegisub, "decode_path")\calls (path) -> path\gsub("^%?user", basePath)
      result = UpdateFeed.getFileDeployPath UpdateFeed, "l0.NS", Common.ScriptType.Module, "/NS.moon", "script", "?user"
      ut\assertString result
      ut\assertContains result, "NS.moon"
      ut\assertContains result, "l0"

    getFileDeployPath_test: (ut) ->
      (ut\stub aegisub, "decode_path")\calls (path) -> path\gsub("^%?user", basePath)
      result = UpdateFeed.getFileDeployPath UpdateFeed, "l0.NS", Common.ScriptType.Module, "/NS.moon", "test", "?user"
      ut\assertString result
      ut\assertContains result, "DepUnit"

    -- walkFiles

    walkFiles_yieldsProxies: (ut) ->
      feed = {
        data: {
          modules: {"test.NS": {channels: {release: {version: "1.0.0",
            files: {{name: "NS.moon", localFileBasePath: "./"}}}}}},
          macros: {}
        },
        feedDir: basePath,
        __class: UpdateFeed
      }
      results = {}
      for file, channel, pkg, section, scriptType in UpdateFeed.walkFiles(feed)
        results[#results + 1] = {:file, :channel, :pkg, :section, :scriptType}
      ut\assertEquals #results, 1
      ut\assertEquals results[1].pkg.namespace, "test.NS"
      ut\assertEquals results[1].channel.name, "release"
      ut\assertEquals results[1].file.name, "NS.moon"
      ut\assertEquals results[1].section, "modules"
      ut\assertEquals results[1].scriptType, Common.ScriptType.Module

    walkFiles_localFilePath: (ut) ->
      feed = {
        data: {
          modules: {"test.NS": {channels: {release: {version: "1.0.0",
            files: {{name: "NS.moon", localFileBasePath: "./"}}}}}},
          macros: {}
        },
        feedDir: basePath,
        __class: UpdateFeed
      }
      for file in UpdateFeed.walkFiles(feed)
        ut\assertString file.localFilePath
        ut\assertContains file.localFilePath, "NS.moon"
        break

    -- deployFiles

    deployFiles_copiesToDist: (ut) ->
      feed = {
        data: {modules: {}, macros: {}},
        feedDir: basePath, logger: DepCtrl.logger, __class: UpdateFeed
      }
      srcPath = "#{basePath}/NS.moon"
      dstPath = "#{basePath}/dst/NS.moon"
      fakeFile = setmetatable {}, {__index: (_, k) ->
        if k == "localFilePath" then srcPath
        elseif k == "name" then "NS.moon"
        elseif k == "type" then "script"
      }
      fakeChan = setmetatable {}, {__index: (_, k) -> k == "name" and "release" or nil}
      fakePkg  = setmetatable {}, {__index: (_, k) -> k == "namespace" and "test.NS" or nil}
      (ut\stub feed, "walkFiles")\calls (self, scriptTypes) ->
        coroutine.wrap ->
          coroutine.yield fakeFile, fakeChan, fakePkg, "modules", Common.ScriptType.Module
      (ut\stub FILEOPS_MODULE_NAME, "exists")\returns true
      (ut\stub UpdateFeed, "getFileDeployPath")\returns dstPath
      (ut\stub FILEOPS_MODULE_NAME, "mkdir")\returns true
      copyStub = (ut\stub FILEOPS_MODULE_NAME, "copy")\returns true
      fileCount, errCount = UpdateFeed.deployFiles feed, basePath, nil, true
      ut\assertEquals fileCount, 1
      ut\assertEquals errCount, 0
      copyStub\assertCalledOnce!

    deployFiles_skipExistingNoClobber: (ut) ->
      feed = {
        data: {modules: {}, macros: {}},
        feedDir: basePath, logger: DepCtrl.logger, __class: UpdateFeed
      }
      srcPath = "#{basePath}/NS.moon"
      dstPath = "#{basePath}/dst/NS.moon"
      fakeFile = setmetatable {}, {__index: (_, k) ->
        if k == "localFilePath" then srcPath
        elseif k == "name" then "NS.moon"
        elseif k == "type" then "script"
      }
      fakeChan = setmetatable {}, {__index: (_, k) -> k == "name" and "release" or nil}
      fakePkg  = setmetatable {}, {__index: (_, k) -> k == "namespace" and "test.NS" or nil}
      (ut\stub feed, "walkFiles")\calls (self, scriptTypes) ->
        coroutine.wrap ->
          coroutine.yield fakeFile, fakeChan, fakePkg, "modules", Common.ScriptType.Module
      (ut\stub FILEOPS_MODULE_NAME, "exists")\returns true
      (ut\stub UpdateFeed, "getFileDeployPath")\returns dstPath
      copyStub = (ut\stub FILEOPS_MODULE_NAME, "copy")\returns true
      fileCount, errCount = UpdateFeed.deployFiles feed, basePath
      ut\assertEquals fileCount, 0
      ut\assertEquals errCount, 0
      copyStub\assertNotCalled!

    deployFiles_countsMissingSource: (ut) ->
      feed = {
        data: {modules: {}, macros: {}},
        feedDir: basePath, logger: DepCtrl.logger, __class: UpdateFeed
      }
      fakeFile = setmetatable {}, {__index: (_, k) ->
        if k == "localFilePath" then nil
        elseif k == "name" then "NS.moon"
      }
      fakeChan = setmetatable {}, {__index: (_, k) -> k == "name" and "release" or nil}
      fakePkg  = setmetatable {}, {__index: (_, k) -> k == "namespace" and "test.NS" or nil}
      (ut\stub feed, "walkFiles")\calls (self, scriptTypes) ->
        coroutine.wrap ->
          coroutine.yield fakeFile, fakeChan, fakePkg, "modules", Common.ScriptType.Module
      fileCount, errCount = UpdateFeed.deployFiles feed, basePath
      ut\assertEquals fileCount, 0
      ut\assertEquals errCount, 1

    _order: {
      "getModuleVersion_defaultChannel", "getModuleVersion_fallback", "getModuleVersion_missing",
      "getFileDeployPath_module", "getFileDeployPath_test",
      "walkFiles_yieldsProxies", "walkFiles_localFilePath",
      "deployFiles_copiesToDist", "deployFiles_skipExistingNoClobber",
      "deployFiles_countsMissingSource"
    }
  }
