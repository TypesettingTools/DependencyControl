-- Standalone HTTP mock server for DependencyControl's Downloader integration tests.
--
-- Built on pegasus (HTTP) + copas (concurrency). pegasus' own `server\start` serves one
-- connection at a time; running it under copas (as below) is what makes it handle many
-- connections concurrently — the whole point here, since the Downloader's scheduling can only
-- be stressed with several transfers genuinely in flight at once.
--
-- This is MoonScript, but it's launched in a *fresh* interpreter, so MockHttpServerController
-- compiles it to plain Lua first (the spawned process needs no MoonScript). Endpoints serve
-- files from --dir:
--   GET /fast/<name>                      full-speed response (Content-Length)
--   GET /slow/<name>?delay=<ms>&chunk=<n>  chunked response, <n> bytes every <ms> ms
--   GET /status/<code>                    respond with the given HTTP status
--   GET /redirect-to/<path>               302 with a relative Location of /<path>
--   GET /__quit                           stop the server (the clean shutdown route)
--
-- Flags: --port <n> (loopback port to listen on), --dir <d>, --max-lifetime <s> (orphan
-- safety, default 120), --check (verify deps load, then exit 0/1 without starting a server).

-- "--flag value" / "--flag" parser (a flag with no following value is a boolean)

CONTENT_TYPE_HEADER_NAME = "Content-Type"
MIME_TYPE_BINARY = "application/octet-stream"
LOCALHOST_IP = "127.0.0.1"

parseArgs = (argv) ->
  opts, i = {}, 1
  while argv[i]
    flag = argv[i]\match "^%-%-(.+)$"
    if flag
      value = argv[i + 1]
      if value and not value\match "^%-%-"
        opts[flag], i = value, i + 2
      else
        opts[flag], i = true, i + 1
    else
      i += 1
  opts

opts = parseArgs arg or {}

-- --check: confirm the server's dependencies are installed, then exit. Lets the integration
-- tests gate themselves on "can we actually launch the server here?" without an env var.
depsOk = pcall ->
  require "socket"
  require "copas"
  require "pegasus.handler"

if opts.check
  os.exit depsOk and 0 or 1
assert depsOk, "mock server dependencies (luasocket, copas, pegasus) are not available"

socket = require "socket"
copas = require "copas"
Handler = require "pegasus.handler"

listenPort = assert tonumber(opts.port), "--port is required"
serveDir = opts.dir or "."
maxLifetime = tonumber(opts["max-lifetime"]) or 120

readFile = (path) ->
  f = io.open path, "rb"
  return nil unless f
  data = f\read "*a"
  f\close!
  data

-- map a request name to a file inside serveDir, rejecting traversal
resolve = (name) ->
  return nil if not name or name == "" or name\find "%.%."
  "#{serveDir}/#{name}"

quitRequested = false

handleRequest = (req, res) ->
  path = req\path!

  if path == "/__quit"
    res\statusCode 200
    res\write "bye"
    quitRequested = true
    return res\close!

  if code = path\match "^/status/(%d+)$"
    res\statusCode tonumber code
    res\write "status #{code}"
    return res\close!

  if target = path\match "^/redirect%-to/(.+)$"
    res\statusCode 302
    res\addHeader "Location", "/#{target}" -- relative, so it also exercises redirect resolution
    res\write "redirecting to /#{target}"
    return res\close!

  if name = path\match "^/fast/(.+)$"
    data = readFile resolve name
    return res\statusCode(404)\write("not found") unless data
    res\statusCode 200
    res\addHeader CONTENT_TYPE_HEADER_NAME, MIME_TYPE_BINARY
    res\write data -- non-streaming: Content-Length, single send
    return res\close!

  if name = path\match "^/slow/(.+)$"
    data = readFile resolve name
    return res\statusCode(404)\write("not found") unless data
    delayMs = tonumber(req.querystring.delay) or 50
    chunk = tonumber(req.querystring.chunk) or 1024
    res\statusCode 200
    res\addHeader CONTENT_TYPE_HEADER_NAME, MIME_TYPE_BINARY
    for i = 1, #data, chunk
      res\write data\sub(i, i + chunk - 1), true -- stayOpen => chunked
      copas.sleep delayMs / 1000 -- yields, so other transfers flow
    return res\close!

  res\statusCode 404
  res\write "unknown endpoint"
  res\close!

-- bind to the loopback port the controller chose for us
server = assert socket.bind LOCALHOST_IP, listenPort

handler = Handler\new handleRequest, serveDir, {}, nil
copas.addserver server, copas.handler (client) -> handler\processRequest listenPort, client

io.stderr\write "mock-http-server listening on #{LOCALHOST_IP}:#{listenPort} (dir=#{serveDir})\n"

-- shut down on the /__quit route, or after max-lifetime so we can never orphan
startedAt = os.time!
copas.addthread ->
  while true
    copas.sleep 0.1
    os.exit 0 if quitRequested or os.time! - startedAt > maxLifetime

copas.loop!
