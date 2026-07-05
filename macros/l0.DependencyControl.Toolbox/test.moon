UnitTestSuite = require "l0.DependencyControl.UnitTestSuite"

-- Plumbing smoke test for automation-script testing: proves DependencyControl discovers a macro's
-- suite, hands it the script's registered macros and its testExports, and runs it. It checks the
-- wiring only; the Toolbox's dialog-driven behaviour is left for a later, fuller suite.
UnitTestSuite "l0.DependencyControl.Toolbox", (macros, dependencies, testExports, controls) ->
  {
    Plumbing: {
      _description: "Automation-script test wiring: registered macros and testExports reach the suite."

      -- every macro registered through registerMacros is exposed by name, carrying its unhooked process
      receivesRegisteredMacros: (ut) ->
        for name in *{"Install Script", "Update Script", "Uninstall Script", "Manage Feeds", "Macro Configuration"}
          ut\assertNotNil macros[name]
          ut\assertFunction macros[name].process

      -- the script's own internal helpers, passed straight through as testExports
      receivesTestExports: (ut) ->
        ut\assertNotNil testExports
        ut\assertFunction testExports.shortenUrl
        ut\assertFunction testExports.expandUrl
        ut\assertEquals testExports.shortenUrl("https://raw.githubusercontent.com/x/y"), "ghuc://x/y"

      _order: {"receivesRegisteredMacros", "receivesTestExports"}
    }
  }
