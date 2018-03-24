Logger = require "l0.DependencyControl.Logger"
Common = require "l0.DependencyControl.Common"
LocationResolver = require "l0.DependencyControl.LocationResolver"

-- ensure lifecycle hooks can be loaded using require
package.path ..= LocationResolver.Directories[LocationResolver.Category.Lifecycle].Base.. "/?.lua;"

class LifecycleHook
  new: (@package, @update, @logger) =>

  postInstall: (version) => true

  postUpdate: (toVersion, fromVersion) => true

  preUninstall: (version) => true
