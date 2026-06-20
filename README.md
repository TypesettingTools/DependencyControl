# DependencyControl - Enterprise Aegisub Script Management

DependencyControl provides versioning, automatic script update, dependency management and script management services to Aegisub macros and modules.

**Features**:

- A lightweight package manager lets users conveniently install scripts right from inside Aegisub
- Loads modules used by an automation script, pulls missing requirements from the internet and informs the user about missing and outdated modules that could not be updated automatically
- Checks scripts and modules for updates and automatically installs them
- Offers convenient macro registration with user-customizable submenus
- Provides configuration, logging services, file operations and a unit test framework for your scripts
- Supports optional modules and private module copies for cases where an older or custom version of a module is required
- Resolves circular dependencies (limitations apply)

**Requirements**:

- Aegisub [v3.4.0+](https://github.com/TypesettingTools/Aegisub/releases) or releases of [arch1t3cht's Aegisub fork](https://github.com/arch1t3cht/Aegisub/releases) based on v3.4.0+. Older versions of Aegisub may work, but you're on your own if you run into any issues.

DependencyControl is self-contained: it bundles a JSON library ([dkjson](https://dkolf.de/dkjson-lua/)), though if you have another `json` module installed, it is used instead.
It also now ships with pure-FFI
implementations of functionality previously provided by
[ffi-experiments](https://github.com/torque/ffi-experiments)
modules (_DownloadManager_, _BadMutex_, _PreciseTimer_).

---

## Table of Contents

1.  [DependencyControl for Users](#dependency-control-for-users)
2.  [Usage for Automation Scripts](#usage-for-automation-scripts)
3.  [Namespaces and Paths](#namespaces-and-paths)
4.  [The Anatomy of an Updater Feed](#the-anatomy-of-an-updater-feed)
5.  [Reference](#reference)
6.  [DependencyControl](#FIXME)
7.  [Updater](#FIXME)
8.  [Logger](#FIXME)
9.  [ConfigHandler](#FIXME)
10. [FileOps](#FIXME)
11. [CLI](#cli)

---

## Dependency Control for Users

As an end-user you don't get to decide whether your scripts use DependencyControl or not, but you can control many aspects of its operation. The updater works out-of-the-box (for any script with an update feed) and is run automatically.

### Installation

1.  Download the latest DependencyControl release unpack its contents to your Aegisub **user** automation directory:
    - On Windows: `%AppData%\Aegisub\automation`
    - On Linux: `~/.aegisub/automation`
    - On OSX: `~/Library/Application Support/Aegisub/automation`

Do **NOT** unpack the file into the automation directory within the Aegisub installation folder, as this will break the updater.

2. Restart Aegisub or re-scan your autoload directory from within the Aegisub _Automation Manger_.

### Configuration

DependencyControl comes with sane default settings, so if you're happy with that, there's no need to read further. If you want to disable the updater, use custom menus or want to tweak another aspect of DependencyControl, read on.

DependencyControl stores its configuration as a JSON file in the `config` folder of your Aegisub user directory:

- On Windows: `%AppData%\Aegisub\config\l0.DependencyControl.json`
- On Linux: `~/.aegisub/config/l0.DependencyControl.json`
- On OSX: `~/Library/Application Support/Aegisub/config/l0.DependencyControl.json`

The **DependencyControl Toolbox** macro provides a GUI for common management tasks; advanced options still require manual JSON editing.

There are 2 kinds of configuration:

#### 1. Global Configuration

Changes made in the `config` section of the configuration file will affect all scripts and general DependencyControl behavior.

**Available Fields**:

- _bool_ **updaterEnabled [true]:** Turns the updater on/off
- _int_ **updateInterval [3 Days]:** The time in seconds between two update checks of a script
- _int_ **traceLevel [3]:** Sets the Trace level of DependencyControl update messages. Setting this higher than your _Trace level_ setting in Aegisub will prevent any of the messages from littering your log window.
- _bool_ **dumpFeeds [true]:** Debug option that will make DependencyControl dump updater feeds (original and expanded) to your Aegisub folder.
- _arr_ **extraFeeds:** lets you provide additional update feeds that will be used when checking any script for updates. Feeds you list here are treated as trusted.
- _arr_ **trustedFeeds:** additional feed URLs you trust as package sources, on top of the feeds DependencyControl trusts by default (those advertised in its own feed). Unlike `extraFeeds`, these aren't crawled for updates on their own — they only mark a feed as trusted so packages can be installed from it without a warning.
- _arr_ **blockedFeeds:** feed URLs that must never be used as a package source. A blocked feed is rejected regardless of any other setting (including `userFeed`). Applied on top of DependencyControl's own block list. Each entry is matched case-insensitively as a URL prefix, so a host root like `https://example.com/` blocks every feed under it.
- _str_ **configDir ["?user/config"]:** Sets the configuration directory that will be "offered" to automation scripts (they may or may not actually use it)
- _str_ **writeLogs [true]:** When enabled, DependencyControl log messages will be written to a file in the Aegisub log folder. This is a valuable resource for debugging, especially since the Aegisub log window is not available during script initialization.
- _int_ **logMaxFiles [200]:** DependencyControl will purge old updater log files when any of the limits for log file count, log age and cumulative file size is exceeded.
- _int_ **logMaxAge [1 Week]:** Logs with a last modified date that exceeds this limit will be deleted. Takes a duration in seconds.
- _int_ **logMaxSize [10 MB]:** Cumulative file size limit for all log files in bytes.

#### 2. Per-script Configuration

Changes made in the `macros` and `modules` sections of the configuration file affect only the script or module in question.

**Available Fields**:

- _str_ **customMenu:** If you want to sort your automation macros into submenus, set this to the submenu name (use `/` to denote submenu levels).
- _str_ **userFeed:** When set the updater will use this feed exclusively to update the script in question (instead of other feeds)
- _int_ **lastUpdateCheck [auto]:** This field is used to store the (epoch) time of the last update check.
- _int_ **logLevel [3]:** sets the default trace level for log messages from this script (only applies to messages sent through a Logger instance provided by DependencyControl to the script)
- _bool_ **logToFile [false]:** set the user preference wrt/ whether log messages of this script should be written to disk or not (same restrictions as above apply, may be overridden by the script)
- `author`, `configFile`, `feed`, `moduleName`, `name`, `namespace`, `url`, `requiredModules`, `version`, `unmanaged`, `provides`: These fields hold aspects of the script's version record. Don't change them (they will be reset anyway)

### How DependencyControl Selects Package Sources

When a script or module needs to be installed or updated, more than one feed may be able to supply it. DependencyControl chooses the source by **trust first, version second**, so an unexpected or compromised feed can't win just by advertising a higher version number. Candidates are ranked best-first:

1. **The package's own / declared feed**: the feed an installed package advertises, or the feed the depending script declares for the dependency — as long as it still offers the package and remains trusted.
2. **Other trusted feeds**: offering the package directly by name.
3. **Trusted feeds offering a _provider_**: a different module that declares it `provides` the required name (see [Providing module aliases](#providing-module-aliases)).
4. **Untrusted feeds** (by name, then via a provider): interactive installs ask for confirmation before using them. Silent installs/updates are refused until the feed is added to the trusted list.

Within a tier the highest satisfying version wins. Feeds are fetched lazily in this order, so closer, more-trusted sources are tried before DependencyControl reaches further out.

#### Customizing Feed Sources & Trust

The feeds DependencyControl advertises in its own feed are trusted out of the box, as is anything you add yourself. Tune this in your [global configuration](#1-global-configuration):

- **`trustedFeeds`**: additional feed URLs you trust as package sources.
- **`extraFeeds`**: extra feeds to check for updates (these count as trusted, too).
- **`blockedFeeds`**: feeds that must never be used, overriding everything else (applied in addition to DependencyControl's own block list). Entries match case-insensitively by URL prefix, so a host root blocks every feed under it.
- **`userFeed`** (per script): pin a single feed to be used exclusively for that script.

(A future DependencyControl Toolbox UI will let you confirm and trust feeds interactively instead of editing the config by hand.)

## Usage for Automation Scripts

### For Macros

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
  feed = "https://raw.githubusercontent.com/TypesettingTools/line0-Aegisub-Scripts/master/DependencyControl.json",
  {
    "aegisub.util",
    {"a-mo.LineCollection", version="1.0.1", url="https://github.com/torque/Aegisub-Motion"},
    {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingTools/Aegisub-Motion"},
    {"a-mo.Log", url="https://github.com/torque/Aegisub-Motion"},
    {"l0.ASSFoundation", version="0.1.1", url="https://github.com/TypesettingTools/ASSFoundation",
      feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"},
    {"l0.ASSFoundation.Common", version="0.1.1", url="https://github.com/TypesettingTools/ASSFoundation",
      feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"},
    "YUtils"
  }
}
local util, LineCollection, Line, Log, ASS, Common, YUtils = version:requireModules()
```

Specifying a feed in your own version record provides DependencyControl with a source to download updates to your script from.
Specifying feeds for required modules managed by DependencyControl allows the Updater to discover those modules and fetch them when they're missing from the user's computer. However, you can omit the feed URLs for required modules when your own feed already has references to them.

To **register your macros** use the following code snippets instead of the usual _aegisub.register_macro()_ calls:

For a **single macro** that should be registered using the _script_name_ as automation menu entry, use:

```Lua
version:registerMacro(myProcessingFunction)
```

For a script that registers **several macros** using its own submenu use:

```Lua
version:registerMacros{
  {script_name, "Opens the Move Along Path GUI", showDialog, validClip},
  {"Undo", "Reverts lines to their original state", undo, hasUndoData}
}
```

Using this method for macro registration is a requirement for the **custom submenus** feature to work with your script and lets DependencyControl hook your macro processing function to run an update check when your macro is run.

### For Modules

Creating a record for a module is very similar to how it does for macros, with the key difference being that name and version information is passed to DependencyControl correctly and a _moduleName_ is required.

```lua
local DependencyControl = require("l0.DependencyControl")
local version = DependencyControl{
  name = "ASSFoundation",
  version = "0.1.1",
  description = "General purpose ASS processing library",
  author = "line0",
  url = "http://github.com/TypesettingTools/ASSFoundation",
  moduleName = "l0.ASSFoundation",
  feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json",
  {
    "l0.ASSFoundation.ClassFactory",
    "aegisub.re", "aegisub.util", "aegisub.unicode",
    {"l0.ASSFoundation.Common", version="0.1.1", url="https://github.com/TypesettingTools/ASSFoundation",
      feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"},
    {"a-mo.LineCollection", version="1.0.1", url="https://github.com/TypesettingTools/Aegisub-Motion"},
    {"a-mo.Line", version="1.0.0", url="https://github.com/TypesettingTools/Aegisub-Motion"},
    {"a-mo.Log", url="https://github.com/TypesettingTools/Aegisub-Motion"},
    "ASSInspector.Inspector",
    {"YUtils", optional=true},
    }

local createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils = version:requireModules()
```

A reference to the version record must be added as the _.version_ field of your returned module for version control to work.
A module should also register itself to enable circular dependency support. The _:register()_ method returns your module, so the last lines of your module should look like this:

```lua
MyModule.version = version
return version:register(MyModule)
```

#### Providing module aliases

A module may declare additional names it can satisfy via a `provides` field. Once DependencyControl is loaded, any `require` for one of those names — including a bare, non-namespaced name — resolves to your module, _unless_ a real module of that name is already available (yours is only a fallback). This lets a library stand in for a commonly-required dependency without every consuming script having to know your module's namespace.

```lua
local version = DependencyControl{
  name = "dkjson",
  version = "2.10.0",
  moduleName = "l0.dkjson",
  -- this module can satisfy `require("json")`:
  provides = {"json"},
}
```

Notes:

- Each entry is a name string (or a table `{name = "json"}`, which may offer further customization options in the future).
- Provided names may be bare/non-namespaced even though your own `moduleName` must be a valid
  (dotted) namespace.
- Resolution only applies after DependencyControl itself has been loaded, and always defers to a
  genuinely installed module of that name — so users can still bring their own.

##### Satisfying a dependency with a provider

`provides` also works across the dependency graph at install time. When a script's `requiredModules` names a module that no feed offers directly, DependencyControl can install a module  that lists that name in its `provides` instead — much like Debian's `Provides:` or Arch's `provides`. For example, a script that requires `json` can be satisfied by installing `l0.dkjson`, which provides it. A candidate must actually be installable (its `platforms` must include yours and its version must meet the requirement), a directly-named module is always preferred over a provider, and the usual [package-source precedence](#how-dependencycontrol-selects-package-sources) decides which feed it comes from. Once a provider is installed for a requirement, DependencyControl keeps using and updating that same module rather than switching to a different provider, as long as it can still satisfy the requirement.

A provider can pin _which_ versions of an aliased module it stands in for by giving the table entry an npm-style version range via `provides = {{name = "json", version = "~1.2"}}`. This lets one provider cover a span of releases without being re-published for every patch bump of the aliased module. If not specified, the provider is assumed to satisfy any version requirement for that name.

For module authors: the `provides` you declare in your version record is mirrored into your feed automatically when you run the `update-feed` CLI, so a published feed advertises it without manual upkeep (you may also add it to a feed by hand).

#### Advanced: moving a package to a new feed URL

A package can change the feed it updates from by shipping a release whose record points `feed` at the new URL; DependencyControl picks that up the next time it updates the package. Because source selection is trust-aware (see [How DependencyControl Selects Package Sources](#how-dependencycontrol-selects-package-sources)),
plan migrations with that in mind:

- If the new URL is **already trusted** (listed in DependencyControl's feed, or added by users), the move is seamless.
- If the new URL is **not yet trusted**, automatic updates to it are held back. To avoid breaking them, keep serving from your **old, already-trusted feed in parallel** during the transition and/or get the new URL added to DependencyControl's trusted list. Individual users can also add it to their own `trustedFeeds`.

---

## Namespaces and Paths

DependencyControl strictly enforces a **namespace-based file structure** for modules as well as automation macros in order to ensure there are no conflicts between scripts that happen to have the same name.

Automation scripts must define their namespace in the version record whereas for modules the module name (as you would use in a `require` statement) defines the namespace.

Rules for a valid namespace:

1.  contains _at least_ one dot
2.  must **not** start or end with a dot
3.  must **not** contain series of two or more dots
4.  the character set is restricted to: `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`
5.  _should_ be descriptive (this is more of a guideline)

**Examples**:

- `l0.ASSFoundation`
- `l0.ASSFoundation.Common` (for a separately version-controlled 'submodule')
- `l0.ASSWipe`
- `a-mo.LineCollection`

### File and Folder Structure

The namespace of your script translates into a subtree of the **user** automation directory you can use to store your files in:

- On Windows: `%AppData%\Aegisub\automation`
- On Linux: `~/.aegisub/automation`
- On OSX: `~/Library/Application Support/Aegisub/automation`

DependencyControl will _not outright_ refuse to work with scripts that ignore this restriction, however it's designed in such a way that downloading to locations outside of your tree is **impossible** (which means your package won't be able to use the auto-updater).

**Automation Scripts** use the `?user/automation/autoload` directory, which has a flat file structure. You may **not** use subdirectories and your **file names must start with the namespace of your script**.

Examples:

- `l0.ASSWipe.lua`
- `l0.ASSWipe.Addon.moon`

**Modules** use the `?user/automation/include` folder, which has a nested file structure. To determine the base name for your main entry point file and sub-directory, the dots in your namespace are replaced with the path separator (`\` on Windows, `/` on other platforms).

**Tests** use the `?user/automation/tests/DepUnit/modules` or `?user/automation/tests/DepUnit/macros` folder depending on whether a macro or automation is being tested and mirror the directory structure of the respective `include` and `autoload` folders.

Our example module _ASSFoundation_ with namespace `l0.ASSFoundation` writes (among others) the following files:

- `?user/automation/include/l0/ASSFoundation.lua`
- `?user/automation/include/l0/ASSFoundation/ClassFactory.lua`
- `?user/automation/include/l0/ASSFoundation/Draw/Bezier.lua`
- `?user/automation/tests/DepUnit/modules/l0/ASSFoundation.lua`

---

## The Updater Feed

If you want DependencyControl auto-update your package(s) on the user's system, you'll need to supply update information in an updater feed, which is a _JSON_ file with the following layout:

_(`//` denotes a comment explaining the property above)_

```json
{
  "dependencyControlFeedFormatVersion": "0.3.0",
  // The version of the feed format. The current version is 0.3.0, don't touch this until further notice.
  "name": "line0's Aegisub Scripts",
  "description": "Main repository for all of line0's automation macros.",
  "maintainer": "line0",
  // The title and description of your repository as well as the name of the maintainer. May be used by GUI-driven management tools, package managers, etc...
  "knownFeeds": {
    "a-mo": "https://raw.githubusercontent.com/TypesettingTools/Aegisub-Motion/DepCtrl/DependencyControl.json",
    "ASSFoundation": "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"
  },
  // A hash table of known feed URLs. Can be referenced with @{feed:name} and will be used to discover other repositories the user can install automation scripts and modules from. At the very least this should contain the repo URLs for the required modules in your repo, but may be used to advertise other unrelated repos you trust.
  "baseUrl": "https://github.com/TypesettingTools/line0-Aegisub-Scripts",
  // baseUrl is a template variable that can be referenced in other string fields of the template. It's useful when you have several scripts which all have their documentation hosted on the same site (so they start with the same URL). For more Information about templates, see the section below.
  "url": "@{baseUrl}",
  // The address where information about this repository can be found. In this case it references the baseUrl template variable and expands to "https://github.com/TypesettingTools/line0-Aegisub-Scripts".
  "fileBaseUrl": "https://raw.githubusercontent.com/TypesettingTools/line0-Aegisub-Scripts/@{channel}/@{namespace}",
  // A special rolling template variable. See the templates section below for more information.

  "macros": {
    // the section where all automation scripts tracked by this feed go. The key for each value is the namespace of the respective script. Below this level, this namespace is available as the @{namespace} and @{namespacePath} template variable
    "l0.ASSWipe": { /* ... */ },
    "l0.Nudge": { /* ... */ }
   },
  "modules": {
    // Your modules go here. If your feed doesn't track any modules, you may omit this section (same goes for the macros object)
    "l0.ASSFoundation": { /* ... */ }
  }
```

An automation script or module object looks like this:

```json
"l0.ASSWipe": {
  "url": "@{baseUrl}#@{namespace}",
  "author": "line0",
  "name": "ASSWipe",
  "description": "Performs script cleanup, removes unnecessary tags and lines.",
  // These script information fields should be identical to the values defined in your
  // DependencyControl version record.
  "channels": {
  // a list of update channels available for your script (think release, beta and alpha).
  // The key is a channel name of your choice, but should make sense to the user picking one.
    "master": {
    // This example only defines one channel, which is set up to track
    // the HEAD of a GitHub repository.
      "version": "0.1.3",
      // The current script version served in this channel.
      // Must be identical to the one in the version record.
      "released": "2015-02-26",
      // Release date of the current script version (UTC/ISO 8601 format)
      "default": true,
      // Marks this channel as the default channel in case the user doesn't have picked a specific one.
      // Must be set to true for **exactly** one channel in the list.
      "platforms": ["Windows-x86", "Windows-x64", "OSX-x64"]
      // Optional: A list of platforms you serve builds for. You should omit this property for regular scripts
      // and modules that use only Lua/Moonscript and no binaries. If this property is absent,
      // the platform check will be skipped. The platform names are derived from the output of
      // ffi.os()-ffi.arch() in luajit.
      "files": [
      // A list of files installed by your script.
        {
          "name": ".lua",
          // the file name relative to the path assigned to the script by your namespace choice
          // (see 3. Namespaces and Paths for more information). Available as the @{fileName} template variable
          // for use in the url field below.
          "url": "@{fileBaseUrl}@{fileName}",
          // URL from which the **raw** file can be downloaded from (no archives, no javascript
          // redirects, etc...). In this case the templates expand to
          // "https://raw.githubusercontent.com/TypesettingTools/line0-Aegisub-Scripts/master/l0.ASSWipe.lua"
          "sha1": "A7BD1C7F0E776BA3010B1448F22DE6528F73B077"
          // The SHA-1 hash of the file being currently served under that url. Will be checked
          // against the downloaded file, so it must always be present and valid or the update process
          // will fail on the user's end.
        },
        {
          "name": ".lua",
          "type": "test",
          // Optional, defaults to "script". Specify "test" to denote a unit test.
          // Currently only "script" and "test" are available, unknown script types will be skipped.
          "url": "@{fileBaseUrl}.Tests.lua",
          "sha1": "27745AB9CF04A840CF3454050CA9D38FA345CEBB"
        },
        {
          "name": ".Helper.dll",
          "url": "@{fileBaseUrl}@{fileName}",
          "sha1": "0B4E0511116355D4A11C2EC75DF7EEAD0E14DE9F",
          "platform": "Windows-x86"
          // Optional. When this property is present, the file will only be downloaded to the users
          // computer if his platform matches to this value.
        }
      ],
      "requiredModules": [
      // an exhaustive list of modules required by this script. Must be identical to the required
      // module entries in your DependencyControl record, but you may not use short style here.
      // (see 2. Usage for Automation Scripts for more information)
        {
          "moduleName": "a-mo.LineCollection",
          "name": "Aegisub-Motion (LineCollection)",
          "url": "https://github.com/torque/Aegisub-Motion",
          "version": "1.0.1",
          "feed": "@{feed:a-mo}"
        },
        {
          "moduleName": "l0.ASSFoundation",
          "name": "ASSFoundation",
          "url": "https://github.com/TypesettingTools/ASSFoundation",
          "version": "0.1.1",
          "feed": "@{feed:ASSFoundation}"
        },
        {
          "moduleName": "aegisub.util"
        },
      ]
    }
  },
  "changelog": {
  // a change log that allows users to see what's new in this and previous versions. The changelog
  // is shared between all channels. Only the entries with a version number equal or below
  // the version the user just updated to will be displayed.
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
```

Full _JSON Schema_ documents (which you can use to validate your feeds) are provided for the following feed versions:

- [v0.3.0](./schemas/feed/v0.3.0.json) (also validates legacy _v0.2.0_ feeds)

### Template Variables

To make maintaining an update feed easier, you can use several template variables that will be expanded when used inside string values (but **not** keys).

**Regular Variables**: These reference a specific key or value and are available at the same depth and further down the tree from the point on where they were created.

Variables extracted at the **same depth** are expanded in a specific order. As a consequence only references to variables of lower order are expanded in values that are assigned to a variable themselves.

_Depth 1:_ Feed Information

1.  `@{feedName}`: The name of the feed
2.  `@{baseUrl}`: The baseUrl field
3.  `@{feed:<feedName>}`: A reference to a feed URL in the knownFeeds table

_Depth 3:_ Script Information

1.  `@{namespace}`: the script namespace
2.  `@{namespacePath}`: the script namespace with all `.` replaced by `/`
3.  `@{scriptName}`: the script name

_Depth 5:_ Version Information

1.  `@{channel}`: the channel name of this version record
2.  `@{version}`: the version number as a SemVer string

_Depth 7:_ File Information

1.  `@{platform}`: the platform defined for this file, otherwise an empty string
2.  `@{fileName}`: the file name

**"Rolling" Variables**: These variables can be defined at any depth in the JSON tree and are continuously expanded using the variables available. You can reference a rolling variable in itself, which will substitute the template for the contents the variable had at the parent-level.

Right now there's only one such variable: `@{fileBaseUrl}`, which you can use to construct the URL to a file using the template variables available.

For an example to serve updates from the HEAD of a GitHub repository main branch, see [here](https://github.com/TypesettingTools/line0-Aegisub-Scripts/blob/master/DependencyControl.json). An example that shows a feed making use of tagged releases is [also available](https://github.com/TypesettingTools/ASSFoundation/blob/master/DependencyControl.json).

## Reference

This section is currently both incomplete and outdated. Sorry about that.

### DependencyControl

**DependencyControl{_tbl_ [requiredModules]={}, _str_ :name=script*name, \_str* :description=script*description, \_str* :author=script*author, \_str* :url, _str_ :version, _str_ :moduleName, _str_ [:configFile], _string_ [:namespace]} --> _obj_ DependencyControlRecord**

The constructor for a DependencyControl record. Uses the table-based signature.
**Arguments:**

- _requiredModules_: the first and only unnamed argument. Contains all required modules, which may be either a single string for a non-version-controlled requirement or a table with the following fields:
  - **_str_ [moduleName/[1]]:** the module name
  - **_str_ [version]:** The minimum required version of the module. Must conform to Semantic Versioning standards. The module in question must contain a DependencyControl version record or otherwise compatible version number.
  - **_str_ [url]**: The URL of the site where the module can be downloaded from (will be shown to the user in error methods).
  - **_str_ [feed]**: The update feed used to fetch a copy of the required module when it is missing from the user's system.
  - **_bool_ [optional=false]**: Marks the module as an optional requirement. If the module is missing on the user's system, no error will be thrown. However, version requirements _will_ be checked if the module was found.
  - **_str_ [name]**: Friendly module name (used for error messages).

- _name, description, author_: Required for modules, pulled from the \_script\_\_ globals for macros.
- _version_: Must conform to [Semantic Versioning](http://semver.org/) standards. Labels and build metadata are not supported at this time
- _moduleName_: module name (as used in require statements). Required for modules, must be nil for macros. Represents the namespace of a module.
- _url_: The web site/repository URL of your script
- _feed_: The update feed for your script.
- _configFile_: Configuration file base name used by the script. Defaults to the namespace. Used for configuration services and script management purposes.

#### Methods

**:checkVersion(_str/num_ version, _str_ [precision = "patch"]) --> _bool_ moduleUpToDate, _str_ error**

Returns true if the version number of the record is greater than or equal to **version**. Reduce the **precision** to `minor` or `major` to also return true for lower patch or minor versions respectively. If the version can't be parsed it returns nil and and error message.

**:checkOptionalModules(_tbl_ modules) --> _bool_ result, _str_ errorMessage**

Returns true if the optional **modules** have been loaded, where **modules** is a list of module names. If one or more of the modules are missing it returns false and an error message.

**:getConfigFileName() --> _str_ fileName**

Returns a full path to the config file proposed for this script by DependencyControl. Uses the configFile argument passed to the constructor which defaults to the script namespace. The path is subject to user configuration and defaults to "?user\config". The file ending is always .json, because why would you use any other format?

The rationale for this function is to keep all macro and module configuration files neatly in one spot and make them discoverable for other scripts (through the DependencyControl config file).

**:getConfigHandler([defaults], [section], [noLoad]) => _obj_ ConfigHandler**

Returns a ConfigHandler (see [ConfigHandler Documentation](#FIXME)) attached to the config file configured for this script.

**:getLogger(_tbl_ args) => _obj_ Logger**

Returns a Logger (see [Logger Documentation](#FIXME)) preconfigured for this script. Trace level and config file preference default to user-configurable values. Log file name and prefix are based on namespace and script name.

**:getVersionNumber(_str/num_ versionString) --> _int/bool_ version, _str_ error**

Takes a SemVer string and converts it into a version number. If parsing the version string fails it returns false and an error message instead.

**:getVersionString(_int_ [version=@version]) --> _str_ versionString**

Returns a version (by default the script version) as a SemVer string.

**:getConfigFileName() --> _str_ configFileName**

Generates and returns a full path to the registered config file name for the module.

**:loadConfig(_bool_ [importRecord], _bool_ [forceReloadGlobal]) --> _bool_ shouldWriteConfig, _bool_ firstInit**

Loads global DependencyControl and per-script configuration from the DependencyControl configuration file. If **importRecord** is true, the version record information of a DependencyControl record will be (temporarily) overwritten by the values contained in the configuration file.
Global configuration is only loaded on first run or if **forceReloadGlobal** is true.

The first return result indicates there are changes to be written to the config file, the second result returns true if the config file was only just created. _Intended for internal use._

**:loadModule(_tbl_ module, _bool_ [usePrivate]) --> _tbl_ moduleRef**

Loads and returns single module and only errors out in case of module errors. Intended for internal use. If **usePrivate** is true, a private copy of the module is loaded instead.

**:moveFile(_str_ src, _str_ dest) --> _bool_ success, _str_ error**

Moves a file from **source** to **destination** (where both are full file names). Returns true on success or false and error message on failure.

**:register(_tbl_ selfRef, extraUnitTestArgs...) --> _tbl_ selfRef**

Replaces dummy reference written to the global LOADED_MODULES table at DependencyControl object creation time with a reference to this module.
Also automatically registers unit tests for this module, passing in any **extraUnitTestArgs**

The purpose of this construct is to allow circular references between modules. Limitations apply: the modules in question may not use each other during construction/setup of each module (for obvious reasons).

Call this method as replacement for returning your module.

**:registerMacro(_str_ [name=@name], _str_ [description=@description], _func_ processing*function, \_func* [validation_function], _func_ is*active_function, \_bool|string* [submenu=false])**

Alternative Signature:

**:registerMacro(_func_ processing*function, \_func* [validation_function], _func_ is*active_function, \_bool|string* [submenu=false])**

Registers a single macro using script name and description by default.
Use **submenu** to specify a submenu name to use for this macro or set it to `true` to use the automation script name.

If the script entry in the DependencyControl configuration file contains a **customMenu** property, the macro will be placed in the specified menu. Do note that that this setting is for _user customization_ and not to be changed without the user's consent.

For the other arguments, please refer to the [aegisub.register_macro](http://docs.aegisub.org/latest/Automation/Lua/Registration/#aegisub.register_macro) API documentation.

**:registerMacros(_tbl_ macros, _bool|string_ [submenuDefault=true])**

Registers multiple macros, where **macros** is a list of tables containing the arguments to a **:registerMacro()** call for each automation menu entry. a single macro using script name and description by default.
Use **submenuDefault** to specify a submenu all macros will be placed in unless overridden on a per-macro basis. Defaults to `true` which causes the automation script name to be used as the submenu name.

**:registerTests(unitTestArgs...)**

Registers unit tests for automation modules, passing in any of specified **unitTestArgs**. Registration of modules is done automatically upon calling **:register**

**:requireModules([modules=@requiredModules], _bool_ [forceUpdate], _bool_ [updateMode], _tbl_ [addFeeds={@feed})] --> ...**

Loads the modules required by this script and returns a reference for every requirement in the order they were supplied by the user. If an optional module is not found, nil is returned.

The updater will try to download copies of modules that are missing or outdated on the user's system. The **addFeeds** parameter can be used to supply additional feeds to search. If missing/outdated requirements can't be fetched, the method will throw an error in normal mode or false and an error message in **update mode**.

Use **forceUpdate** to override update intervals and perform update checks for all required modules, even if requirements are satisfied.

**:writeConfig(_bool_ [writeLocal=true], _bool_ [writeGlobal=true], _bool_ [concert]]**

Writes **global** and per-module **local** configuration. If **concert** is true, concerted writing will be used to update the configuration of all DependencyControl hosted by any given macro/environment at once. See ConfigHandler documentation for more information. _Intended for internal use._

### Updater

#### Methods

**:getUpdaterErrorMsg(_int_ [code], _str_ targetName, ...) --> _str_ errorMsg**

Used to turn an updater return **code** into a human-readable error message. The **name** of the updated component and other format string parameters are passed into the function.

VarArgs:

1.  **_bool_ isModule**: True when component is a module, false when it is an automation script/macro
2.  **_bool_ isFetch**: True when we are fetching a missing module, false when updating
3.  **extError**: Extended error information as returned by the _:update()_ method

**:getUpdaterLock(_bool_ [doWait], _int_ [waitTimeout=(user config)]) --> _bool_ result, _str_ runningHost**

Locks the updater to the current macro/environment. Since all automation scripts load in parallel we have to make sure multiple automation scripts don't all update/fetch the same dependencies at once multiple times. The solution is to only let one updater operate at a time. The others will wait their turn and recheck if their required modules were fetched in the meantime.

If **doWait** is true, the function will wait until the updater is unlocked or **waitTimeout** has passed. It will then get the lock and return true. If **doWait** is false, the function will return immediately (true on success, false if another updater has the lock). _Intended for internal use_.

**:releaseUpdaterLock()**

Makes an updater host (macro) release its lock on the Updater if it has one. See _:getUpdaterLock_ for more information

**:update(_bool_ [force], _tbl_ [addFeeds]) --> _int_ resultCode, _str_ extError**

Runs the updater on this automation script or module. This includes recursively updating all required modules. When **force** is true, required modules will skip their update interval check.

The updater consults feeds in trust order (closest and most-trusted first) and stops as soon as a source can satisfy the requirement — see [How DependencyControl Selects Package Sources](#how-dependencycontrol-selects-package-sources). You can supply **additional candidate feeds**.

Returns a result code (0: up-to-date, 1: update performed, <=-1: error) and extended error information which can be fed into _:getUpdaterErrorMsg()_ to get a descriptive error message.

### Logger

tbd

### ConfigHandler

tbd

### FileOps

tbd

### UnitTestSuite

Reference documentation for the UnitTestSuite module is available in the [source code](https://github.com/TypesettingTools/DependencyControl/blob/master/modules/l0/DependencyControl/UnitTestSuite.moon#L760)

### UpdateFeed

tbd

## CLI

DependencyControl ships a CLI launcher (`depctrl.lua`) for running tests, building release
bundles, and deploying to a local Aegisub installation — all **without** a running Aegisub
process. All commands read their package list from a feed JSON file and can operate on any
DepCtrl-managed package, not only DependencyControl itself.

### Prerequisites

- _LuaJIT_ on your `PATH`, built with `DLUAJIT_ENABLE_LUA52COMPAT`
- _LuaRocks_, configured for Lua v5.1, which _LuaJIT_ is ABI-compatible with. You may have to select the Lua version explicitly via `luarocks --lua-version=5.1`
- The [moonscript](https://luarocks.org/modules/leafo/moonscript), [LuaFileSystem](https://luarocks.org/modules/hisham/luafilesystem) and [argparse](https://luarocks.org/modules/mpeterv/argparse) rocks, installed into that 5.1 tree:

  ```sh
  luarocks --lua-version=5.1 install moonscript
  luarocks --lua-version=5.1 install luafilesystem
  luarocks --lua-version=5.1 install argparse
  ```

- Your `LUA_PATH` / `LUA_CPATH` must let `luajit` find the LuaRocks-installed modules (`luarocks --lua-version=5.1 path --bin` prints the correct values).

General form:

```sh
luajit depctrl.lua <command> [options]
```

The feed is resolved in this order: `--feed` flag → `DependencyControl.json` in the current
working directory. All commands accept `--target-module` and `--target-macro` to restrict
processing to specific packages; without them the command operates on every package in the feed.

### `test` — Run unit test suites

```sh
luajit depctrl.lua test [--feed <path>] [--report-dir <dir>]
                        [--target-module <ns>] [--target-macro <ns>]
```

Loads every matching package from the feed, runs its DepUnit test suite (if one is registered),
and writes a per-package [CTRF](https://ctrf.io) JSON report. Exit code `0` = all tested
packages passed, `1` = one or more failures or load errors.

Packages without a test suite are skipped with a notice; packages that fail to load are counted
as failures. Log files and config/feed caches are written to a per-run throwaway workspace under
the system temp directory rather than touching your real Aegisub configuration.

The feed must have correct `localFileBasePath` entries so the CLI can resolve source files on
disk.

| Option            | Default                         | Description                                              |
| ----------------- | ------------------------------- | -------------------------------------------------------- |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                               |
| `--report-dir`    | `ctrf/`                         | Directory for per-package CTRF JSON reports              |
| `--target-module` | _(all modules)_                 | Module namespace to test; repeatable                     |
| `--target-macro`  | _(all macros)_                  | Macro namespace to test; repeatable                      |

### `bundle` — Build a release archive

```sh
luajit depctrl.lua bundle [--feed <path>] [--out-dir <dir>]
                          [--target-module <ns>] [--target-macro <ns>]
```

Copies every file listed in the feed into a `dist/` subfolder of `<dir>`, then packages
`dist/` into a zip archive named `<feedName>-v<version>[-<branch>-g<hash>].zip` in `<dir>`.
`dist/` is wiped and recreated on each run. The git branch and hash suffix is omitted when
HEAD is exactly on a tag.

| Option            | Default                         | Description                                  |
| ----------------- | ------------------------------- | -------------------------------------------- |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                   |
| `--out-dir`       | CWD                             | Root for the `dist/` folder and the zip file |
| `--target-module` | _(all modules)_                 | Restrict to this module namespace; repeatable |
| `--target-macro`  | _(all macros)_                  | Restrict to this macro namespace; repeatable  |

Exit code `0` = success, `1` = one or more errors.

### `deploy` — Deploy to a local Aegisub installation

```sh
luajit depctrl.lua deploy [--feed <path>] [--out-dir <dir>] [--clobber | --no-clobber]
                          [--target-module <namespace>] [--target-macro <namespace>]
```

Copies every file listed in the feed directly into `<dir>` using the Aegisub install layout —
macros into `<dir>/automation/autoload/`, modules into `<dir>/automation/modules/`, test files
into `<dir>/automation/tests/DepUnit/…`. Useful for testing against a locally installed Aegisub
without going through a full release build.

| Option            | Default                         | Description                                            |
| ----------------- | ------------------------------- | ------------------------------------------------------ |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                             |
| `--out-dir`       | CWD                             | Deployment root — typically the Aegisub user directory |
| `--clobber`       | false                           | Overwrite existing files in the deployment directory   |
| `--no-clobber`    | _(default)_                     | Skip files that already exist at the destination       |
| `--target-module` | _(all modules)_                 | Restrict to this module namespace; repeatable          |
| `--target-macro`  | _(all macros)_                  | Restrict to this macro namespace; repeatable           |

Exit code `0` = success, `1` = one or more errors.
