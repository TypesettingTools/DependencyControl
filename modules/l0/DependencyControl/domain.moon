Enum = require "l0.DependencyControl.Enum"
pathOps = require "l0.DependencyControl.path-ops"

msgs = {
  validateNamespace: {
    badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
  }
  getNamespacedPath: {
    badBasePath: "Provided base path '%s' is not a valid full path (%s)."
    badPath: "Could not generate a valid full path from base path '%s' and namespaced sub-path '%s': %s."
  }
}

---Whether a record is managed (installed and updated) or unmanaged (tracked only).
---@alias RecordType
---| "managed" # Managed: a script/module DependencyControl installs and keeps up to date
---| "unmanaged" # Unmanaged: a record describing a module DependencyControl tracks but does not update
RecordType = Enum "RecordType", {
  Managed: "managed"
  Unmanaged: "unmanaged"
}

---Whether a script is an automation script or a require()-able module.
---@alias ScriptType
---| "automation" # Automation: an automation script (macro / applied filter)
---| "module" # Module: a require()-able module
ScriptType = Enum "ScriptType", {
  Automation: "automation"
  Module: "module"
}

---The config/feed section a script type is stored under.
---@alias ScriptTypeSection
---| "macros" # Automation scripts are stored in the "macros" section
---| "modules" # Modules are stored in the "modules" section
ScriptTypeSection = Enum "ScriptTypeSection", {
  [ScriptType.Automation]: "macros"
  [ScriptType.Module]: "modules"
}

---User policy for fetching feeds that are neither trusted nor blocked.
---`prompt` only applies to feed discovery; dependency resolution always fetches and instead
---gates *installing* from an untrusted feed via the `feedTrustPromptThreshold` setting.
---@alias FetchUntrustedFeeds
---| "always" # Always: fetch untrusted feeds without asking (the default)
---| "never" # Never: never fetch untrusted feeds
---| "prompt" # Prompt: ask before fetching an untrusted feed; falls back to Never where no prompter is available (e.g. headless)
FetchUntrustedFeeds = Enum "FetchUntrustedFeeds", {
  Always: "always"
  Never: "never"
  Prompt: "prompt"
}

-- forward-declared so the members below close over the local rather than a global of the same name
local Domain

---Shared vocabulary of DependencyControl's problem domain: the kinds of scripts and records it
---manages, the human-readable terms for them, namespace rules, and install/test locations.
---@class Domain
Domain = {
  :FetchUntrustedFeeds
  :RecordType
  :ScriptType
  :ScriptTypeSection

  terms: {
    scriptType: {
      singular: {
        [ScriptType.Automation]: "automation script"
        [ScriptType.Module]: "module"
      }
      plural: {
        [ScriptType.Automation]: "automation scripts"
        [ScriptType.Module]: "modules"
      }
    }

    isInstall: {
      [true]: "installation"
      [false]: "update"
    }

    capitalize: (str) -> (str\sub 1, 1)\upper! .. str\sub 2
  }

  ---Validates a DependencyControl namespace string.
  ---@param namespace string
  ---@return boolean? valid True when the namespace is well-formed.
  ---@return string? err Validation error message when invalid.
  validateNamespace: (namespace) ->
    segments = [seg for seg in namespace\gmatch "[^%.]+"]
    _, dotCount = namespace\gsub "%.", ""
    if #segments >= 2 and dotCount == #segments - 1 and not namespace\match "[^-._%w]"
      return true
    return false, msgs.validateNamespace.badNamespace\format namespace

  ---Returns the Aegisub directory that scripts of the given type are installed to.
  ---@param scriptType ScriptType Whether to resolve the automation-script or module directory.
  ---@param rootDir? string Aegisub path token to resolve against (defaults to "?user").
  ---@return string? dir Absolute directory path, or nil for an unrecognized script type.
  getAutomationDir: (scriptType, rootDir = "?user") ->
    switch scriptType
      when ScriptType.Automation then aegisub.decode_path("#{rootDir}/automation/autoload")
      when ScriptType.Module then aegisub.decode_path("#{rootDir}/automation/include")
      else nil

  ---Returns the DepUnit test directory for scripts of the given type.
  ---@param scriptType ScriptType Whether to resolve the automation-script or module test directory.
  ---@param rootDir? string Aegisub path token to resolve against (defaults to "?user").
  ---@return string? dir Absolute directory path, or nil for an unrecognized script type.
  getTestDir: (scriptType, rootDir = "?user") ->
    switch scriptType
      when ScriptType.Automation then aegisub.decode_path("#{rootDir}/automation/tests/DepUnit/macros")
      when ScriptType.Module then aegisub.decode_path("#{rootDir}/automation/tests/DepUnit/modules")
      else nil

  ---Converts a base path and namespace into a namespaced filesystem path.
  ---Dots in the namespace are converted to path separators when nested is true.
  ---@param basePath string|string[] Base path (or segments) the namespaced path is created under.
  ---@param namespace string
  ---@param ext string File extension (including the dot).
  ---@param nested? boolean Convert namespace dots to path separators (default true).
  ---@return string? path
  ---@return string? err
  getNamespacedPath: (basePath, namespace, ext, nested = true) ->
    res, msg = Domain.validateNamespace namespace
    return nil, msg unless res

    fullBasePath, msg = pathOps.validateFullPath basePath
    return nil, msgs.getNamespacedPath.badBasePath\format basePath, msg unless fullBasePath

    namespacePath = "#{nested and namespace\gsub("%.", pathOps.pathSep) or namespace}#{ext}"
    normalizedFullPath, msg = pathOps.validateFullPath namespacePath, false, fullBasePath
    return nil, msgs.getNamespacedPath.badPath\format fullBasePath, namespacePath, msg unless normalizedFullPath

    return normalizedFullPath
}

return Domain
