ffi = require "ffi"
re  = require "aegisub.re"

--- Shared constants, enums, and terminology used across DependencyControl modules.
-- @class DependencyControlCommon
class DependencyControlCommon
    msgs = {
        validateNamespace: {
            badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        }
    }
    -- Some terms are shared across components
    @platform = "#{ffi.os}-#{ffi.arch}"

    @terms = {
        scriptType: {
            singular: { "automation script", "module" }
            plural: { "automation scripts", "modules" }
        }

        isInstall: {
            [true]: "installation"
            [false]: "update"
        }

        capitalize: (str) -> (str\sub 1, 1)\upper! .. str\sub 2
    }

    -- Common enums
    @RecordType = {
        Managed: 1
        Unmanaged: 2
    }

    @ScriptType = {
        Automation: 1
        Module: 2
        name: {
            legacy: { "macros", "modules" }
            canonical: {"automation", "modules"}
        }
    }

    namespaceValidation = re.compile "^(?:[-\\w]+\\.)+[-\\w]+$"

    --- Validates a DependencyControl namespace string.
    -- @param namespace string
    -- @return boolean|nil
    -- @return string|nil err
    @validateNamespace = (namespace) ->
        return if namespaceValidation\match namespace
            true
        else false, msgs.validateNamespace.badNamespace\format namespace

    automationDir: {
        aegisub.decode_path("?user/automation/autoload"),
        aegisub.decode_path("?user/automation/include")
    }

    @testDir = {aegisub.decode_path("?user/automation/tests/DepUnit/macros"),
                aegisub.decode_path("?user/automation/tests/DepUnit/modules")}
