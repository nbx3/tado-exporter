## Authenticated Tado API client.
## Wraps auth module to provide simple GET requests with auto-refresh.

import std/[asyncdispatch, httpclient, json, strformat, strutils, times, logging]
import auth

const
  BaseUrl = "https://my.tado.com/api/v2"
  HopsUrl* = "https://hops.tado.com"

type
  RateLimit* = object
    remaining*: int       ## requests remaining (-1 = unknown)
    exhausted*: bool      ## whether quota is exhausted
    refillInSecs*: int    ## seconds until refill (from t= value)
    refillAt*: float      ## absolute epoch time of refill
    lastUpdated*: float   ## epoch time of last header parse

  TadoClient* = ref object
    auth*: TadoAuth
    rateLimit*: RateLimit

proc newRateLimit*(): RateLimit =
  RateLimit(remaining: -1, exhausted: false, refillInSecs: 0,
            refillAt: 0.0, lastUpdated: 0.0)

proc newTadoClient*(auth: TadoAuth): TadoClient =
  TadoClient(auth: auth, rateLimit: newRateLimit())

proc isRateLimited*(c: TadoClient): bool =
  c.rateLimit.exhausted

proc rateLimitSecsRemaining*(c: TadoClient): int =
  if not c.rateLimit.exhausted: return 0
  let remaining = c.rateLimit.refillAt - epochTime()
  if remaining <= 0: return 0
  return int(remaining)

proc parseRateLimitHeader(c: TadoClient, resp: Response | AsyncResponse) =
  ## Parse the ratelimit response header and update c.rateLimit.
  ## Header format: "perday";r=123 or "perday";r=0;t=123
  let header = resp.headers.getOrDefault("ratelimit")
  if header == "": return

  var remaining = -1
  var refillSecs = 0

  for part in header.split(';'):
    let trimmed = part.strip()
    if trimmed.startsWith("r="):
      try: remaining = parseInt(trimmed[2..^1])
      except ValueError: discard
    elif trimmed.startsWith("t="):
      try: refillSecs = parseInt(trimmed[2..^1])
      except ValueError: discard

  let now = epochTime()
  c.rateLimit.remaining = remaining
  c.rateLimit.exhausted = remaining == 0
  c.rateLimit.refillInSecs = refillSecs
  c.rateLimit.refillAt = if refillSecs > 0: now + float(refillSecs) else: 0.0
  c.rateLimit.lastUpdated = now

  if remaining == 0:
    warn(&"Tado API rate limit exhausted! Refill in {refillSecs}s")
  elif remaining >= 0 and remaining <= 10:
    warn(&"Tado API rate limit low: {remaining} requests remaining")

proc doGet(c: TadoClient, baseUrl, path: string): Future[JsonNode] {.async.} =
  ## Internal GET with automatic token management and 401 retry.
  let token = await c.auth.getAccessToken()

  let client = newAsyncHttpClient()
  defer: client.close()

  let url = &"{baseUrl}{path}"
  let headers = newHttpHeaders({
    "Authorization": &"Bearer {token}",
  })

  var resp = await client.request(url, httpMethod = HttpGet, headers = headers)
  var body = await resp.body
  c.parseRateLimitHeader(resp)

  # Re-auth on 401
  if resp.code == Http401:
    debug("Got 401, refreshing token...")
    await c.auth.refreshToken()
    let newToken = await c.auth.getAccessToken()

    let retryClient = newAsyncHttpClient()
    defer: retryClient.close()

    let retryHeaders = newHttpHeaders({
      "Authorization": &"Bearer {newToken}",
    })
    resp = await retryClient.request(url, httpMethod = HttpGet, headers = retryHeaders)
    body = await resp.body
    c.parseRateLimitHeader(resp)

  if resp.code != Http200:
    error(&"API request failed: {path} — HTTP {resp.code}")
    raise newException(IOError, &"API request failed: {path} — HTTP {resp.code}")

  result = parseJson(body)

proc get*(c: TadoClient, path: string): Future[JsonNode] {.async.} =
  ## GET request to the classic Tado API (my.tado.com).
  result = await c.doGet(BaseUrl, path)

proc getHops*(c: TadoClient, path: string): Future[JsonNode] {.async.} =
  ## GET request to the Tado X HOPS API (hops.tado.com).
  result = await c.doGet(HopsUrl, path)
