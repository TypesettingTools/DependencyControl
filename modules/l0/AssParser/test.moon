UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"

return UnitTestSuite "l0.AssParser", (DepCtrl, ...) ->
  -- The suite controls object is appended by UnitTestSuite\import as the final argument.
  -- Its index varies by loader (CLI vs Aegisub pass different arg counts), so grab the last one.
  nArgs = select "#", ...
  controls = select nArgs, ...

  -- Each test class lives in its own sibling module under `test/`, loaded via the suite's requireTest
  -- helper so the same call resolves in both the Aegisub-default and custom (CI) test locations.
  {
    Ass: (controls\requireTest "ass")!
    AssFile: (controls\requireTest "ass-file")!
    OverrideTags: (controls\requireTest "override-tags") controls\requireTest "ass-corpus"
    Karaoke: (controls\requireTest "karaoke")!
    Diagnostics: (controls\requireTest "diagnostics")!
    Normalize: (controls\requireTest "normalize")!
  }
