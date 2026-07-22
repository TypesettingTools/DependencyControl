-- dkjson wrapper tests: the Prettier-flavored encoder (used to persist the config) must always emit
-- valid JSON. In particular a non-string object key — e.g. a stray integer left on a malformed
-- required-module spec — has to be quoted, or the config file it writes can no longer be parsed.
-- Called from test.moon as: (controls\requireTest "dkjson")!
->
  dkjson = require "l0.dkjson"

  prettier = (value) -> dkjson.encode value, {indentMode: "prettier"}

  {
    _description: "Tests for the DependencyControl dkjson wrapper's Prettier encoder."

    encode_prettierQuotesIntegerKey: (ut) ->
      -- an object whose only key is an integer must still serialize to parseable JSON
      decoded = dkjson.decode prettier {[2]: "json"}
      ut\assertNotNil decoded
      ut\assertEquals decoded["2"], "json"

    encode_prettierQuotesMixedKeys: (ut) ->
      -- a string key alongside an integer key: both survive the round-trip
      decoded = dkjson.decode prettier {moduleName: "ffi", [2]: "json"}
      ut\assertNotNil decoded
      ut\assertEquals decoded.moduleName, "ffi"
      ut\assertEquals decoded["2"], "json"

    encode_prettierKeepsArraysAsArrays: (ut) ->
      -- a plain sequence stays a JSON array, not an object with stringified indices
      decoded = dkjson.decode prettier {"a", "b", "c"}
      ut\assertNotNil decoded
      ut\assertEquals #decoded, 3
      ut\assertEquals decoded[1], "a"
      ut\assertEquals decoded[3], "c"

    encode_prettierPlainObjectRoundTrips: (ut) ->
      decoded = dkjson.decode prettier {name: "x", version: "1.2.3"}
      ut\assertNotNil decoded
      ut\assertEquals decoded.name, "x"
      ut\assertEquals decoded.version, "1.2.3"
  }
