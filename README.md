DependencyControl - Enterprise Aegisub Script Management
========================================================

 1. [DependencyControl](#dependencycontrol)

----------------------------------

## DependencyControl ##

DependencyControl is a Lua module for versioning and dependency managment of Aegisub macros and modules. It also provides a global script registry allowing for certain aspects of script management and customization.

__Features__:

 * Loads required modules, informs the user the user about missing and outdated requirements
 * Provides convenient macro registration with user-customizable submenus
 * Improves script loading time by reusing module references
 * Provides facilities to work with optional modules
 * Supports circular dependencies (limitations apply)
 * Supports loading of private module copies for cases where an older or custom version of a module is required
 * _Planned: Automatic script update from the web_

__Requirements__:
 * Aegisub 3.2.0+
 * [LuaJSON](https://github.com/harningt/luajson)

### Usage ###

#### For Macros: ####

Load DependencyControl at the start of your macro and create a version record. Script and version information is automatically pulled from the *script_* variables. Here's an example of a macro that requires several modules - some of which have a version record as well as some that don't.

```Lua
script_name="Move Along Path"
script_description="Moves text along a path specified in a \\clip. Currently only works on fbf lines."
script_version="0.1.0"
script_author="line0"

local DependencyControl = require("l0.DependencyControl")
local version = DependencyControl{
    namespace = "l0.MoveAlongPath",
    {
        "aegisub.util",
        {"a-mo.LineCollection", version="1.0.1", url="https://github.com/torque/Aegisub-Motion"},
        {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Log", url="https://github.com/torque/Aegisub-Motion"},
        {"l0.ASSFoundation", version="0.1.0", url="https://github.com/TypesettingCartel/ASSFoundation"},
        {"l0.Common", version="0.1.0", url="https://github.com/TypesettingCartel/ASSFoundation"},
        {"YUtils"}
    }
}
local util, LineCollection, Line, Log, ASS, Common, YUtils = version:requireModules()
```

To register your macros use the following code snippets instead of the usual *aegisub.register_macro()* calls:

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

#### For Modules: ####

Creating a record for a module is very similar to how it does for macros, with the key difference being that name and version information is passed to DependencyControl correctly and a *moduleName* is required.

```Lua

local DependencyControl = require("l0.DependencyControl")
local version = DependencyControl{
    name = "ASSFoundation",
    version = "0.1.0",
    description = "General purpose ASS processing library",
    author = "line0",
    url = "http://github.com/TypesettingCartel/ASSFoundation",
    moduleName = "l0.ASSFoundation",
    {
        "l0.ASSFoundation.ClassFactory",
        "aegisub.re", "aegisub.util", "aegisub.unicode", "l0.Common",
        {"a-mo.LineCollection", version="1.0.1", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        {"a-mo.Log", url="https://github.com/TypesettingCartel/Aegisub-Motion"},
        "ASSInspector.Inspector",
        {"YUtils", optional=true},
    }
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
    * __*str* (1):__ the module name
    * __*str* [:version]:__ The mininum required version of the module. Must conform to Semantic Versioning standards. The module in question must contain a DependencyControl version record or otherwise compatible version number.
    * __*str* [url]__: The URL of the site where the module can be downloaded from (will be shown to the user in error methods).
    * __*bool* [optional=false]__: Marks the module as an optional requirement. If the module is missing on the user's system, no error will be thrown. However, version requirements *will* be checked if the module was found.
    * __*str* [name]__: Friendly module name (used for error messages).

* _name, description, author_: Required for modules, pulled from the *script_* globals for macros.
* _version_: Must conform to [Semantic Versioning](http://semver.org/) standards. Labels and build metadata are not supported at this time
* _moduleName_: module name (as used in require statements). Required for modules, must be nil for macros
* _url_: The web site/repository URL of the module
* _namespace_: The namespace used for script extradata (to be used for script management purposes). Defaults to the module name for modules.
* _configFile_: Configuration file name used by the script. Defaults to [module/macro name].json. To be used for script management purposes.

#### Methods ####
__:check(*str/num* version) --> *bool* moduleUpToDate__

Returns true if the version number of the record is greater than or equal to __version__.

__:checkOptionalModules(*tbl* modules, *bool* noAssert) --> *str* errorMessage__

Checks if the optional __modules__ have been loaded, where __modules__ is a list of module names. Throws an error if one or more of the modules are missing unless __noAssert__ is true, in which case the method returns the error message as a string.

__:get() --> *str* versionString__

Returns the module version as a SemVer string.

__:getConfigFileName() --> *str* configFileName__

Generates and returns a full path to the registered config file name for the module.

__:load(*tbl* module, *bool* usePrivate) --> *tbl* moduleRef__

Loads and returns single module and only errors out in case of module errors. Mostly intended for internal use. If __usePrivate__ is true, a private copy of the module is loaded instead.

__:parse(*str/num* versionString) --> *int* version__

Takes a SemVer string and converts it into a version number. Mostly intended for internal use.

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

__:requireModules([modules=@requiredModules]) --> ...__

Loads the modules required by this script and returns a reference for every requirement in the order they were supplied by the user. If an optional module is not found, nil is returned.
