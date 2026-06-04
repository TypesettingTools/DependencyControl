-- DependencyControl wrapper around the vendored upstream dkjson.
--
-- The upstream library is kept pristine and unmodified at `modules/l0/dkjson/vendor/dkjson.lua`
-- so it can be updated by dropping in a new copy. The wrapper is a thin overlay that only
-- carries a DependencyControl version record and defers everything else to the upstream module.
--
-- Resolving the bare module specifiers this module `provides` ("json", "dkjson") is 
-- handled by DependencyControl's module searcher. Locally installed copies of dkjson,
-- luajson or any other JSON module will take precedence over this one if imported
-- via bare specifier.

dkjson = require "l0.dkjson.vendor.dkjson"

wrapper = setmetatable {}, __index: dkjson

wrapper.__depCtrlInit = (DependencyControl) ->
    wrapper.version = DependencyControl {
        name: "dkjson"
        version: "2.10.0"
        description: "David Kolf's JSON module for Lua."
        author: "David Kolf"
        moduleName: "l0.dkjson"
        url: "http://dkolf.de/dkjson-lua/"
        feed: "https://raw.githubusercontent.com/TypesettingTools/DependencyControl/master/DependencyControl.json"
        provides: {"json", "dkjson"}
    }

return wrapper
