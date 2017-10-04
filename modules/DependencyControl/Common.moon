ffi = require "ffi"
re = require "re"
Logger = require "l0.DependencyControl.Logger"
Enum = require "l0.DependencyControl.Enum"

class DependencyControlCommon
    -- Some terms are shared across components
    msgs = {
        validateNamespace: {
            badNamespace: "Namespace '%s' failed validation. Namespace rules: must contain 1+ single dots, but not start or end with a dot; all other characters must be in [A-Za-z0-9-_]."
        }
    }

    @logger =  Logger fileBaseName: "DepCtrl.Common", toFile: true
    @platform = "#{ffi.os}-#{ffi.arch}"

    @terms = {
        scriptType: {
            singular: { "automation script", "module" }
            plural: { "automation scripts", "modules" }
        }

        isInstall: {
            [true]: "install"
            [false]: "update"
        }

        capitalize: (str) -> str[1]\upper! .. str\sub 2
    }

    @name: {
        scriptType: {
            legacy: { "macros", "modules" }
            canonical: {"automation", "modules"}
        }
    }

    @UpdaterMode = Enum "UpdaterMode", {
        Disabled: 0
        Manual: 1
        Auto: 2
    }, @logger

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


    @globalConfig = {
        file: aegisub.decode_path "?user/config/l0.DependencyControl.json",
        defaults: {
            updaterEnabled: false
            updateInterval: 302400
            traceLevel: 3
            traceToFileLevel: 4
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

    @defaultScriptConfig = {
        updaterMode: @UpdaterMode.Auto
    }
