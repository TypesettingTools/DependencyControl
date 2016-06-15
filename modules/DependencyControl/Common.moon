ffi = require "ffi"
re = require "re"
Logger = require "l0.DependencyControl.Logger"

class DependencyControlCommon
    -- Some terms are shared across components
    msgs = {
        validateNamespace: {
            badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        }
    }

    @logger =  Logger fileBaseName: "DepCtrl.Common"
    @platform = "#{ffi.os}-#{ffi.arch}"
    @globalConfig = {
        file: aegisub.decode_path "?user/config/l0.DependencyControl.json",
        defaults: {
            updaterEnabled: true
            updateInterval: 302400
            traceLevel: 3
            extraFeeds: {}
            tryAllFeeds: false
            dumpFeeds: true
            configDir:"?user/config"
            logMaxFiles: 200
            logMaxAge: 604800
            logMaxSize: 10*(10^6)
            updateWaitTimeout: 60
            updateOrphanTimeout: 600
            logDir: "?user/log"
            writeLogs: true
        }
    }

    @terms = {
        scriptType: {
            singular: { "automation script", "module" }
            plural: { "automation scripts", "modules" }
        }

        isInstall: {
            [true]: "installation"
            [false]: "update"
        }

        capitalize: (str) -> str[1]\upper! .. str\sub 2
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

    @InstallState = {
        Orphaned: -1
        Pending: 0
        Downloaded: 1
        Installed: 2
    }

    automationDir: {
        aegisub.decode_path("?user/automation/autoload"),
        aegisub.decode_path("?user/automation/include")
    }

    @testDir = {aegisub.decode_path("?user/automation/tests/DepUnit/macros"),
                aegisub.decode_path("?user/automation/tests/DepUnit/modules")}

    namespaceValidation = re.compile "^(?:[-\\w]+\\.)+[-\\w]+$"
    @validateNamespace = (namespace) ->
        return if namespaceValidation\match namespace
            true
        else false, msgs.validateNamespace.badNamespace\format namespace