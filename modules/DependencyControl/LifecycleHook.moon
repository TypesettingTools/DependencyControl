Logger = require "l0.DependencyControl.Logger"
Common = require "l0.DependencyControl.Common"

-- ensure lifecycle hooks can be loaded using require
package.path ..= aegisub.decode_path("?user/automation/tests") .. "/?.lua;"

class LifecycleHook
  new: (@package, @update, @logger) =>

  postInstall: (version) => true

  postUpdate: (toVersion, fromVersion) => true

  preUninstall: (version) => true
