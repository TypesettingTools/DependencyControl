-- RNG seed divergence across isolated Lua states, replicating Aegisub loading one DependencyControl copy
-- per automation script simultaneously: each spawned luajit child seeds through the real Logger
-- construction and reports the head of its random stream, which must be unique per state — this is what
-- keeps per-script log file names and temp paths from colliding.
-- Self-gating via _condition: skipped where a luajit child process can't be spawned.
-- Called from Tests.moon as: (require "...test.integration.Logger") basePath
(basePath) ->
  FileOps = require "l0.DependencyControl.FileOps"

  STATE_COUNT = 50

  -- The probe a child state runs: bootstrap the parent's module paths, load the headless shim, construct
  -- a Logger (which seeds the state's rng), and print the head of the resulting random stream.
  buildProbeSource = ->
    table.concat {
      ("package.path = %q")\format package.path
      ("package.cpath = %q")\format package.cpath
      'require "moonscript"'
      'require "l0.AegisubShims.aegisub"'
      'local Logger = require "l0.DependencyControl.Logger"'
      'Logger{fileBaseName = "seedProbe"}'
      'io.write(("%04x%04x%04x"):format(math.random(0, 0xFFFF), math.random(0, 0xFFFF), math.random(0, 0xFFFF)))'
    }, "\n"

  {
    _description: "Logger rng seeding: simultaneously created Lua states get distinct random streams (runs where a luajit child can be spawned)."

    _condition: ->
      ok, handle = pcall io.popen, 'luajit -e "io.write(_VERSION)"'
      return false, "io.popen unavailable (#{tostring handle})" unless ok and handle
      out = handle\read "*a"
      handle\close!
      return false, "no runnable luajit on PATH" unless out and #out > 0
      return true

    isolatedStates_getDistinctRandomStreams: (ut) ->
      FileOps.mkdir basePath, false, true
      probePath = FileOps.joinPath basePath, "logger-seed-probe.lua"
      ut\assertTruthy FileOps.writeFile probePath, buildProbeSource!

      -- spawn every child before reading any, so their module loads and seedings overlap in time
      handles = [io.popen "luajit \"#{probePath}\" 2>&1" for _ = 1, STATE_COUNT]
      streams = for handle in *handles
        out = handle\read "*a"
        handle\close!
        out

      unique = {}
      for stream in *streams
        -- a failed child prints an error dump instead of hex; the mismatch surfaces it verbatim
        ut\assertEquals stream\match("^%x+$"), stream
        unique[stream] = true
      count = 0
      count += 1 for _ in pairs unique
      ut\assertEquals count, STATE_COUNT
  }
