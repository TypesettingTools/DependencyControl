-- Controls a mock HTTP server subprocess for the Downloader integration tests.
--
-- Safe to require anywhere (including Aegisub): loading it only defines the class. luasocket is
-- pulled in lazily, when a server is actually started/stopped. The server itself runs in a
-- separate process (await blocks, so it can't share our thread); we compile mock-http-server.moon
-- to plain Lua up front so that process needs only a bare interpreter, no MoonScript.

ffi = require "ffi"
moonbase = require "moonscript.base"
FileOps = require "l0.DependencyControl.FileOps"

MOCK_SERVER_FILE_BASENAME = "mock-http-server"

isWindows = ffi.os == "Windows"
interpreter = (arg and arg[-1]) or "luajit" -- run the server under the interpreter running us

-- mock-http-server.moon sits next to this file; locate it from our own source path.
_, device, dir = FileOps.validateFullPath debug.getinfo(1, "S").source\gsub("^@", ""), true
serverSourcePath = FileOps.joinPath "#{device}#{dir}", "#{MOCK_SERVER_FILE_BASENAME}.moon"

quote = (s) -> "\"#{tostring(s)}\""

spawnDetached = (cmd) ->
  os.execute isWindows and "start \"\" /b #{cmd}" or "#{cmd} >/dev/null 2>&1 &"

-- os.execute on Windows mis-parses a command that begins with a quote unless the whole command
-- is wrapped in one more pair of quotes (cmd /c then strips the outer pair).
runBlocking = (cmd) -> os.execute isWindows and quote(cmd) or cmd

class MockHttpServerController
  -- Compile mock-http-server.moon to a throwaway .lua once and cache the path.
  @compileServer = =>
    return @compiledServerPath if @compiledServerPath

    serverSource = assert FileOps.readFile serverSourcePath
    compiledServerLua = assert moonbase.to_lua serverSource
    tempDir = assert FileOps.createTempDir!
    path = FileOps.joinPath tempDir, "#{MOCK_SERVER_FILE_BASENAME}.lua"
    assert FileOps.writeFile path, compiledServerLua
    @compiledServerPath, @compiledServerTempDir = path, tempDir
    return @compiledServerPath

  --- Whether the server can be launched here, i.e. its Lua dependencies (luasocket, copas,
  --- pegasus) are installed. Spawns the server with --check, which loads the deps and exits
  --- 0/1 without serving — so this needs no luasocket in our own process.
  @isReady: =>
    success, errMsg = pcall @compileServer, @
    return false, "mock server compilation failed: #{errMsg}" unless success
    return true if runBlocking("#{quote interpreter} #{quote @compiledServerPath} --check")
    return false, "mock server dependencies (luasocket/copas/pegasus) not available"

  --- @param[opt] opts table: dir (directory whose files to serve), maxLifetime (server
  --- self-destruct timeout in seconds), timeout (readiness wait in seconds)
  new: (opts = {}) =>
    @serveDir = opts.serveDir or "."
    @maxLifetime = opts.maxLifetime or 120
    @timeout = opts.timeout or 10

  --- Picks a free loopback port, starts the server on it and waits until it's listening.
  -- @return self
  start: =>
    socket = require "socket"
    -- Grab a free port by binding to 0, then hand it to the server via --port. (Tiny race
    -- between closing and the server re-binding, but it's loopback and a throwaway server.)
    probe = assert socket.bind "127.0.0.1", 0
    _, port = probe\getsockname!
    probe\close!
    @port, @baseUrl = port, "http://127.0.0.1:#{port}"

    startCommand = table.concat {
      quote(interpreter), quote(@@compileServer!),
      "--port", tostring(port),
      "--dir", quote(@serveDir),
      "--max-lifetime", tostring(@maxLifetime),
    }, " "
    io.stderr\write "Starting mock HTTP server with command: #{startCommand}...\n"
    spawnDetached startCommand

    -- Ready only once the server actually answers HTTP. A bare TCP connect succeeds as
    -- soon as the kernel accepts into the listen backlog (which can happen before copas
    -- starts dispatching requests).
    isServing = ->
      conn = socket.tcp!
      conn\settimeout 0.5
      unless conn\connect "127.0.0.1", port
        conn\close!
        return false
      conn\send "GET /status/200 HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n"
      statusLine = conn\receive "*l"
      conn\close!
      return statusLine != nil and statusLine\match("^HTTP/") != nil

    deadline = socket.gettime! + @timeout
    while socket.gettime! < deadline
      return @ if isServing!
      socket.sleep 0.05
    error "mock HTTP server didn't start on port #{port} within #{@timeout}s"

  --- Stops the server via its /__quit route. Best-effort: if luasocket isn't available here,
  --- the server's max-lifetime cleans it up regardless.
  stop: =>
    return unless @port
    pcall ->
      socket = require "socket"
      conn = socket.tcp!
      conn\settimeout 2
      if conn\connect "127.0.0.1", @port
        conn\send "GET /__quit HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n"
        conn\receive "*a" -- wait for the response / server exit
      conn\close!
    @port, @baseUrl = nil, nil
