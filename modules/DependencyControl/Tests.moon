DependencyControl = require "l0.DependencyControl"

DependencyControl.UnitTestSuite "l0.DependencyControl", (DepCtrl) ->
  {
    Common: {
      _description: "Tests for the Common base class providing shared utilities and enums across DependencyControl components."

      capitalizeTerms: (ut) ->
        ut\assertEquals DepCtrl.terms.capitalize("hello world"), "Hello world"
    }
  }
