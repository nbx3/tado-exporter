## Tado Prometheus Exporter — exports Tado smart thermostat metrics.
## Configured via environment variables, serves Prometheus metrics on /metrics.
## Uses background polling to decouple scrape frequency from API rate limits.

import std/[asyncdispatch, asynchttpserver, os, strutils, strformat, logging]
import tado_exporter/[auth, client, collector]

const Version {.strdefine.} = "dev"

const
  MinPollInterval = 300  # 5 minute safety floor

type
  Config = object
    port: int
    tokenPath: string
    pollInterval: int  # seconds

proc loadConfig(): Config =
  var interval = getEnv("TADO_POLL_INTERVAL", "2700").parseInt()
  if interval < MinPollInterval:
    warn(&"TADO_POLL_INTERVAL={interval}s is below minimum {MinPollInterval}s, clamping")
    interval = MinPollInterval

  Config(
    port: getEnv("TADO_PORT", "9617").parseInt(),
    tokenPath: getEnv("TADO_TOKEN_PATH", "/data/tado-token.json"),
    pollInterval: interval,
  )

const landingPage = """<!DOCTYPE html>
<html><head><title>Tado Exporter</title></head>
<body><h1>Tado Exporter</h1><p><a href="/metrics">Metrics</a></p></body>
</html>"""

proc backgroundPoller(c: TadoCollector, intervalSecs: int) {.async.} =
  ## Poll Tado API in the background at the configured interval.
  ## Pauses polling when the Tado API rate limit is exhausted.
  while true:
    # Check rate limit before polling
    if c.client.isRateLimited():
      let waitSecs = c.client.rateLimitSecsRemaining()
      if waitSecs > 0:
        warn(&"Rate limit exhausted, sleeping {waitSecs}s until refill")
        await sleepAsync(waitSecs * 1000)
        continue

    try:
      await c.poll()
      let rl = c.client.rateLimit
      if rl.remaining >= 0:
        debug(&"Poll completed, {rl.remaining} API requests remaining today")
      else:
        debug("Poll completed successfully")
    except:
      warn(&"Background poll failed: {getCurrentExceptionMsg()}")
    await sleepAsync(intervalSecs * 1000)

proc main() {.async.} =
  let levelStr = getEnv("LOG_LEVEL", "INFO").toUpperAscii()
  let level = case levelStr
    of "DEBUG": lvlDebug
    of "INFO": lvlInfo
    of "WARN", "WARNING": lvlWarn
    of "ERROR": lvlError
    of "FATAL": lvlFatal
    of "NONE": lvlNone
    else: lvlInfo
  let logger = newConsoleLogger(level, fmtStr = "$datetime $levelname ")
  addHandler(logger)

  let cfg = loadConfig()
  info(&"Tado Exporter {Version} starting")
  info(&"  Port: {cfg.port}")
  info(&"  Token path: {cfg.tokenPath}")
  info(&"  Poll interval: {cfg.pollInterval}s")

  # Initialize auth
  let tadoAuth = newTadoAuth(cfg.tokenPath)
  await tadoAuth.initAuth()

  # Create client and collector
  let tadoClient = newTadoClient(tadoAuth)
  let tadoCollector = newTadoCollector(tadoClient)

  # Discover home and zones
  await tadoCollector.discover()

  # Do initial poll before starting server
  await tadoCollector.poll()
  info("Initial poll completed")

  # Start background poller
  asyncCheck backgroundPoller(tadoCollector, cfg.pollInterval)

  # HTTP server
  var server = newAsyncHttpServer()

  proc handler(req: Request) {.async.} =
    debug(&"{req.reqMethod} {req.url.path}")
    try:
      case req.url.path
      of "/metrics":
        await req.respond(Http200, tadoCollector.cachedOutput,
          newHttpHeaders({"Content-Type": "text/plain; version=0.0.4; charset=utf-8"}))
      of "/health":
        if tadoCollector.lastSuccess:
          await req.respond(Http200, "OK")
        else:
          await req.respond(Http503, "Last poll failed")
      of "/":
        await req.respond(Http200, landingPage,
          newHttpHeaders({"Content-Type": "text/html"}))
      else:
        warn(&"404 {req.reqMethod} {req.url.path}")
        await req.respond(Http404, "Not Found")
    except:
      error(&"Error handling {req.reqMethod} {req.url.path}: {getCurrentExceptionMsg()}")
      try:
        await req.respond(Http500, "Internal Server Error")
      except:
        error(&"Failed to send error response: {getCurrentExceptionMsg()}")

  info(&"Listening on :{cfg.port}")
  server.listen(Port(cfg.port))
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handler)
    else:
      await sleepAsync(500)

when isMainModule:
  waitFor main()
