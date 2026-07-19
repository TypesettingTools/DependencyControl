MIN_MOONSCRIPT_VERSION = "0.3.0"

SemanticVersion = require "l0.DependencyControl.SemanticVersion"
moonscript = require 'moonscript.version'
assert SemanticVersion\check(moonscript.version, MIN_MOONSCRIPT_VERSION),
  [[ DependencyControl requires Moonscript v%s or later to work, 
however the Version %s provided by your Aegisub installation is outdated.
Update to a recent Aegisub build to resolve this issue. 
]]\format MIN_MOONSCRIPT_VERSION, moonscript.version


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

Common = require "l0.DependencyControl.Common"
ConfigHandler = require "l0.DependencyControl.ConfigHandler"
ConfigView = require "l0.DependencyControl.ConfigView"
Crypto = require "l0.DependencyControl.Crypto"
Downloader = require "l0.DependencyControl.Downloader"
Enum = require "l0.DependencyControl.Enum"
EventEmitter = require "l0.DependencyControl.EventEmitter"
FeedInventory = require "l0.DependencyControl.FeedInventory"
FeedLoader = require "l0.DependencyControl.FeedLoader"
FeedManager = require "l0.DependencyControl.FeedManager"
FeedTrust = require "l0.DependencyControl.FeedTrust"
FileOps = require "l0.DependencyControl.FileOps"
Finalizer = require "l0.DependencyControl.Finalizer"
GitRepository = require "l0.DependencyControl.GitRepository"
Host = require "l0.DependencyControl.Host"
Lock = require "l0.DependencyControl.Lock"
Logger = require "l0.DependencyControl.Logger"
PackageRecord = require "l0.DependencyControl.PackageRecord"
Accessors = require "l0.DependencyControl.Accessors"
Stub = require "l0.DependencyControl.Stub"
Timer = require "l0.DependencyControl.Timer"
UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"
UpdateFeed = require "l0.DependencyControl.UpdateFeed"
Updater = require "l0.DependencyControl.Updater"

---Main DependencyControl entry point.
---Provides package management and access to all sub-modules.
---@class DependencyControl: PackageRecord
class DependencyControl extends PackageRecord
  @Common = Common
  @ConfigHandler = ConfigHandler
  @ConfigView = ConfigView
  @Crypto = Crypto
  @Downloader = Downloader
  @Enum = Enum
  @EventEmitter = EventEmitter
  @FeedInventory = FeedInventory
  @FeedLoader = FeedLoader
  @FeedManager = FeedManager
  @FeedTrust = FeedTrust
  @FileOps = FileOps
  @GitRepository = GitRepository
  @Host = Host
  @Lock = Lock
  @Logger = Logger
  @PackageRecord = PackageRecord
  @Stub = Stub
  @Timer = Timer
  @UpdateFeed = UpdateFeed
  @Updater = Updater
  @UnitTestSuite = UnitTestSuite
  @Finalizer = Finalizer
  @SemanticVersion = SemanticVersion

-- inherit PackageRecord's version accessor before constructing any instance below
Accessors.install DependencyControl

rec = DependencyControl{
  name: "DependencyControl",
  version: "0.7.0", -- @{l0.DependencyControl:version}
  description: "Provides script management and auto-updating for Aegisub macros and modules.",
  author: "line0",
  url: "http://github.com/TypesettingTools/DependencyControl",
  moduleName: "l0.DependencyControl",
  feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/DependencyControl.json",
  provides: {
    {name: "BM.BadMutex", version: "^0.1.3"},
    {name: "DM.DownloadManager", version: "^0.3.1"},
    {name: "PT.PreciseTimer", version: "^0.1.6"},
  }
}
DependencyControl.__class.version = rec
LOADED_MODULES[rec.moduleName], package.loaded[rec.moduleName] = DependencyControl, DependencyControl
rec\requireModules!
rec\register DependencyControl

return DependencyControl
