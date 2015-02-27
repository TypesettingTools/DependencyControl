DependencyControl - Enterprise Aegisub Script Management
--------------------------------------------------------

DependencyControl provides versioning, automatic script update, dependency managment and script management services to Aegisub macros and modules.

__Features__:

 * Loads modules used by an automation script, pulls missing requirements from the internet and informs the user about missing and outdated modules that could not be updated automatically.
 * Checks scripts and modules for updates and automatically installs them
 * Offers convenient macro registration with user-customizable submenus
 * Provides configuration and logging services for your script
 * Supports optional modules and private module copies for cases where an older or custom version of a module is required
 * Resolves circular dependencies (limitations apply)

__Requirements__:

 * Aegisub 3.2.0+
 * [LuaJSON](https://github.com/harningt/luajson)
 * [DownloadManager](https://github.com/torque/ffi-experiments/releases) v0.1.2
 * [PreciseTimer](https://github.com/torque/ffi-experiments/releases) v0.1.2

----------------------------------

### Documentation ###

 1. [DependencyControl for Users](#dependency-control-for-users)
 2. [Usage for Automation Scripts](#usage-for-automation-scripts)
 3. [Reference](#reference)
 4. [The Anatomy of an Updater Feed](#FIXME) (tbd)
 5. [Ancillary Components: Logger and ConfigHandler](#FIXME) (tbd)

----------------------------------

### Dependency Control for Users ###

As an end-user you don't get to decide whether your scripts use DependencyControl or not, but you can control many aspects of its operation. The updater works out-of-the-box (for any script with an update feed) and is run automatically.

#### Install Instructions ####
 1. Download the latest DependencyControl release for your platform and unpack its contents to your Aegisub **user** automation directory.

 _It is essential DependencyControl and all scripts it's used reside in the **user** automation directory, **NOT** the the automation directory in the Aegisub application folder._

 On Windows, this will be `%AppData%\Aegisub\automation` folder.

2. In Aegisub, rescan your automation folder (or restart Aegisub).

#### Configuration ####
DependencyControl comes with sane default settings, so if you're happy with that, there's no need to read further. If you want to disable the updater, use custom menus or want to tweak another aspect of DepedencyControl, read on.

DependencyControl stores its configuration as a JSON file in the _config_ subdirectory of your Aegisub folder (`l0.DependencyControl.json`). Currently you'll have to edit this file manually, in the future there will be a management macro.

There are 2 kinds of configuration:

##### 1. Global Configuration #####
Changes made in the `config` section of the configuration file will affect all scripts and general DependencyControl behavior.

__Available Fields__:

* *bool* __updaterEnabled [true]:__ Turns the updater on/off
* *int* __updateInterval [3 Days]:__ The time in seconds between two update checks of a script
* *int* __traceLevel [3]:__ Sets the Trace level of DependencyControl update messages. Setting this higher than your _Trace level_ setting in Aegisub will prevent any of the messages from littering your log window.
* *bool* __dumpFeeds [true]:__ Debug option that will make DependencyControl dump updater feeds (original and expanded) to your Aegsiub folder.
* *arr* __extraFeeds:__ lets you provide additional update feeds that will be used when checking any script for updates
* *bool* __tryAllFeeds [false]:__ When set to true, feeds available to update a macro or module will be checked until an update is found. When set to false, a regular update process will stop once a feed confirms the script to be up-to-date.
* *str* __configDir ["?user/config"]:__ Sets the configuration directory that will be "offered" to automation scripts (they may or may not actually use it)
* *str* __writeLogs [true]:__ When enabled, DependencyControl log messages will be written to a file in the Aegisub log folder. This is a valuable resource for debugging, especially since the Aegisub log window is not available during script initalization.
* *int* __logMaxFiles [200]:__ DepedencyControl will purge old updater log files when any of the limits for log file count, log age and cumulative file size is exceeded.
* *int* __logMaxAge [1 Week]:__ Logs with a last modified date that exceeds this limit will be deleted. Takes a duration in seconds.
* *int* __logMaxSize [10 MB]:__ Cumlative file size limit for all log files in bytes.

##### 1. Per-script Configuration #####
Changes made in the `macros` and `modules` sections of the configuration file affect only the script or module in question.

__Available Fields__:

* *str* __customMenu:__ If you want to sort your automation macros into submenus, set this to the submenu name (use `/` to denote submenu levels).
* *str* __userFeed:__ When set the updater will use this feed exclusively to update the script in question (instead of other feeds)
* *int* __lastUpdateCheck [auto]:__ This field is used to store the (epoch) time of the last update check.
* *int* __logLevel [3]:__ sets the default trace level for log messages from this script (only applies to messages sent through a Logger instance provided by DepedencyControl to the script)
* *bool* __logToFile [false]:__ set the user preference wrt/ whether log messages of this script should be written to disk or not (same restrictions as above apply, may be overriden by the script)
* author, configFile, feed, moduleName, name, namespace, url, requiredModules, version, unmanaged: These fields hold aspects of the script's version record. Don't change them (they will be reset anyway)

-----------------------------------------
### Usage for Automation Scripts ###

#### For Macros: ####

Load DependencyControl at the start of your macro and create a version record. Script and version information is automatically pulled from the `script_*` variables (the additional `script_namespace` variable is **required**).

Here's an example of a macro that requires several modules - some of which have a version record as well as some that don't.

```Lua
script_name = "Move Along Path"
script_description = "Moves text along a path specified in a \\clip. Currently only works on fbf lines."
script_version = "0.1.2"
script_author = "line0"
script_namespace = "l0.MoveAlongPath"

local DependencyControl = require("l0.DependencyControl")
local version = DependencyControl{
    feed = "https://raw.githubusercontent.com/TypesettingCartel/line0-Aegisub-Scripts/master/DependencyControl.json",
    {
        "aegisub.util",
        {"a-mo.LineCollection", version="1.0.1", url="https://github.com/torque/Aegisub-Motion"},
        {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Log", url="https://github.com/torque/Aegisub-Motion"},
        {"l0.ASSFoundation", version="0.1.1", url="https://github.com/TypesettingCartel/ASSFoundation",
         feed = "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json"},
        {"l0.ASSFoundation.Common", version="0.1.1", url="https://github.com/TypesettingCartel/ASSFoundation",
         feed = "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json"},
        "YUtils"
    }
}
local util, LineCollection, Line, Log, ASS, Common, YUtils = version:requireModules()
```

Specifying a feed in your own version record provides DepedencyControl with a source to download updates to your script from. Specifying feeds for required modules managed by DependencyControl allows the Updater to discover those modules and fetch them when they're missing from the user's computer.


To __register your macros__ use the following code snippets instead of the usual *aegisub.register_macro()* calls:

For a __single macro__ that should be registered using the *script_name* as automation menu entry, use:
```Lua
version:registerMacro(myProcessingFunction)
```

For a script that registers __several macros__ using its own submenu use:
```Lua
version:registerMacros{
    {script_name, "Opens the Move Along Path GUI", showDialog, validClip},
    {"Undo", "Reverts lines to their original state", undo, hasUndoData}
}
```

Using this method for macro registration is a requirement for the __custom submenus__ feature to work with your script and lets DependencyControl hook your macro processing function to run an update check when your macro is run.

#### For Modules: ####

Creating a record for a module is very similar to how it does for macros, with the key difference being that name and version information is passed to DependencyControl correctly and a *moduleName* is required.

```Lua

local DependencyControl = require("l0.DependencyControl")
local version = DependencyControl{
    name = "ASSFoundation",
    version = "0.1.1",
    description = "General purpose ASS processing library",
    author = "line0",
    url = "http://github.com/TypesettingCartel/ASSFoundation",
    moduleName = "l0.ASSFoundation",
    feed = "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json",
    {
        "l0.ASSFoundation.ClassFactory",
        "aegisub.re", "aegisub.util", "aegisub.unicode",
        {"l0.ASSFoundation.Common", version="0.1.1", url="https://github.com/TypesettingCartel/ASSFoundation",
         feed = "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json"},
        {"a-mo.LineCollection", version="1.0.1", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Log", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        "ASSInspector.Inspector",
        {"YUtils", optional=true},
    }

local createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils = version:requireModules()

```

A reference to the version record must be added as the *.version* field of your returned module for version control to work.
A module should also register itself to enable circular dependency support. The *:register()* method returns your module, so the last lines of your module should look like this:

```Lua

MyModule.version = version

return version:register(MyModule)

```
---------------------------------------------
### Reference ###

__DependencyControl{*tbl* [requiredModules]={}, *str* :name=script_name, *str* :description=script_description, *str* :author=script_author, *str* :url, *str* :version, *str* :moduleName, *str* [:configFile], *string* [:namespace]} --> *obj* DependecyControlRecord__

The constructor for a DepedencyControl record. Uses the table-based signature.
__Arguments:__

 * _requiredModules_: the first and only unnamed argument. Contains all required modules, which may be either a single string for a non-version-controlled requirement or a table with the following fields:
    * __*str* [moduleName/[1]]:__ the module name
    * __*str* [version]:__ The mininum required version of the module. Must conform to Semantic Versioning standards. The module in question must contain a DependencyControl version record or otherwise compatible version number.
    * __*str* [url]__: The URL of the site where the module can be downloaded from (will be shown to the user in error methods).
    * __*str* [feed]__: The update feed used to fetch a copy of the required module when it is missing from the user's system.
    * __*bool* [optional=false]__: Marks the module as an optional requirement. If the module is missing on the user's system, no error will be thrown. However, version requirements *will* be checked if the module was found.
    * __*str* [name]__: Friendly module name (used for error messages).

* _name, description, author_: Required for modules, pulled from the *script_* globals for macros.
* _version_: Must conform to [Semantic Versioning](http://semver.org/) standards. Labels and build metadata are not supported at this time
* _moduleName_: module name (as used in require statements). Required for modules, must be nil for macros. Represents the namespace of a module.
* _url_: The web site/repository URL of your script
* _feed_: The update feed for your script.
* _configFile_: Configuration file base name used by the script. Defaults to the namespace. Used for configuration services and script management purposes.

#### Methods ####
__:checkVersion(*str/num* version) --> *bool* moduleUpToDate, *str* error__

Returns true if the version number of the record is greater than or equal to __version__. If the version can't be parsed it returns nil and and error message.

__:checkOptionalModules(*tbl* modules) --> *bool* result, *str* errorMessage__

Returns true if the optional __modules__ have been loaded, where __modules__ is a list of module names. If one or more of the modules are missing it returns false and an error message.

__:createDir(*str* path, *bool* [isFile]) --> *bool* result, *str* error__

Creates a directory. Returns _true_ on success or if the directory already exists or _false_ and an error message on failure. Use __isFile__ to indicate the __path__ points to a file, in which case its parent will be created.

__:expandFeed(*tbl* feed) --> *tbl* feed__

Expands template variables in downloaded update feeds **in-place** and returns the expanded feed. _Intended for internal use._

__:getConfigFileName() --> *str* fileName__

Returns a full path to the config file proposed for this script by DependencyControl. Uses the configFile argument passed to the constructor which defaults to the script namespace. The path is subject to user configuration and defaults to "?user\config". The file ending is always .json, because why would you use any other format?

The rationale for this function is to keep all macro and module configuration files neatly in one spot and make them discoverable for other scripts (through the DepedencyControl config file).

__:getConfigHandler([defaults], [section], [noLoad]) => *obj* ConfigHandler__

Returns a ConfigHandler (see [ConfigHandler Documentation](#FIXME)) attached to the config file configured for this script.

__:getLogger(*tbl* args) => *obj* Logger__

Returns a Logger (see [Logger Documentation](#FIXME)) preconfigured for this script. Trace level and config file preference default to user-configurable values. Log file name and prefix are based on namespace and script name.

__:getUpdaterErrorMsg(*int* [code], *str* targetName, ...) --> *str* errorMsg__

Used to turn an updater return __code__ into a human-readable error message. The __name__ of the updated component and other format string parameters are passed into the function.

VarArgs:

 1. __*bool* isModule__: True when component is a  module, false when it is an automation script/macro
 2. __*bool* isFetch__: True when we are fetching a missing module, false when updating
 3. __extError__: Extended error information as returned by the _:update()_ method

__:getUpdaterLock(*bool* [doWait], *int* [waitTimeout=(user config)]) --> *bool* result, *str* runningHost__

Locks the updater to the current macro/environment. Since all automation scripts load in parallel we have to make sure multiple automation scripts don't all update/fetch the same depedencies at once multiple times. The solution is to only let one updater operate at a time. The others will wait their turn and recheck if their required modules were fetched in the meantime.

If __doWait__ is true, the function will wait until the updater is unlocked or __waitTimeout__ has passed. It will then get the lock and return true. If __doWait__ is false, the function will return immediately (true on success, false if another updater has the lock). _Intendend for internal use_.


__:getVersionNumber(*str/num* versionString) --> *int/bool* version, *str* error__

Takes a SemVer string and converts it into a version number. If parsing the version string fails it returns false and an error message instead.

__:getVersionString(*int* [version=@version]) --> *str* versionString__

Returns a version (by default the script version) as a SemVer string.

__:getConfigFileName() --> *str* configFileName__

Generates and returns a full path to the registered config file name for the module.

__:loadConfig(*bool* [importRecord], *bool* [forceReloadGlobal]) --> *bool* shouldWriteConfig, *bool* firstInit__

Loads global DependencyControl and per-script configuration from the DepedencyControl configuration file. If __importRecord__ is true, the version record information of a DependencyControl record will be (temporarily) overwritten by the values contained in the configuration file.
Global configuration is only loaded on first run or if __forceReloadGlobal__ is true.

The first return result indicates there are changes to be written to the config file, the second result returns true if the config file was only just created. _Intended for internal use._

__:loadModule(*tbl* module, *bool* [usePrivate]) --> *tbl* moduleRef__

Loads and returns single module and only errors out in case of module errors. Intended for internal use. If __usePrivate__ is true, a private copy of the module is loaded instead.

__:moveFile(*str* src, *str* dest) --> *bool* success, *str* error__

Moves a file from __source__ to __destiantion__ (where both are full file names). Returns true on success or false and error message on failure.

__:register(*tbl* selfRef) --> *tbl* selfRef__

Replaces dummy reference written to the global LOADED_MODULES table at DependencyControl object creation time with a reference to this module.

The purpose of this construct is to allow circular references between modules. Limitations apply: the modules in question may not use each other during construction/setup of each module (for obvious reasons).

Call this method as replacement for returning your module.

__:registerMacro(*str* [name=@name], *str* [description=@description], *func* processing_function, *func* [validation_function], *func* is_active_function, *bool* [useSubmenu=false])__

Alternative Signature:

__:registerMacro(*func* processing_function, *func* [validation_function], *func* is_active_function, *bool* [useSubmenu=false])__

Registers a single macro using script name and description by default.
If __useSubmenu__ is set to true, the macro will be placed in a submenu using the script name.

If the script entry in the DependencyControl configuration file contains a __customMenu__ property, the macro will be placed in the specified menu. Do note that that this setting is for *user customization* and not to be changed without the user's consent.

For the other arguments, please refer to the [aegisub.register_macro](http://docs.aegisub.org/latest/Automation/Lua/Registration/#aegisub.register_macro) API documentation.

__:registerMacros(*tbl* macros, *bool* [useSubmenuDefault=true])__

Registers multiple macros, where __macros__ is a list of tables containing the arguments to a __:registerMacro()__ call for each automation menu entry.  a single macro using script name and description by default.
If __useSubmenuDefault__ is set to true, the macros will be placed in a submenu using the script name unless overriden by per-macro settings.

__:releaseUpdaterLock()__

Makes an updater host (macro) release its lock on the Updater if it has one. See _:getUpdaterLock_ for more information

__:requireModules([modules=@requiredModules], *bool* [forceUpdate], *bool* [updateMode], *tbl* [addFeeds={@feed})] --> ...__

Loads the modules required by this script and returns a reference for every requirement in the order they were supplied by the user. If an optional module is not found, nil is returned.

The updater will try to download copies of modules that are missing or outdated on the user's system. The __addFeeds__ parameter can be used to supply additional feeds to search. If missing/outdated requirements can't be fetched, the method will throw an error in normal mode or false and an error message in __update mode__.

Use __forceUpdate__ to override update intervals and perform update checks for all required modules, even if requirements are satisfied.

__:update(*bool* [force], *tbl* [addFeeds], *bool* [tryAllFeeds=auto]) --> *int* resultCode, *str* extError__

Runs the updater on this automation script or module. This includes recursicely updating all required modules. When __force__ is true, required modules will skip their update interval check.

By default, the updater will process all suitable feeds until one feed confirms the script to be up-to-date (unless configured otherwise by the user or if we are looking for updates to an outdated component). Set __tryAllFeeds__ to true to check all feeds until an update is found. You can also supply __additional candidate feeds__.

Returns a result code (0: up-to-date, 1: update performed, <=-1: error) and extendend error information which can be fed into _:getUpdaterErrorMsg()_ to get a descriptive error message.

__:writeConfig(*bool* [writeLocal=true], *bool* [writeGlobal=true], *bool* [concert]]__

Writes __global__ and per-module __local__ configuration. If __concert__ is true, concerted writing will be used to update the configuration of all DependencyControl hosted by any given macro/environment at once. See ConfigHandler documentation for more information. _Intended for internal use._
