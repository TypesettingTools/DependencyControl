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
      -- walkFiles lazily loads via ensureLoaded; stub it away since data is supplied directly
      ensureLoadedStub = (ut\stub feed, "ensureLoaded")\calls (self) -> self.data
      results = {}
      for file, channel, pkg, section, scriptType in UpdateFeed.walkFiles(feed)
        results[#results + 1] = {:file, :channel, :pkg, :section, :scriptType}
      ut\assertEquals #results, 1
      ut\assertEquals results[1].pkg.namespace, "test.NS"
      ut\assertEquals results[1].channel.name, "release"
      ut\assertEquals results[1].file.name, "NS.moon"
      ut\assertEquals results[1].section, "modules"
      ut\assertEquals results[1].scriptType, Common.ScriptType.Module
      ensureLoadedStub\assertCalledOnce!

    -- walkFiles yields files untouched; the localFilePath accessor itself is attached by `expand`
    -- (covered by expand_attachesLocalFilePath), so here it's supplied directly on the file record.
    walkFiles_passesThroughLocalFilePath: (ut) ->
      feed = {
        data: {
          modules: {"test.NS": {channels: {release: {version: "1.0.0",
            files: {{name: "NS.moon", localFilePath: FileOps.joinPath(basePath, "NS.moon")}}}}}},
          macros: {}
        },
        feedDir: basePath,
        __class: UpdateFeed
      }
      (ut\stub feed, "ensureLoaded")\calls (self) -> self.data
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

    -- ensureLoaded

    ensureLoaded_localWithoutFileName_errors: (ut) ->
      result, err = UpdateFeed.ensureLoaded {__class: UpdateFeed}, UpdateFeed.ExpansionMode.Local
      ut\assertNil result
      ut\assertString err

    ensureLoaded_reusesMatchingExpansion: (ut) ->
      data = {modules: {}}
      feed = {data: data, expansionMode: UpdateFeed.ExpansionMode.Local, fileName: "x.json", __class: UpdateFeed}
      ut\assertIs UpdateFeed.ensureLoaded(feed, UpdateFeed.ExpansionMode.Local), data

    -- refreshFiles: returns (changed, errors) and mutates the raw channel in place

    refreshFiles_updatesChangedSha: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "exists")\returns true
      (ut\stub FILEOPS_MODULE_NAME, "getHash")\returns "deadbeef"
      rawChannel = {files: {{name: "a.moon", sha1: "OLDHASH"}}}
      expandedChannel = {files: {{localFilePath: "/x/a.moon"}}}
      changed, errors = UpdateFeed.refreshFiles {__class: UpdateFeed}, rawChannel, expandedChannel
      ut\assertTrue changed
      ut\assertEquals #errors, 0
      ut\assertEquals rawChannel.files[1].sha1, "DEADBEEF"

    refreshFiles_unchangedSha: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "exists")\returns true
      (ut\stub FILEOPS_MODULE_NAME, "getHash")\returns "abc123"
      rawChannel = {files: {{name: "a.moon", sha1: "ABC123"}}}
      changed, errors = UpdateFeed.refreshFiles {__class: UpdateFeed}, rawChannel, {files: {{localFilePath: "/x/a.moon"}}}
      ut\assertFalse changed
      ut\assertEquals #errors, 0

    refreshFiles_missingFileFlagsDelete: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "exists")\returns false   -- vanished from disk
      rawChannel = {files: {{name: "gone.moon", sha1: "X"}}}
      changed, errors = UpdateFeed.refreshFiles {__class: UpdateFeed}, rawChannel, {files: {{localFilePath: "/x/gone.moon"}}}
      ut\assertTrue changed
      ut\assertTrue rawChannel.files[1].delete
      ut\assertEquals #errors, 0

    refreshFiles_sha1FailureCollectsError: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "exists")\returns true
      (ut\stub FILEOPS_MODULE_NAME, "getHash")\returns nil, "boom"
      rawChannel = {files: {{name: "a.moon", sha1: "X"}}}
      changed, errors = UpdateFeed.refreshFiles {__class: UpdateFeed}, rawChannel, {files: {{localFilePath: "/x/a.moon"}}}
      ut\assertFalse changed
      ut\assertEquals #errors, 1
      ut\assertContains errors[1], "a.moon"

    refreshFiles_noLocalPathCollectsError: (ut) ->
      rawChannel = {files: {{name: "a.moon", sha1: "X"}}}
      changed, errors = UpdateFeed.refreshFiles {__class: UpdateFeed}, rawChannel, {files: {{}}}
      ut\assertFalse changed
      ut\assertEquals #errors, 1

    -- updatePackage: returns a per-package result rather than mutating shared state

    updatePackage_notInRaw: (ut) ->
      feed = {rawFeedData: {modules: {}}, data: {modules: {}}, __class: UpdateFeed}
      result = UpdateFeed.updatePackage feed, Common.ScriptType.Module, "no.Such", nil
      ut\assertFalse result.changed
      ut\assertEquals #result.errors, 1
      ut\assertContains result.errors[1], "no.Such"

    updatePackage_collectsResultAndResetsReleased: (ut) ->
      ns = "test.NS"
      feed = {
        rawFeedData: {modules: {[ns]: {channels: {release: {default: true, released: "2024-01-01", files: {}}}}}},
        data: {modules: {[ns]: {channels: {release: {files: {}}}}}},
        __class: UpdateFeed
      }
      (ut\stub feed, "refreshVersionRecord")\returns true       -- version/deps changed
      (ut\stub feed, "refreshFiles")\returns false, {}
      result = UpdateFeed.updatePackage feed, Common.ScriptType.Module, ns, nil
      ut\assertEquals result.namespace, ns
      ut\assertEquals result.channel, "release"
      ut\assertTrue result.changed
      ut\assertEquals #result.errors, 0
      ut\assertNotNil feed.rawFeedData.modules[ns].channels.release.released   -- reset to null sentinel

    updatePackage_collectsRefreshError: (ut) ->
      ns = "test.NS"
      feed = {
        rawFeedData: {modules: {[ns]: {channels: {release: {default: true, files: {}}}}}},
        data: {modules: {[ns]: {channels: {release: {files: {}}}}}},
        __class: UpdateFeed
      }
      (ut\stub feed, "refreshVersionRecord")\returns nil, "no record"
      (ut\stub feed, "refreshFiles")\returns false, {}
      result = UpdateFeed.updatePackage feed, Common.ScriptType.Module, ns, nil
      ut\assertEquals #result.errors, 1
      ut\assertContains result.errors[1], "no record"

    _order: {
      "getModuleVersion_defaultChannel", "getModuleVersion_fallback", "getModuleVersion_missing",
      "getFileDeployPath_module", "getFileDeployPath_test",
      "walkFiles_yieldsProxies", "walkFiles_passesThroughLocalFilePath",
      "deployFiles_copiesToDist", "deployFiles_skipExistingNoClobber",
      "deployFiles_countsMissingSource",
      "ensureLoaded_localWithoutFileName_errors", "ensureLoaded_reusesMatchingExpansion",
      "refreshFiles_updatesChangedSha", "refreshFiles_unchangedSha", "refreshFiles_missingFileFlagsDelete",
      "refreshFiles_sha1FailureCollectsError", "refreshFiles_noLocalPathCollectsError",
      "updatePackage_notInRaw", "updatePackage_collectsResultAndResetsReleased",
      "updatePackage_collectsRefreshError"
    }
  }
