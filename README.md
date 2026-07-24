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

DependencyControl is self-contained: it bundles a JSON library ([dkjson](https://dkolf.de/dkjson-lua/)), though if you have another `json` module installed, it is used instead. It also now ships with pure-FFI implementations of functionality previously provided by [ffi-experiments](https://github.com/torque/ffi-experiments) modules (_DownloadManager_, _BadMutex_, _PreciseTimer_).

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [DependencyControl for Users](#dependencycontrol-for-users)
3. [DependencyControl for Script Authors](#dependencycontrol-for-script-authors)
4. [Namespaces and Paths](#namespaces-and-paths)
5. [The Updater Feed](#the-updater-feed)
6. [Reference](#reference)
7. [CLI](#cli)
8. [Release Automation](#release-automation)

---

## Prerequisites

DependencyControl downloads and verifies packages, which on some systems relies on a couple of standard shared libraries. What (if anything) you need to install depends on your platform and on whether you use DependencyControl inside Aegisub or through its standalone [CLI](#cli).

### For Aegisub Users

On **Windows** and **macOS** there is nothing to install beyond Aegisub [v3.4.0+](https://github.com/TypesettingTools/Aegisub/releases) itself — or a release of [arch1t3cht's Aegisub fork](https://github.com/arch1t3cht/Aegisub/releases) based on v3.4.0+ (older versions may work, but you're on your own if you run into issues).

On **Linux**, two additional system libraries are used to download and verify packages. Both are almost certainly already installed on any distribution, so you would only need to add them on a very bare-bones system:

- **libcurl 7.30.0 or newer** (`libcurl.so.4`) — downloads packages and updates.
- **OpenSSL 1.1.0 or newer** (`libcrypto.so.1.1` or `libcrypto.so.3`) — computes the SHA-1 hashes DependencyControl relies on, both to verify downloaded files and internally for its locking between concurrent Aegisub instances.

DependencyControl also guards against [server-side request forgery](https://en.wikipedia.org/wiki/Server-side_request_forgery) — a hostile feed trying to point a download at an address inside your own network — through the [`blockPrivateHosts`](#1-global-configuration) setting. For that guard to cover redirects as well, **libcurl 7.80.0 or newer** is needed; with an older libcurl the address you start from is still checked, but the targets of any redirects along the way are not.

### For CLI Users (Script Authors & Contributors)

The [CLI](#cli) runs outside Aegisub and needs its own Lua toolchain (LuaJIT, LuaRocks, and a set of rocks) on top of the system libraries above. See [CLI → Toolchain setup](#toolchain-setup) for the full requirements and install commands.

---

## DependencyControl for Users

As an end-user you don't get to decide whether your scripts use DependencyControl or not, but you can control many aspects of its operation. The updater works out-of-the-box (for any script with an update feed) and is run automatically.

### Installation

1. Download the latest DependencyControl release and unpack its contents into your Aegisub **user** automation directory:
   - On Windows: `%AppData%\Aegisub\automation`
   - On Linux: `~/.aegisub/automation`
   - On OSX: `~/Library/Application Support/Aegisub/automation`

   Do **NOT** unpack the file into the automation directory within the Aegisub installation folder, as this will break the updater.

2. Restart Aegisub or re-scan your autoload directory from within the Aegisub _Automation Manager_.

### Configuration

DependencyControl comes with sane default settings, so if you're happy with that, there's no need to read further. If you want to disable the updater, use custom menus or want to tweak another aspect of DependencyControl, read on.

DependencyControl stores its configuration as a JSON file in the `config` folder of your Aegisub user directory:

- On Windows: `%AppData%\Aegisub\config\l0.DependencyControl.json`
- On Linux: `~/.aegisub/config/l0.DependencyControl.json`
- On OSX: `~/Library/Application Support/Aegisub/config/l0.DependencyControl.json`

The **DependencyControl Toolbox** macro provides a GUI for common management tasks; advanced options still require manual JSON editing.

There are 2 kinds of configuration:

#### 1. Global Configuration

Settings in the top-level `config` object affect all scripts and DependencyControl's own behavior. As of v0.7.0 they're grouped into four sections — `updates`, `feeds`, `logging`, and `paths`. A flat config from an earlier version is migrated into this layout automatically the first time v0.7.0 loads it, so there's nothing to convert by hand. DependencyControl stamps the file with a `$schema` link to the [config schema](schemas/config/v0.7.0.json), which a JSON-aware editor uses to validate and autocomplete your edits.

**`updates` — the update engine**

- _str_ **mode ["auto-update"]:** Which update contexts may install and update at all. Each value includes the ones before it:
  - `"off"` — no installs or updates at all
  - `"user-requested"` — only actions you start yourself (e.g. via the Toolbox)
  - `"dependency-resolution"` — also installing/updating modules a script depends on
  - `"auto-update"` (default) — also background scheduled update checks
- _int_ **checkInterval [302400 (3.5 days)]:** Minimum seconds between two automatic update checks of a given script.
- _int_ **waitTimeout [60]:** Seconds to wait for another process's in-progress update to finish before giving up.
- _int_ **orphanTimeout [50]:** Seconds after which an updater lock whose owner has vanished (e.g. a crashed Aegisub) is treated as stale and may be taken over.
- _str_ **feedTrustPromptThreshold ["auto-update"]:** How freely DependencyControl may ask you to trust an as-yet-untrusted feed before installing from it. Takes the same context values as `mode` (`"off"` never asks; the default allows asking in every context). When a context isn't allowed to prompt, the install fails or is skipped rather than silently using the untrusted feed.
- _str_ **packageChoicePromptThreshold ["user-requested"]:** How freely DependencyControl may ask you to choose among equally-ranked sources for a requirement. Same context values (the default asks only for actions you start yourself). When a context can't prompt, a stable but arbitrary tie-breaker decides instead.
- _bool_ **offerAllSources [false]:** By default the package picker only appears when two or more sources are genuinely tied (same trust band and version). Set this to `true` to be offered _every_ eligible source whenever there's more than one, including lower-ranked and untrusted ones.
- _bool_ **blockPrivateHosts [true]:** Refuse feed and package downloads from hosts that resolve to a private, loopback, or link-local address (an SSRF safeguard). Turn off to use feeds on your local network.

**`feeds` — feed trust, discovery, and caching**

- _arr_ **extraFeeds []:** Your own additional feeds. They're trusted _and_ used as discovery roots: checked for updates to any script, and their advertised `knownFeeds` are crawled to surface further feeds.
- _arr_ **trustedFeeds []:** Feeds you trust as package sources but that are not discovery roots. They let a package install from them without a warning, but aren't themselves crawled for updates.
- _arr_ **blockedFeeds []:** Feeds that must never be used as a package source, overriding all trust and merged with DependencyControl's own block list. Each entry is an object: `url` (required); `matchMode` (`"prefix"`, the default, matches every feed URL starting with `url` case-insensitively, while `"exact"` matches only that one URL); and an optional `reason`.
- _str_ **fetchUntrustedFeeds ["always"]:** What to do when discovery reaches an untrusted feed: `"always"` fetches it, `"never"` skips it, and `"prompt"` asks first (falling back to `"never"` where nothing can prompt, e.g. a headless run).
- _obj_ **crawlLimits:** Bounds on how far untrusted feed discovery expands. Keys: `per-feed` [25] (untrusted feeds a single feed may contribute), `per-root` [50] (budget per configured discovery root), and `depth` [7]. Any unset budget uses its default.
- _int_ **cacheMaxAge [3600]:** Seconds a cached feed snapshot stays fresh before it's re-fetched.
- _int_ **maxFeedSize [5000000]:** Largest single feed response, in bytes, before the fetch is aborted — a guard against a hostile or runaway feed. Set `0` to remove the limit.
- _int_ **feedFetchTimeout [15]:** Longest time, in seconds, to spend fetching a single feed before the transfer is aborted. Set `0` to remove the timeout.

**`logging` — verbosity and retention**

- _int_ **defaultLevel [3]:** Default trace level of DependencyControl's messages; higher levels log more. Setting it above your Aegisub _Trace level_ keeps these messages out of the log window.
- _bool_ **toFile [true]:** Write log messages to a file in the log directory. This is valuable for debugging, especially during script initialization when the Aegisub log window isn't available.
- _int_ **maxFiles [200]:** Old log files are purged once the limit on file count, age, or cumulative size is exceeded.
- _int_ **maxAge [604800 (1 week)]:** Delete log files whose last-modified date is older than this many seconds.
- _int_ **maxSize [10000000 (10 MB)]:** Cumulative byte-size limit across all log files.

**`paths` — base directories** (each accepts Aegisub path tokens such as `?user` and `?data`)

- _str_ **config ["?user/config"]:** Directory for DependencyControl's config files; also the directory offered to automation scripts for their own config (they may or may not use it).
- _str_ **log ["?user/log"]:** Directory for DependencyControl's log files.
- _str_ **cache ["?user/cache"]:** Base directory for on-disk caches. Each cache lives under a `<namespace>/<name>` subdirectory (e.g. the feed cache at `<cache>/l0.DependencyControl/feeds`).

#### 2. Per-script Configuration

Changes made in the `macros` and `modules` sections of the configuration file affect only the script or module in question.

**Available Fields**:

- _str_ **customMenu:** If you want to sort your automation macros into submenus, set this to the submenu name (use `/` to denote submenu levels).
- _str_ **userFeed:** When set the updater will use this feed exclusively to update the script in question (instead of other feeds)
- _int_ **lastUpdateCheck [auto]:** This field is used to store the (epoch) time of the last update check.
- _obj_ **currentSource [auto]:** Remembers which source last satisfied this package and how sticky that choice is (see [Remembering your source choice](#remembering-your-source-choice)). Managed automatically; don't edit it.
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

The **DependencyControl Toolbox**'s _Manage Feeds_ macro lets you review, trust, block, and discover feeds interactively, so most of this can be done without editing the config by hand.

#### Remembering your source choice

When a package can be installed from more than one source and DependencyControl asks you to pick one, the picker also lets you decide how long that choice should stick. The buttons map to:

- **Just This Once**: use the picked source for this install only; you'll be asked again next time there's a choice.
- **Remember**: keep using the picked source as long as it stays available. If it later disappears (e.g. the feed stops offering the package), DependencyControl asks you to choose again — or, during a non-interactive update, falls back to asking next time and proceeds with its own ranked pick for now.
- **Pin/Lock**: pin this source. DependencyControl will keep using it without asking and will refuse to silently switch — if a pinned source becomes unavailable, a required dependency fails (so you can fix the pin) while an optional one is skipped.
- **Auto-Pick**: stop asking for this package and always take the top-ranked source automatically.
- **Cancel**: cancel the operation without installing.

A remembered choice follows the source even if its feed URL changes, so moving a feed won't break it. When the picked source is reached through a [provider](#providing-module-aliases), it's the provider that's remembered, so version bumps update it in place instead of switching to a different one.

## DependencyControl for Script Authors

### Usage for Automation Scripts

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
    {"a-mo.LineCollection", version = "1.0.1", url = "https://github.com/torque/Aegisub-Motion"},
    {"a-mo.Line", version = "1.0.0", url = "https://github.com/TypesettingTools/Aegisub-Motion"},
    {"a-mo.Log", url = "https://github.com/torque/Aegisub-Motion"},
    {"l0.ASSFoundation", version = "0.1.1", url = "https://github.com/TypesettingTools/ASSFoundation",
      feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"},
    {"l0.ASSFoundation.Common", version = "0.1.1", url = "https://github.com/TypesettingTools/ASSFoundation",
      feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"},
    "YUtils"
  }
}
local util, LineCollection, Line, Log, ASS, Common, YUtils = version:requireModules()
```

Specifying a feed in your own version record provides DependencyControl with a source to download updates to your script from. Specifying feeds for required modules managed by DependencyControl allows the Updater to discover those modules and fetch them when they're missing from the user's computer. However, you can omit the feed URLs for required modules when your own feed already has references to them.

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

### Usage for Modules

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
    {"l0.ASSFoundation.Common", version = "0.1.1", url = "https://github.com/TypesettingTools/ASSFoundation",
      feed = "https://raw.githubusercontent.com/TypesettingTools/ASSFoundation/master/DependencyControl.json"},
    {"a-mo.LineCollection", version = "1.0.1", url = "https://github.com/TypesettingTools/Aegisub-Motion"},
    {"a-mo.Line", version ="1.0.0", url = "https://github.com/TypesettingTools/Aegisub-Motion"},
    {"a-mo.Log", url = "https://github.com/TypesettingTools/Aegisub-Motion"},
    "ASSInspector.Inspector",
    {"YUtils", optional = true},
  }
}

local createASSClass, re, util, unicode, Common, LineCollection, Line, Log, ASSInspector, YUtils = version:requireModules()
```

A reference to the version record must be added as the _.version_ field of your returned module for version control to work. A module should also register itself to enable circular dependency support. The _:register()_ method returns your module, so the last lines of your module should look like this:

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
- Provided names may be bare/non-namespaced even though your own `moduleName` must be a valid (dotted) namespace.
- Resolution only applies after DependencyControl itself has been loaded, and always defers to a genuinely installed module of that name — so users can still bring their own.

##### Satisfying a dependency with a provider

`provides` also works across the dependency graph at install time. When a script's `requiredModules` names a module that no feed offers directly, DependencyControl can install a module that lists that name in its `provides` instead — much like Debian's `Provides:` or Arch's `provides`. For example, a script that requires `json` can be satisfied by installing `l0.dkjson`, which provides it. A candidate must actually be installable (its `platforms` must include yours and its version must meet the requirement), a directly-named module is always preferred over a provider, and the usual [package-source precedence](#how-dependencycontrol-selects-package-sources) decides which feed it comes from. Once a provider is installed for a requirement, DependencyControl keeps using and updating that same module rather than switching to a different provider, as long as it can still satisfy the requirement.

A provider can pin _which_ versions of an aliased module it stands in for by giving the table entry an npm-style version range via `provides = {{name = "json", version = "~1.2"}}`. This lets one provider cover a span of releases without being re-published for every patch bump of the aliased module. If not specified, the provider is assumed to satisfy any version requirement for that name.

For module authors: the `provides` you declare in your version record is mirrored into your feed automatically when you run the `update-feed` CLI, so a published feed advertises it without manual upkeep (you may also add it to a feed by hand).

#### Advanced: moving a package to a new feed URL

A package can change the feed it updates from by shipping a release whose record points `feed` at the new URL; DependencyControl picks that up the next time it updates the package. Because source selection is trust-aware (see [How DependencyControl Selects Package Sources](#how-dependencycontrol-selects-package-sources)), plan migrations with that in mind:

- If the new URL is **already trusted** (listed in DependencyControl's feed, or added by users), the move is seamless.
- If the new URL is **not yet trusted**, automatic updates to it are held back. To avoid breaking them, keep serving from your **old, already-trusted feed in parallel** during the transition and/or get the new URL added to DependencyControl's trusted list. Individual users can also add it to their own `trustedFeeds`.

---

## Namespaces and Paths

DependencyControl strictly enforces a **namespace-based file structure** for modules as well as automation macros in order to ensure there are no conflicts between scripts that happen to have the same name.

Automation scripts must define their namespace in the version record whereas for modules the module name (as you would use in a `require` statement) defines the namespace.

Rules for a valid namespace:

1. contains _at least_ one dot
2. must **not** start or end with a dot
3. must **not** contain series of two or more dots
4. the character set is restricted to: `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`
5. _should_ be descriptive (this is more of a guideline)

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

**Tests** live under `?user/automation/tests/DepUnit/modules` or `?user/automation/tests/DepUnit/macros`, depending on whether a module or an automation script is being tested. Test files are resolved as `require` identifiers (`DepUnit.modules.<namespace>` / `DepUnit.macros.<namespace>`), so the dots in the namespace always become path separators — the tree is **nested** for both modules and macros, even though the `autoload` folder itself is flat. A test suite is a single file at the root of the namespace path; a multi-file suite adds sibling files under a folder of the same name.

Our example module _ASSFoundation_ with namespace `l0.ASSFoundation` writes (among others) the following files:

- `?user/automation/include/l0/ASSFoundation.lua`
- `?user/automation/include/l0/ASSFoundation/ClassFactory.lua`
- `?user/automation/include/l0/ASSFoundation/Draw/Bezier.lua`
- `?user/automation/tests/DepUnit/modules/l0/ASSFoundation.lua`

An automation script _MyScript_ with namespace `l0.MyScript` lives at `?user/automation/autoload/l0.MyScript.lua` (flat) but its test suite is nested at `?user/automation/tests/DepUnit/macros/l0/MyScript.lua`.

---

## The Updater Feed

If you want DependencyControl auto-update your package(s) on the user's system, you'll need to supply update information in an updater feed, which is a _JSON_ file with the following layout:

_(`//` denotes a comment explaining the property above)_

```json
{
  "dependencyControlFeedFormatVersion": "0.3.0",
  // The version of the feed format. This example uses the simple v0.3.0 layout, which remains fully supported.
  // The current version is 0.4.0, which adds optional per-file-type template maps, author-defined
  // variables and local path resolution for CI/CLI tooling (see the template section below).
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
          // (see the Namespaces and Paths section for more information). Available as the @{fileName} template variable
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
      // (see the DependencyControl for Script Authors section for more information)
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

- [v0.4.0](./schemas/feed/v0.4.0.json) (current; also validates _v0.3.0_ and legacy _v0.2.0_ feeds)
- [v0.3.0](./schemas/feed/v0.3.0.json) (also validates legacy _v0.2.0_ feeds)

### Template Variables

To make maintaining an update feed easier, you can use several template variables that will be expanded when used inside string values (but **not** keys).

**Regular Variables**: These reference a specific key or value and are available at the same depth and further down the tree from the point on where they were created.

Variables extracted at the **same depth** are expanded in a specific order. As a consequence only references to variables of lower order are expanded in values that are assigned to a variable themselves.

_Depth 1:_ Feed Information

1. `@{feedName}`: The name of the feed
2. `@{baseUrl}`: The baseUrl field
3. `@{feed:<feedName>}`: A reference to a feed URL in the knownFeeds table

_Depth 2:_ Section Information _(v0.4.0)_

1. `@{scriptTypeSection}`: the name of the feed section the package lives in (`macros` or `modules`)
2. `@{scriptType}`: the matching script type identifier (`automation` or `module`)

_Depth 3:_ Script Information

1. `@{namespace}`: the script namespace
2. `@{namespacePath}`: the script namespace with all `.` replaced by `/`
3. `@{scriptName}`: the script name

_Depth 5:_ Version Information

1. `@{channel}`: the channel name of this version record
2. `@{version}`: the version number as a SemVer string

_Depth 7:_ File Information

1. `@{platform}`: the platform defined for this file, otherwise an empty string
2. `@{fileName}`: the file name

**"Rolling" Variables**: These variables can be defined at any depth in the JSON tree — the feed root, a `macros`/`modules` section container _(v0.4.0)_, a package, or a channel — and are continuously expanded using the variables available. You can reference a rolling variable in itself, which will substitute the template for the contents the variable had at the parent-level.

1. `@{fileBaseUrl}`: the base URL to construct file download URLs from
2. `@{localFileBasePath}` _(v0.4.0)_: the on-disk counterpart of `@{fileBaseUrl}`, resolved relative to the feed file when a feed is expanded in local mode; it lets CI/CLI tooling (such as the [DepCtrl CLI](#cli)) locate every packaged file's source in your repository

**Per-file-type template maps** _(v0.4.0)_: the `fileBaseUrls` and `localFileBasePaths` properties hold one full URL/path template per file type (`script`, `test`), usually ending in `@{fileName}`. At each file record, the entry matching the file's `type` becomes the effective `@{fileBaseUrl}`/`@{localFileBasePath}` value, so file entries can simply declare `"url": "@{fileBaseUrl}"`. A file type without a map entry falls back to the scalar `fileBaseUrl`/`localFileBasePath`. The maps roll like the scalar variables, so defining them once at the feed root (or on a section container, when your macros and modules trees follow different layouts) describes every package's file locations in one place.

**Author-defined variables** _(v0.4.0)_: a root-level `vars` object defines your own template variables. A string value is substituted as `@{name}`; an object value is a lookup table indexed as `@{name:key}`, where the key part may itself be a variable. DependencyControl's own feed uses this to derive release-tag names per channel:

```json
"vars": { "tagSuffix": { "alpha": "-alpha", "stable": "" } },
"fileBaseUrls": { "script": "@{fileBaseUrl}v@{version}@{tagSuffix:@{channel}}/@{scriptTypeSection}/@{namespacePath}@{fileName}" }
```

For an example that serves updates from the HEAD of a GitHub repository's main branch, see [line0's script feed](https://github.com/TypesettingTools/line0-Aegisub-Scripts/blob/master/DependencyControl.json). An example that shows a feed making use of tagged releases is [also available](https://github.com/TypesettingTools/ASSFoundation/blob/master/DependencyControl.json). DependencyControl's [own feed](./DependencyControl.json) exercises the full v0.4.0 feature set: root-level template maps, a section-scoped override for the differently-structured macros tree, and channel-keyed release-tag suffixes.

## Reference

The full API reference — every class, method, parameter, and return, for every module — is published at **[typesettingtools.github.io/DependencyControl](https://typesettingtools.github.io/DependencyControl/)**, showing the latest release (with a version picker for earlier releases and the in-development `main`). To build it from your own checkout, or to get the same annotations as editor IntelliSense, see [MoonCATS](#mooncats) below.

### MoonCATS

The `l0.MoonCats` module extracts the [LuaCATS](https://luals.github.io/wiki/annotations/) annotations from MoonScript sources into LuaLS `.d.lua` type definitions and rendered API documentation — see the [`generate-types`](#generate-types--extract-luals-type-definitions) and [`generate-docs`](#generate-docs--render-api-documentation) CLI commands for the packaged workflows. The module itself is a pure text transform available to other tooling: `MoonCats!\extractPackage sources` takes a list of `{requireId, source}` pairs and returns one definition per module plus a diagnostics collection, resolving cross-module references (re-exported classes, package-wide type aliases) across the whole set; `renderDocs sources, opts` runs the same parse and returns documentation pages, an index, and site scaffolding instead; `extractModule` is the single-module convenience. Parsing is AST-assisted via the moonscript rock's own parser, so string literals and comment-lookalike content never confuse the extraction.

## CLI

DependencyControl ships a CLI launcher (`depctrl.lua`) for running tests, building release bundles, and deploying to a local Aegisub installation — all **without** a running Aegisub process. All commands read their package list from a feed JSON file and can operate on any DepCtrl-managed package, not only DependencyControl itself.

### Toolchain setup

Beyond the native runtime libraries the CLI shares with Aegisub (see [Prerequisites](#prerequisites)), running the CLI needs a standalone Lua toolchain:

- _LuaJIT_ on your `PATH`, built with `-DLUAJIT_ENABLE_LUA52COMPAT`
- _LuaRocks_, configured for Lua v5.1, which _LuaJIT_ is ABI-compatible with. You may have to select the Lua version explicitly via `luarocks --lua-version=5.1`
- Your `LUA_PATH` / `LUA_CPATH` must let `luajit` find the LuaRocks-installed modules (`luarocks --lua-version=5.1 path --bin` prints the correct values).

Every command needs three core rocks: [moonscript](https://luarocks.org/modules/leafo/moonscript) (to load the `.moon` sources), [LuaFileSystem](https://luarocks.org/modules/hisham/luafilesystem), and [argparse](https://luarocks.org/modules/mpeterv/argparse).

```sh
luarocks --lua-version=5.1 install moonscript
luarocks --lua-version=5.1 install luafilesystem
luarocks --lua-version=5.1 install argparse
```

Individual commands pull in a few more rocks; install a group only if you run the commands that need it. The [test workflow](.github/workflows/test.yml) installs the full superset.

- **Feed validation:** commands that refresh or write the feed (led by `update-feed`) validate it against the bundled JSON schema using `lua-schema`, with `lpeg` for its pattern rules. Without `lua-schema` present, validation is skipped with a warning rather than failing.
- **`test` with the mock HTTP server:** test suites that exercise download and update code spin up a small mock web server built on `luasocket`, `copas`, and `pegasus`. DependencyControl's own suite needs all three; a package whose tests don't reach the network does not.

```sh
# feed validation
luarocks --lua-version=5.1 install lua-schema
luarocks --lua-version=5.1 install lpeg
# mock HTTP server for network tests
luarocks --lua-version=5.1 install luasocket
luarocks --lua-version=5.1 install copas
luarocks --lua-version=5.1 install pegasus
```

General form:

```sh
luajit depctrl.lua <command> [options]
```

The feed is resolved in this order: `--feed` flag → `DependencyControl.json` in the current working directory. All commands accept `--target-module` and `--target-macro` to restrict processing to specific packages; without them the command operates on every package in the feed.

### `test` — Run unit test suites

```sh
luajit depctrl.lua test [--feed <path>] [--report-dir <dir>]
                        [--target-module <ns>] [--target-macro <ns>]
```

Loads every matching package from the feed, runs its DepUnit test suite (if one is registered), and writes a per-package [CTRF](https://ctrf.io) JSON report. Exit code `0` = all tested packages passed, `1` = one or more failures or load errors.

Packages without a test suite are skipped with a notice; packages that fail to load are counted as failures. Log files and config/feed caches are written to a per-run throwaway workspace under the system temp directory rather than touching your real Aegisub configuration.

The feed must have correct `localFileBasePaths` (or `localFileBasePath`) entries so the CLI can resolve source files on disk.

| Option            | Default                         | Description                                 |
| ----------------- | ------------------------------- | ------------------------------------------- |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                  |
| `--report-dir`    | `ctrf/`                         | Directory for per-package CTRF JSON reports |
| `--target-module` | _(all modules)_                 | Module namespace to test; repeatable        |
| `--target-macro`  | _(all macros)_                  | Macro namespace to test; repeatable         |

### `bundle` — Build a release archive

```sh
luajit depctrl.lua bundle [--feed <path>] [--out-dir <dir>]
                          [--target-module <ns>] [--target-macro <ns>]
```

Copies every file listed in the feed into a `dist/` subfolder of `<dir>`, then packages `dist/` into a zip archive named `<feedName>-v<version>[-<branch>-g<hash>].zip` in `<dir>`. `dist/` is wiped and recreated on each run. The git branch and hash suffix is omitted when HEAD is exactly on a tag.

| Option            | Default                         | Description                                   |
| ----------------- | ------------------------------- | --------------------------------------------- |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                    |
| `--out-dir`       | CWD                             | Root for the `dist/` folder and the zip file  |
| `--target-module` | _(all modules)_                 | Restrict to this module namespace; repeatable |
| `--target-macro`  | _(all macros)_                  | Restrict to this macro namespace; repeatable  |

Exit code `0` = success, `1` = one or more errors.

### `deploy` — Deploy to a local Aegisub installation

```sh
luajit depctrl.lua deploy [--feed <path>] [--out-dir <dir>] [--clobber | --no-clobber]
                          [--target-module <namespace>] [--target-macro <namespace>]
```

Copies every file listed in the feed directly into `<dir>` using the Aegisub install layout — macros into `<dir>/automation/autoload/`, modules into `<dir>/automation/modules/`, test files into `<dir>/automation/tests/DepUnit/…`. Useful for testing against a locally installed Aegisub without going through a full release build.

| Option            | Default                         | Description                                            |
| ----------------- | ------------------------------- | ------------------------------------------------------ |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                             |
| `--out-dir`       | CWD                             | Deployment root — typically the Aegisub user directory |
| `--clobber`       | false                           | Overwrite existing files in the deployment directory   |
| `--no-clobber`    | _(default)_                     | Skip files that already exist at the destination       |
| `--target-module` | _(all modules)_                 | Restrict to this module namespace; repeatable          |
| `--target-macro`  | _(all macros)_                  | Restrict to this macro namespace; repeatable           |

Exit code `0` = success, `1` = one or more errors.

### `update-feed` — Refresh and extend the feed

```sh
luajit depctrl.lua update-feed [--feed <path>] [--channel <name>] [--dry-run] [--add-files]
                               [--mark-released] [--release-date <date>]
                               [--target-module <ns>] [--target-macro <ns>]
```

Refreshes each targeted package's channel in place: recomputes SHA-1 hashes from the local source files, updates the version, dependencies and provided aliases from the package's DependencyControl record, and flags files that have vanished locally with `delete: true`. Any package that changed has its `released` date reset to `null` to mark the build as pending. The feed is validated against the bundled schema before processing.

With `--add-files`, files found on disk that the targeted channel doesn't list are added to it, complete with computed SHA-1 hashes. Discovery works by inverting the effective per-file-type `localFileBasePaths` templates — every template whose only unexpanded variable is `@{fileName}` is matched against the files below it — so it requires the feed to declare `localFileBasePaths` (at any level; see the template section above). New _packages_ are not discovered; add those to the feed by hand.

With `--mark-released`, each targeted channel still marked unreleased (`released` is `null`) is stamped with the release date — today (UTC) by default, or the date passed to `--release-date` (giving a date implies `--mark-released`). A channel that already carries a date keeps it. This is the last step of a release, recording which builds have shipped — the release workflow runs it so version tooling can later tell a released version from a pending one, passing one date so every stamp in a run agrees.

| Option            | Default                         | Description                                            |
| ----------------- | ------------------------------- | ------------------------------------------------------ |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                             |
| `--channel`       | _(each package's default)_      | Channel to update                                      |
| `--dry-run`       | false                           | Print what would change without writing back           |
| `--add-files`     | false                           | Add entries for on-disk files missing from the channel |
| `--mark-released` | false                           | Stamp the release date on channels still unreleased    |
| `--release-date`  | today (UTC)                     | Date to stamp with `--mark-released`                   |
| `--target-module` | _(all modules)_                 | Restrict to this module namespace; repeatable          |
| `--target-macro`  | _(all macros)_                  | Restrict to this macro namespace; repeatable           |

Exit code `0` = success, `1` = one or more packages had errors.

### `bump-version` — Bump package versions (lockstep)

```sh
luajit depctrl.lua bump-version [--feed <path>] [--channel <name>] (--major | --minor | --patch)
                                (<namespace>… | --all-changed)
```

Bumps the given packages — or, with `--all-changed`, every package changed since its last release — to the repository's lockstep version, then refreshes the feed. Versions are managed in lockstep: a release only advances the packages that actually changed, and they all move to the same repo-level version. The versions and release state are read from the working channel (`--channel`, or the channel marked `default: true`). The target version is derived from that channel's release dates: if the highest version present has already been released, a new cycle starts and the version is bumped by the chosen component; otherwise the packages join the release already in progress. If a later bump reaches past the in-progress version, every package already bumped into that cycle is carried up with it, so a release never spans two versions.

Each version lives in its package's source, on the line marked `-- @{<namespace>:version}` (e.g. `-- @{l0.MoonCats:version}`) — the feed template variable the literal feeds, keyed by the package's own namespace just like everything else DependencyControl tracks. The command rewrites the literal there and updates the channel's version and file hash in the feed to match. `version` is the only property synced this way — every other record field flows source → feed through `update-feed`, never the reverse — so it is the only recognized marker. Before touching anything the command verifies the feed's hashes already match the sources and bails if not, so its only feed change is the version bump — run `update-feed` and commit first if it reports the feed out of sync.

| Option          | Default                         | Description                                       |
| --------------- | ------------------------------- | ------------------------------------------------- |
| `--feed`        | `DependencyControl.json` in CWD | Path to the feed JSON file                        |
| `--channel`     | _(the default channel)_         | Channel whose versions and release state drive it |
| `--major`       | —                               | Start a new cycle by bumping the major component  |
| `--minor`       | —                               | Start a new cycle by bumping the minor component  |
| `--patch`       | —                               | Start a new cycle by bumping the patch component  |
| `--all-changed` | false                           | Bump every package changed since its last release |

Exit code `0` = success (including nothing to bump), `1` = the feed was out of sync or a package/marker couldn't be resolved.

### `merge-feed` — Publish channel(s) from one feed into another

```sh
luajit depctrl.lua merge-feed [--feed <src>] --into <dst> --from <channel> --to "<channels>"
                              --default-channel <name> [--released <date>] [--dry-run]
```

Copies the `--from` channel of every package in the source feed into each `--to` channel of the destination feed (updated in place), then writes the destination through the feed's canonical formatter. Each destination channel's `default` flag is set (true only for `--default-channel`) and its release date stamped when `--released` is given; file hashes are copied as-is, so no sources are read. Channels not named in `--to` are left untouched — they keep their previously published versions — and a package missing from the destination is added carrying only the `--to` channels. Top-level feed metadata and shared package fields track the source. This is how the release workflow promotes the dev feed's channel onto the published `stable`/`alpha` channels while leaving the channel it isn't releasing in place.

| Option              | Default                         | Description                                         |
| ------------------- | ------------------------------- | --------------------------------------------------- |
| `--feed`            | `DependencyControl.json` in CWD | Source feed to copy from                            |
| `--into`            | _(required)_                    | Destination feed, updated in place                  |
| `--from`            | _(required)_                    | Source channel to copy                              |
| `--to`              | _(required)_                    | Destination channel(s), space-separated             |
| `--default-channel` | _(required)_                    | Which destination channel becomes default: true     |
| `--released`        | _(unset)_                       | Release date to stamp on the destination channel(s) |
| `--dry-run`         | false                           | Compute the merge without writing the destination   |

Exit code `0` = success, `1` = a feed couldn't be loaded or a required option was missing.

### `release-notes` — Render grouped release notes from the changelog

```sh
luajit depctrl.lua release-notes [--feed <path>] [--channel <name> | --version <ver>] [--title <text>] [--output <path>]
```

Renders a GitHub-flavored markdown release body from one version's changelog across every package that has entries for it, grouping them into sections — New Features, Bug Fixes, Changes, Other Changes — by a conventional-commit-style marker at the start of each changelog entry:

```text
<type>[(<scope>)][!]: <message>
```

`type` is `feat`, `fix`, or `change` (case-insensitive); an unrecognized leading token leaves the entry uncategorized under Other Changes. `(scope)` is an optional area tag such as `(Updater)` that becomes the entry's bold lead-in. A trailing `!` flags a breaking change: the entry stays in its type's section but is tagged ⚠️ and floated above that section's non-breaking entries. The package whose name matches the feed's `name` is treated as primary — its unscoped entries render with no lead-in, while other packages fall back to their namespace's last segment, so every line stays attributed in the aggregated notes.

The same markers drive the changelog the Toolbox prints to Aegisub's log on update: there the machine `type` token is dropped and each entry is rendered under a glyph-headed category (✨ Features, 🐛 Fixes, 🔧 Changes), breaking entries tagged ⚠️ and floated to the top of their section, so the convention never leaks into what users read. Feeds need no markers to work — a version with nothing marked renders as a flat list, no headings, in both the release body and the log.

Pass `--version` for an exact version, or `--channel` (the default channel if omitted) to use the highest version that channel advertises. Notes go to stdout unless `--output` writes them to a file, which receives only the notes and none of the setup logging — so the release workflow uses `--output` to fill the body of the GitHub Release it cuts.

| Option      | Default                         | Description                                     |
| ----------- | ------------------------------- | ----------------------------------------------- |
| `--feed`    | `DependencyControl.json` in CWD | Path to the feed JSON file                      |
| `--channel` | _(the channel marked default)_  | Channel whose version's changelog to render     |
| `--version` | _(derived from `--channel`)_    | Exact version to render (overrides `--channel`) |
| `--title`   | _(none)_                        | Optional top-level `#` heading to prepend       |
| `--output`  | _(stdout)_                      | Write the notes to this file instead of stdout  |

Exit code `0` = success (including an empty result), `1` = the feed couldn't be loaded or no version could be resolved.

### `generate-types` — Extract LuaLS type definitions

```sh
luajit depctrl.lua generate-types [--feed <path>] [--out-dir <dir>] [--check] [--target-module <ns>]
```

Extracts the [LuaCATS](https://luals.github.io/wiki/annotations/) annotations from the feed's module sources into LuaLS `.d.lua` definition files (one per module, mirroring the require path under the output directory), powered by the [MoonCATS](#mooncats) module. Pointing the [Lua language server](https://luals.github.io/)'s `Lua.workspace.library` setting at the definition tree gives any Lua or MoonScript project full IntelliSense — completion, signature help, and type checking — for every DependencyControl-managed module; this repository's own `.vscode/settings.json` wires up `types/` that way. For browsable API documentation rendered from the same annotations, see [`generate-docs`](#generate-docs--render-api-documentation) below.

Beyond copying annotation blocks, the extractor synthesizes what LuaLS can't infer from MoonScript: a constructor call signature (`@overload`) for every class built from its `new` parameters, a typed per-enum class for each exported `Enum` so members complete and type-check, `@field` declarations for data members and instance defaults, and cross-module types for re-exported classes. Macros are skipped — they aren't require-able and have no type definition to generate.

With `--check`, nothing is written; instead the extraction's findings act as an annotation linter: missing annotation blocks on public members, `@param` tags that disagree with the real signature in name or count, and explicit value returns without a `@return` are reported as errors and fail the run. Note that a MoonScript function's implicit final-expression return is deliberately not flagged as missing a `@return`, so a clean check is not proof of complete return documentation.

| Option            | Default                         | Description                                              |
| ----------------- | ------------------------------- | -------------------------------------------------------- |
| `--feed`          | `DependencyControl.json` in CWD | Path to the feed JSON file                               |
| `--out-dir`       | `types` in CWD                  | Root directory for the generated definition tree         |
| `--check`         | false                           | Lint annotations only; write nothing, exit `1` on errors |
| `--target-module` | _(all modules)_                 | Restrict to this module namespace; repeatable            |

Exit code in generate mode: `0` = success, `1` = a module failed to parse, a definition failed to emit, or a file couldn't be written (annotation lint findings are reported but don't fail generation). In `--check` mode: `1` when any error-severity finding exists.

### `generate-docs` — Render API documentation

```sh
luajit depctrl.lua generate-docs [--feed <path>] [--out-dir <dir>] [--site <flavor>] [--site-name <title>]
                                 [--include-private] [--target-module <ns>]
```

Renders browsable API documentation straight from the module sources' LuaCATS annotations — one markdown page per module, plus an index grouped by package. Because it reads the annotations themselves (via [MoonCATS](#mooncats)) rather than the generated type definitions, it documents everything the annotations carry, including details that don't survive into definition files or third-party doc generators: constructor parameter tables with descriptions, deprecation notices with their reasons, per-value enum member descriptions from `@alias` variant lines, and MoonScript's real instance-vs-class member distinction. Every method shows its call signature in both MoonScript and Lua form, parameter and field types cross-link to the page that defines them, and private members are omitted unless `--include-private` renders them with a badge.

For a **standalone API site**, `--site mkdocs` emits a ready-to-serve, self-contained [MkDocs](https://www.mkdocs.org/) project, and `--site mdbook` the [mdBook](https://rust-lang.github.io/mdBook/) equivalent. The **default, `--site none`**, is the advanced path DependencyControl's own site takes: it writes only an **embeddable reference section**, which a committed `mkdocs.yml` folds into a larger, hand-written site through the [`mkdocs-literate-nav`](https://github.com/oprypin/mkdocs-literate-nav) plugin, keeping `docs/` and `mkdocs.yml` as committed source with only the generated `docs/reference/` gitignored.

Published API docs are versioned on GitHub Pages by the `Docs` workflow (`.github/workflows/docs.yml`), which regenerates the docs and deploys them with [mike](https://github.com/jimporter/mike): every merge to main updates `/main/`, every `v*` tag publishes an immutable `/<tag>/` copy and moves the `latest` alias, and a manual workflow dispatch on any branch publishes a `/<branch>/` preview. The site's root URL redirects to `latest` once the first release exists, and to `/main/` before then, so it is never a dead link. The Material theme's version picker lists all published versions; a stale preview can be dropped with `mike delete <branch> --push` from the repository root (where the committed `mkdocs.yml` lives). Serving requires the repository's Pages source to be set to the `gh-pages` branch (root).

| Option              | Default                         | Description                                              |
| ------------------- | ------------------------------- | -------------------------------------------------------- |
| `--feed`            | `DependencyControl.json` in CWD | Path to the feed JSON file                               |
| `--out-dir`         | `docs/reference` in CWD         | Embeddable reference dir, or a standalone site root      |
| `--site`            | `none`                          | `none` embed section; `mkdocs`/`mdbook` standalone       |
| `--site-name`       | `DependencyControl API`         | Site title                                               |
| `--include-private` | false                           | Render private members (badged) instead of omitting them |
| `--target-module`   | _(all modules)_                 | Restrict to this module namespace; repeatable            |

Exit code `0` = success, `1` = a module failed to parse or a file couldn't be written.

## Release Automation

DependencyControl ships two **reusable GitHub Actions workflows** for a publish-branch release model — used both by this repo and by any package repo that wants the same setup:

- [`reusable-publish-release.yml`](.github/workflows/reusable-publish-release.yml) — run on demand; copies your dev feed's channel onto the published channel(s) of a separate publish branch, tags the versions they reference, records the release date back on the dev branch (for a stable release) so `bump-version` can tell what has shipped, and can cut a GitHub Release per channel with notes rendered from the changelog.
- [`reusable-update-feed.yml`](.github/workflows/reusable-update-feed.yml) — on every push to the dev branch, refreshes the feed's file hashes and versions from the sources and commits the result back, so pull requests only have to author metadata.

### The branch model

The feed URL baked into installed configs points at one branch, so that branch must only ever advertise released, downloadable versions. The workflows keep the dev and published states on separate branches:

- a **dev branch** (`main`) whose `DependencyControl.json` carries a single dev channel — the working state, edited freely in pull requests;
- a **publish branch** (`publish`) whose `DependencyControl.json` carries the user-facing channels (e.g. `stable` and `alpha`) — written only by the release workflow, and the branch the feed URL serves.

A release _copies_ the dev channel onto a chosen published channel and leaves the channels it isn't releasing untouched, so the published channels can sit at different versions. Each channel's files resolve from a `v<version>` tag (with the channel's tag suffix) that the release workflow creates.

DependencyControl's own feed URL served from `master` through v0.6.x; from v0.7.0 it serves from `publish`, the workflow's default. Because clients older than v0.7.0 can't read the current feed format, a one-time resolved feed left on `master` advertises v0.7.0 so they can upgrade onto `publish`. Any branch name works, as long as it's the one your feed URL points at.

### Using the workflows in your own package

1. **Set up the branches.** Make your dev branch the default and create a publish branch. In your feed, give each package a single dev channel (its name is the `source-channel` input, default `main`); the release workflow creates the published channels.
2. **Add two thin caller workflows** that pin a DependencyControl version and pass your layout. A publish caller (`.github/workflows/release.yml`):

   ```yaml
   name: Release
   on:
     workflow_dispatch:
       inputs:
         ref:
           description: Ref to release
           default: main
         channels:
           description: Channel(s) to publish (space-separated)
           default: stable
   permissions:
     contents: write
   jobs:
     publish:
       permissions:
         contents: write
       uses: TypesettingTools/DependencyControl/.github/workflows/reusable-publish-release.yml@v1
       with:
         ref: ${{ github.event.inputs.ref }}
         channels: ${{ github.event.inputs.channels }}
         default-channel: stable
         release-channels: stable
       secrets:
         app-private-key: ${{ secrets.CI_APP_PRIVATE_KEY }} # only if the publish branch is protected
   ```

   An update-feed caller (`.github/workflows/update-feed.yml`):

   ```yaml
   name: Update feed
   on:
     push:
       branches: [main]
       paths: ["**/*.moon", "DependencyControl.json"]
   permissions:
     contents: write
   jobs:
     sync:
       if: ${{ !contains(github.event.head_commit.message, '[skip ci]') }}
       permissions:
         contents: write
       uses: TypesettingTools/DependencyControl/.github/workflows/reusable-update-feed.yml@v1
   ```

3. **Version with `bump-version`.** Bump the changed packages (lockstep) before releasing; the update-feed workflow propagates the new versions into your dev feed, and the release workflow tags and publishes them.

### Branch protection

Each workflow pushes to the branch it maintains — the publish workflow to the publish branch and its version tags, the update-feed workflow to the dev branch. With no protection they push using the built-in `GITHUB_TOKEN` and need no credential setup. To protect those branches, note that `GITHUB_TOKEN` _cannot_ be granted bypass: a ruleset's bypass list accepts roles, teams, GitHub Apps, and deploy keys — but not the `github-actions[bot]` identity the token runs as. Give the workflows a **GitHub App** on the bypass list instead:

1. **Create a GitHub App** with repository permission _Contents: read & write_ and no webhook, then generate a private key and note the App's Client ID.
2. **Install the App** on the package repository.
3. **Add the App to the bypass list** of each protected branch's ruleset — the publish branch, the dev branch, or both — plus any tag protection that the publish workflow's version tags would trip.
4. **Store the credentials** as repository Actions entries: the Client ID as a **variable** (it isn't sensitive) such as `DEPCTRL_CI_APP_CLIENT_ID`, and the private key as a **secret** such as `DEPCTRL_CI_APP_PRIVATE_KEY`.
5. **Pass them to whichever caller pushes a protected branch** — the publish and update-feed callers both accept `app-client-id: ${{ vars.DEPCTRL_CI_APP_CLIENT_ID }}` and the `app-private-key: ${{ secrets.DEPCTRL_CI_APP_PRIVATE_KEY }}` secret.

Each workflow mints a short-lived token from the App for its pushes and falls back to `GITHUB_TOKEN` when these inputs are absent, so you can develop against unprotected branches and add the App only when you lock them down.

### Key inputs

Both workflows fetch the depctrl CLI from this repo (`depctrl-ref`, default `latest` — the newest DependencyControl release), so you never vendor it. The publish workflow's inputs:

| Input | Default | Description |
| --- | --- | --- |
| `ref` | _(required)_ | Commit or branch to release (its source is tagged) |
| `channels` | _(required)_ | Space-separated channels to publish (e.g. `stable alpha`) |
| `default-channel` | _(required)_ | Which published channel is marked `default: true` |
| `source-channel` | `main` | The dev feed channel to copy from |
| `dev-branch` / `publish-branch` | `main` / `publish` | Branch names |
| `stable-channel` | `stable` | Publishing this channel records the release date on the dev branch |
| `release-channels` | _(none)_ | Published channels to also cut a GitHub Release for |
| `depctrl-ref` | `latest` | DependencyControl ref for the CLI (`latest`, a tag, or a branch) |
| `app-client-id` | _(none)_ | GitHub App Client ID for branch-protection bypass |

`reusable-update-feed.yml` takes the matching `dev-branch`, `depctrl-ref`, and `app-client-id` inputs plus the `app-private-key` secret. See each workflow file's header for the full contract.
