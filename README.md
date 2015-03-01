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
 3. [Namespaces and Paths](#FIXME)
 4. [Reference](#reference)
 5. [The Anatomy of an Updater Feed](#FIXME) (tbd)
 6. [Ancillary Components: Logger and ConfigHandler](#FIXME) (tbd)

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

```lua
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

```lua

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

```lua

MyModule.version = version

return version:register(MyModule)

```
---------------------------------------------

### Namespaces and Paths ###

DependencyControl strictly enforces a **namespace-based file structure** for modules as well as automation macros in order to ensure there are no conflicts between scripts that happen to have the same name. 

Automation scripts must define their namespace in the version record whereas for modules the module name (as you would use in a `require` statement) defines the namespace. 

#### Rules for a valid namespace: ####

 1. contains _at least_ one dot
 2. must **not** start or end with a dot
 3. must **not** contain series of two or more dots
 4. the character set is restricted to: `A-Z`, `a-z`, `0-9`, `.`, `_`, `-` 
 5. *should* be descriptive (this is more of a guideline)

__Examples__:
 * l0.ASSFoundation
 * l0.ASSFoundation.Common (for a separately version-controlled 'submodule')
 * l0.ASSWipe
 * a-mo.LineCollection

#### File and Folder Structure ####

The namespace of your script translates into a subtree of the **user**automation directory you can use to store your files in. DepedencyControl will _not_ refuse to work with scripts that ignore this restriction, however it's designed in such a way that downloading to locations outside of your tree is **impossible** (which means your macro/module be able to use the auto-updater).

__Automation Scripts__ use the `?user/automation/autoload`, which has a flat file structure. You may **not** use subdirectories and your **file names must start with the namespace of your script**.

__Examples__:
 * l0.ASSWipe.lua
 * l0.ASSWipe.Addon.moon

__Modules__ use the `?user/automation/include` folder, which has a nested file structure. To determine your _subdirectory/file base name_, the dots in your namespace are replaced with `/` (`\` in Windows terms). 

Our example module ASSFoundation with namespace __l0.ASSFoundation__ writes (among others) the following files:
 * __?user/automation/include/l0/ASSFoundation__.lua
 * __?user/automation/include/l0/ASSFoundation__/ClassFactory.lua
 * __?user/automation/include/l0/ASSFoundation__/Draw/Bezier.lua

---------------------------------------------

### The Anatomy of an Updater Feed ###

If you want DepedencyControl auto-update your script on the user's system, you'll need to supply update information in an updater feed, which is a _JSON_ file with a simple basic layout:

*(`//` denotes a comment explaining the property above)*

`````javascript
{
  "dependencyControlFeedFormatVersion": "0.1.0", 
  // The version of the feed format. The current version is 0.1.0, don't touch this until further notice.
  "name": "line0's Aegisub Scripts",
  "description": "Main repository for all of line0's automation macros.",
  "maintainer": "line0",
  // The title and description of your repository as well as the name of the maintainer. May be used by GUI-driven management tools, package managers, etc...
  "baseUrl": "https://github.com/TypesettingCartel/line0-Aegisub-Scripts",
  // baseUrl is a template variable that can be referenced in other string fields of the template. It's useful when you have several scripts which all have their documentation hosted on the same site (so they start with the same URL). For more Information about templates, see the section below.
  "url": "@{baseUrl}",
  // The address where information about this repository can be found. In this case it references the baseUrl template variable and expands to "https://github.com/TypesettingCartel/line0-Aegisub-Scripts".
  "fileBaseUrl": "https://raw.githubusercontent.com/TypesettingCartel/line0-Aegisub-Scripts/@{channel}/@{namespace}",
  // A special rolling template variable. See the templates section below for more information.
  
  "macros": {
    // the section where all automation scripts tracked by this feed go. The key for each value is the namespace of the respective script. Below this level, this namespace is available as the @{namespace} and @{namespacePath} template variable
    "l0.ASSWipe": { ... },
    "l0.Nudge": { ... }
   },
  "modules": {
    // Your modules go here. If your feed doesn't track any modules, you may omit this section (same goes for the macros object) 
    "l0.ASSFoundation": { ... }
  }  

`````

An automation script or module object looks like this:

````javascript
"l0.ASSWipe": {
      "url": "@{baseUrl}#@{namespace}",
      "author": "line0",
      "name": "ASSWipe",
      "description": "Performs script cleanup, removes unnecessary tags and lines.",
      // These script information fields should be identical to the values defined in your DepedencyControl version record.
      "channels": {
      // a list of update channels available for your script (think release, beta and alpha). The key is a channel name of your choice, but should make sense to the user picking one.
        "master": {
        // This example only defines one channel, which is set up to track the the HEAD of a GitHub repository.
          "version": "0.1.3",
          // The current script version served in this channel. Must be identical to the one in the version record.
          "released": "2015-02-26",
          // Release date of the current script version (UTC/ISO 8601 format)
          "default": true,
          // Marks this channel as the default channel in case the user doesn't have picked a specific one. Must be set to true for **exactly** one channel in the list. 
          "platforms": ["Windows-x86", "Windows-x64", "OSX-x64"]
          // Optional: A list of platforms you serve builds for. You should omit this property for regular scripts and modules that use only Lua/Moonscript and no binaries. If this property is absent, the platform check will be skipped. The platform names are derived from the output of ffi.os()-ffi.arch() in luajit. 
          "files": [
          // A list of files installed by your script.
            {
              "name": ".lua",
              // the file name relative to the path assigned to the script by your namespace choice (see 3. Namespaces and Paths for more information). Available as the @{fileName} template variable for use in the url field below.
              "url": "@{fileBaseUrl}@{fileName}",
              // URL from which the **raw** file can be downloaded from (no archives, no javascript redirects, etc...). In this case the templates expand to "https://raw.githubusercontent.com/TypesettingCartel/line0-Aegisub-Scripts/master/l0.ASSWipe.lua"
              "sha1": "A7BD1C7F0E776BA3010B1448F22DE6528F73B077"
              // The SHA-1 hash of the file being currently served under that url. Will be checked against the downloaded file, so it must always be present and valid or the update process will fail on the user's end.
            },
            {
              "name": ".Helper.dll",
              "url": "@{fileBaseUrl}@{fileName}",
              "sha1": "0B4E0511116355D4A11C2EC75DF7EEAD0E14DE9F"
              "platform": "Windows-x86"
              // Optional. When this property is present, the file will only be downloaded to the users computer if his platform matches to this value.
            }
          ],
          "requiredModules": [
          // an exhaustive list of modules required by this script. Must be identical to the required module entries in your DepdencyControl record, but you may not use short style here. (see 2. Usage for Automation Scripts for more information)
            {
              "moduleName": "a-mo.LineCollection",
              "name": "Aegisub-Motion (LineCollection)",
              "url": "https://github.com/torque/Aegisub-Motion",
              "version": "1.0.1"
            }, 
            {
              "moduleName": "l0.ASSFoundation",
              "name": "ASSFoundation",
              "url": "https://github.com/TypesettingCartel/ASSFoundation",
              "version": "0.1.1",
              "feed": "https://raw.githubusercontent.com/TypesettingCartel/ASSFoundation/master/DependencyControl.json"
            },
            {
              "moduleName": "aegisub.util"
            },
          ]
        }
      },
      "changelog": {
      // a change log that allows users to see what's new in this and previous versions. The changelog is shared between all channels. Only the entries with a version number equal or below the version the user just updated to will be displayed.
        "0.1.0": [
          "Sync with ASSFoundation changes",
          // one entry for each line
          "Start versioning with DependencyControl"
        ],
        "0.1.3": [
          "Enabled auto-update using DependencyControl",
          "Changed config file to \\config\\l0.ASSWipe.json (rename ASSWipe.json to restore your existing configuration)",
          "DependencyControl compatibility fixes"
        ]
      }
    }
````

#### Template Variables ####

To make maintaining an update feed easier, you can use several template variables that will be expanded when used inside string values (but **not** Keys).

__Regular Variables:__ These reference a specific key or value and are available at the same depth and further down the tree from the point on where they were created. 

Variables extracted at the **same depth** are expanded in a specific order. As a consequence only references to variables of lower order are expanded in values that are assigned to a variable themselves.

_Depth 1:_ Feed Information
 1. __feedName__: The name of the feed
 2. __baseUrl__: The baseUrl field 

_Depth 3:_ Script Information
 1. __namespace__: the script namespace
 2. __namepspacePath__: the script namespace with all `.` replaced by `/`
 3. scriptName: the script name

_Depth 5:_ Version Information
 1. __channel__: the channel name of this version record
 2. __version__: the version number as a SemVer string

_Depth 7:_ File Information
 1. __platform__: the platform defined for this file, otherwise an empty string
 2. __fileName__: the file name

__"Rolling" Variables:__ These variables can be defined at any depth in the JSON tree and are continuously expanded using the variables available. You can reference a rolling variable in itself, which will substitute the template for the contents the variable had at the parent-level. 

Right now there's only one such variable: __fileBaseUrl__, which you can use to construct the URL to a file using the template variables available. 

For an example to serve updates from the HEAD of a GitHub repository, see [here](https://github.com/TypesettingCartel/line0-Aegisub-Scripts/blob/master/DependencyControl.json). An example that shows a feed making use of tagged releases is [also available](https://github.com/TypesettingCartel/ASSFoundation/blob/master/DependencyControl.json)

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
