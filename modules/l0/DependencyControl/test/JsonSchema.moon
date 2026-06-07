-- JsonSchema tests: schema discovery and multi-version validation orchestration. These avoid the
-- actual lua-schema dependency by stubbing FileOps and passing pre-built (mock) schema instances.
-- Called from test.moon as: (require "...test.JsonSchema") basePath
(basePath) ->
  JsonSchema = require "l0.DependencyControl.JsonSchema"
  FILEOPS_MODULE_NAME = "l0.DependencyControl.FileOps"

  -- a stand-in for a JsonSchema instance with a scripted validate(data) result
  mockSchema = (valid, err) -> {__class: JsonSchema, validate: (self, data) -> valid, err}

  {
    _description: "Tests for JsonSchema: getSchemasInDirectory discovery and validateAny orchestration."

    -- getSchemasInDirectory

    getSchemasInDirectory_mapsVersionsToPaths: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "listDir")\returns {"v0.3.0.json", "v0.4.0.json", "readme.txt"}
      (ut\stub FILEOPS_MODULE_NAME, "joinPath")\calls (dir, name) -> "#{dir}/#{name}"
      result = JsonSchema\getSchemasInDirectory "/schemas"
      ut\assertTable result
      ut\assertContains result["0.4.0"], "v0.4.0.json"
      ut\assertContains result["0.3.0"], "v0.3.0.json"
      ut\assertNil result["readme"]

    getSchemasInDirectory_noneFound: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "listDir")\returns {"readme.txt", "notes.md"}
      result, err = JsonSchema\getSchemasInDirectory "/schemas"
      ut\assertNil result
      ut\assertString err

    getSchemasInDirectory_dirReadError: (ut) ->
      (ut\stub FILEOPS_MODULE_NAME, "listDir")\returns nil, "permission denied"
      result, err = JsonSchema\getSchemasInDirectory "/schemas"
      ut\assertNil result
      ut\assertContains err, "permission denied"

    -- validateAny

    validateAny_exactVersionValid: (ut) ->
      isValid, version = JsonSchema\validateAny {}, {"0.4.0": mockSchema true}, "0.4.0"
      ut\assertTrue isValid
      ut\assertEquals version, "0.4.0"

    validateAny_reportsInvalidWithError: (ut) ->
      isValid, version, err = JsonSchema\validateAny {}, {"0.4.0": mockSchema(false, "name must be string")}, "0.4.0"
      ut\assertFalse isValid
      ut\assertEquals version, "0.4.0"
      ut\assertContains err, "name must be string"

    -- with no schema for the feed's declared version, it falls through to the available ones
    validateAny_fallsThroughToOtherVersions: (ut) ->
      isValid, version = JsonSchema\validateAny {}, {"0.3.0": mockSchema true}, "0.4.0"
      ut\assertTrue isValid
      ut\assertEquals version, "0.3.0"

    -- with no schema matching and the others all rejecting, the result is nil with errors aggregated
    -- (a false from the exact declared version is instead returned verbatim — that's a definitive no)
    validateAny_aggregatesAllFailures: (ut) ->
      schemas = {"0.3.0": mockSchema(false, "err A"), "0.2.0": mockSchema(false, "err B")}
      isValid, _, err = JsonSchema\validateAny {}, schemas, "0.4.0"   -- 0.4.0 absent -> falls through
      ut\assertNil isValid
      ut\assertContains err, "err A"
      ut\assertContains err, "err B"

    _order: {
      "getSchemasInDirectory_mapsVersionsToPaths", "getSchemasInDirectory_noneFound",
      "getSchemasInDirectory_dirReadError",
      "validateAny_exactVersionValid", "validateAny_reportsInvalidWithError",
      "validateAny_fallsThroughToOtherVersions", "validateAny_aggregatesAllFailures"
    }
  }
