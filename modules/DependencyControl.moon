Logger =           require "l0.DependencyControl.Logger"
UpdateFeed =       require "l0.DependencyControl.UpdateFeed"
ConfigHandler =    require "l0.DependencyControl.ConfigHandler"
ConfigView =       require "l0.DependencyControl.ConfigHandler"
FileOps =          require "l0.DependencyControl.FileOps"
Updater =          require "l0.DependencyControl.Updater"
UnitTestSuite =    require "l0.DependencyControl.UnitTestSuite"
DependencyRecord = require "l0.DependencyControl.DependencyRecord"

class DependencyControl extends DependencyRecord
    @ConfigHandler = ConfigHandler
    @ConfigView = ConfigView
    @UpdateFeed = UpdateFeed
    @Logger = Logger
    @Updater = Updater
    @UnitTestSuite = UnitTestSuite
    @FileOps = FileOps


rec = DependencyControl{
    name: "DependencyControl",
    version: "0.6.3",
    description: "Provides script management and auto-updating for Aegisub macros and modules.",
    author: "line0",
    url: "http://github.com/TypesettingTools/DependencyControl",
    moduleName: "l0.DependencyControl",
    feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/DependencyControl.json",
    {
        {"DM.DownloadManager", version: "0.3.1", feed: "https://raw.githubusercontent.com/torque/ffi-experiments/master/DependencyControl.json"},
        {"BM.BadMutex", version: "0.1.3", feed: "https://raw.githubusercontent.com/torque/ffi-experiments/master/DependencyControl.json"},
        {"PT.PreciseTimer", version: "0.1.5", feed: "https://raw.githubusercontent.com/torque/ffi-experiments/master/DependencyControl.json"},
        {"requireffi.requireffi", version: "0.1.1", feed: "https://raw.githubusercontent.com/torque/ffi-experiments/master/DependencyControl.json"},
    }
}
DependencyControl.__class.version = rec
LOADED_MODULES[rec.moduleName], package.loaded[rec.moduleName] = DependencyControl, DependencyControl
DependencyControl.updater\scheduleUpdate rec
rec\requireModules!

return DependencyControl