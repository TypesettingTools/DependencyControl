MIN_MOONSCRIPT_VERSION = "0.3.0"

SemanticVersioning = require "l0.DependencyControl.SemanticVersioning"
moonscript = require 'moonscript.version'
assert SemanticVersioning\check(moonscript.version, MIN_MOONSCRIPT_VERSION), 
    [[ DependencyControl requires Moonscript v%s or later to work, 
however the Version %s provided by your Aegisub installation is outdated.
Update to a recent Aegisub build to resolve this issue. 
]]\format MIN_MOONSCRIPT_VERSION, moonscript.version


-- Install the module-provides searcher and register DepCtrl's bundled fallbacks before
-- the sub-modules below load (they `require` the bare names "json", "BM.BadMutex" and
-- "DM.DownloadManager"). By default the searcher defers to a separately installed native
-- module and only falls back to ours; the optional env var forces ours by preempting the
-- module cache.
ModuleProvider = require "l0.DependencyControl.ModuleProvider"
ModuleProvider.install!

provideBundled = (providerName, aliases, forceVar) ->
    if forceVar and os.getenv(forceVar) == "1"
        impl = require providerName
        package.loaded[alias] = impl for alias in *aliases
    else
        ModuleProvider.register alias, providerName for alias in *aliases

provideBundled "l0.dkjson", {"json", "dkjson"}
provideBundled "l0.DependencyControl.TerribleMutex", {"BM.BadMutex"}, "DEPCTRL_PREFER_FFI_MUTEX"
provideBundled "l0.DependencyControl.DownloadManager", {"DM.DownloadManager"}, "DEPCTRL_PREFER_FFI_DOWNLOADER"

Logger =         require "l0.DependencyControl.Logger"
UpdateFeed =     require "l0.DependencyControl.UpdateFeed"
ConfigHandler =  require "l0.DependencyControl.ConfigHandler"
FileOps =        require "l0.DependencyControl.FileOps"
Updater =        require "l0.DependencyControl.Updater"
UnitTestSuite =  require "l0.DependencyControl.UnitTestSuite"
Record =         require "l0.DependencyControl.Record"

class DependencyControl extends Record
    @ConfigHandler = ConfigHandler
    @UpdateFeed = UpdateFeed
    @Logger = Logger
    @Updater = Updater
    @UnitTestSuite = UnitTestSuite
    @FileOps = FileOps
    @SemanticVersioning = SemanticVersioning


rec = DependencyControl{
    name: "DependencyControl",
    version: "0.7.0",
    description: "Provides script management and auto-updating for Aegisub macros and modules.",
    author: "line0",
    url: "http://github.com/TypesettingTools/DependencyControl",
    moduleName: "l0.DependencyControl",
    feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/DependencyControl.json",
    {
        -- BM.BadMutex and DM.DownloadManager are provided by DepCtrl's bundled FFI
        -- implementations (see the provideBundled calls above); the native libraries are
        -- preferred automatically when separately installed.
        {"requireffi.requireffi", version: "0.1.1", feed: "https://raw.githubusercontent.com/torque/ffi-experiments/master/DependencyControl.json", optional: true},
    }
}
DependencyControl.__class.version = rec
LOADED_MODULES[rec.moduleName], package.loaded[rec.moduleName] = DependencyControl, DependencyControl
DependencyControl.updater\scheduleUpdate rec
rec\requireModules!

return DependencyControl
