VersionRecord = require "l0.DependencyControl.VersionRecord"

class DummyRecord extends VersionRecord
  msgs = {
      new: {
          badRecordError: "Error: Bad DependencyControl dummy record (%s)."
      }
  }

  new: (args) =>
    success, errMsg = @__import args, false
    @@logger\assert success, msgs.new.badRecordError, errMsg
    @virtual = true