MIN_MOONSCRIPT_VERSION = "0.3.0"

SemanticVersion = require "l0.DependencyControl.SemanticVersion"
moonscript = require 'moonscript.version'
assert SemanticVersion\check(moonscript.version, MIN_MOONSCRIPT_VERSION),
  [[ DependencyControl requires Moonscript v%s or later to work,
however the Version %s provided by your Aegisub installation is outdated.
Update to a recent Aegisub build to resolve this issue.
]]\format MIN_MOONSCRIPT_VERSION, moonscript.version

-- DependencyControl also needs a LuaJIT built with Lua 5.2 compatibility (LUAJIT_ENABLE_LUA52COMPAT):
-- Accessors expose computed properties through the __pairs metamethod, and SemanticVersion compares
-- across types, neither of which works without it. Probe the __pairs feature we rely on directly.
lua52CompatEnabled = ->
  respected = false
  probe = setmetatable {}, {
    __pairs: ->
      respected = true
      -> nil
  }
  pairs probe
  respected

assert lua52CompatEnabled!,
  [[DependencyControl requires a LuaJIT built with Lua 5.2 compatibility (LUAJIT_ENABLE_LUA52COMPAT), which your Aegisub installation is missing.
Update to a recent Aegisub build to resolve this issue.]]


-- Install the module-provides searcher and register DepCtrl's bundled fallbacks before
-- the sub-modules below load.
ModuleProvider = require "l0.DependencyControl.ModuleProvider"
ModuleProvider\install!

provideBundled = (providerName, aliases, forceVar) ->
  if forceVar and os.getenv(forceVar) == "1"
    impl = require providerName
    package.loaded[alias] = impl for alias in *aliases
  else
    ModuleProvider\register alias, providerName for alias in *aliases

provideBundled "l0.dkjson", {"json", "dkjson"}
provideBundled "l0.DependencyControl.shims.BadMutex", {"BM.BadMutex"}, "DEPCTRL_FORCE_BUILTIN_MUTEX"
provideBundled "l0.DependencyControl.shims.DownloadManager", {"DM.DownloadManager"}, "DEPCTRL_FORCE_BUILTIN_DOWNLOADER"
provideBundled "l0.DependencyControl.shims.PreciseTimer", {"PT.PreciseTimer"}, "DEPCTRL_FORCE_BUILTIN_TIMER"

domain = require "l0.DependencyControl.domain"
environment = require "l0.DependencyControl.environment"
utils = require "l0.DependencyControl.utils"
ConfigHandler = require "l0.DependencyControl.ConfigHandler"
ConfigView = require "l0.DependencyControl.ConfigView"
Hash = require "l0.DependencyControl.hash"
Downloader = require "l0.DependencyControl.Downloader"
Enum = require "l0.DependencyControl.Enum"
EventEmitter = require "l0.DependencyControl.EventEmitter"
FeedInventory = require "l0.DependencyControl.FeedInventory"
FeedLoader = require "l0.DependencyControl.FeedLoader"
FeedManager = require "l0.DependencyControl.FeedManager"
FeedTrust = require "l0.DependencyControl.FeedTrust"
ffiPosix = require "l0.DependencyControl.helpers.ffi-posix"
ffiWindows = require "l0.DependencyControl.helpers.ffi-windows"
fileOps = require "l0.DependencyControl.file-ops"
Finalizer = require "l0.DependencyControl.Finalizer"
GitRepository = require "l0.DependencyControl.GitRepository"
Host = require "l0.DependencyControl.Host"
Lock = require "l0.DependencyControl.Lock"
Logger = require "l0.DependencyControl.Logger"
PackageRecord = require "l0.DependencyControl.PackageRecord"
pathOps = require "l0.DependencyControl.path-ops"
Accessors = require "l0.DependencyControl.Accessors"
Stub = require "l0.DependencyControl.Stub"
Timer = require "l0.DependencyControl.Timer"
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
UpdateTask = require "l0.DependencyControl.UpdateTask"
Updater = require "l0.DependencyControl.Updater"

---Main DependencyControl entry point.
---Provides package management and access to all sub-modules.
---@class DependencyControl: PackageRecord
class DependencyControl extends PackageRecord
  @Domain = domain
  @Environment = environment
  @Utils = utils
  @ConfigHandler = ConfigHandler
  @ConfigView = ConfigView
  @Hash = Hash
  @Downloader = Downloader
  @Enum = Enum
  @EventEmitter = EventEmitter
  @FeedInventory = FeedInventory
  @FeedLoader = FeedLoader
  @FeedManager = FeedManager
  @FeedTrust = FeedTrust
  -- both load on every platform; their calls only work on the one they wrap
  @FfiPosix = ffiPosix
  @FfiWindows = ffiWindows
  @FileOps = fileOps
  @GitRepository = GitRepository
  @Host = Host
  @Lock = Lock
  @Logger = Logger
  @PackageRecord = PackageRecord
  @PathOps = pathOps
  @Stub = Stub
  @Timer = Timer
  @UpdateFeed = UpdateFeed
  @UpdateTask = UpdateTask
  @Updater = Updater
  @UnitTestSuite = UnitTestSuite
  @Finalizer = Finalizer
  @SemanticVersion = SemanticVersion

-- inherit PackageRecord's version accessor before constructing any instance below
Accessors.install DependencyControl

rec = DependencyControl{
  name: "DependencyControl",
  version: "0.9.0", -- @{l0.DependencyControl:version}
  description: "Provides script management and auto-updating for Aegisub macros and modules.",
  author: "line0",
  url: "http://github.com/TypesettingTools/DependencyControl",
  moduleName: "l0.DependencyControl",
  feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/publish/DependencyControl.json",
  provides: {
    {name: "BM.BadMutex", version: "^0.1.3"},
    {name: "DM.DownloadManager", version: "^0.3.1"},
    {name: "PT.PreciseTimer", version: "^0.1.6"},
  },
  {
    {
      moduleName:"l0.dkjson",
      version: "0.7.0",
      url: "http://github.com/TypesettingTools/DependencyControl",
      feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/publish/DependencyControl.json"
    }
  }
}
DependencyControl.__class.version = rec
LOADED_MODULES[rec.moduleName], package.loaded[rec.moduleName] = DependencyControl, DependencyControl
rec\requireModules!
rec\register DependencyControl

return DependencyControl
