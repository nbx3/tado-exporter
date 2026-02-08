## Authenticated Tado API client.
## Wraps auth module to provide simple GET requests with auto-refresh.

import std/[asyncdispatch, httpclient, json, strformat, logging]
import auth

const
  BaseUrl = "https://my.tado.com/api/v2"

type
  TadoClient* = ref object
    auth*: TadoAuth

proc newTadoClient*(auth: TadoAuth): TadoClient =
  TadoClient(auth: auth)

proc get*(c: TadoClient, path: string): Future[JsonNode] {.async.} =
  ## GET request to the Tado API with automatic token management.
  ## Re-attempts with a fresh token on 401.
  let token = await c.auth.getAccessToken()

  let client = newAsyncHttpClient()
  defer: client.close()

  let url = &"{BaseUrl}{path}"
  let headers = newHttpHeaders({
    "Authorization": &"Bearer {token}",
  })

  var resp = await client.request(url, httpMethod = HttpGet, headers = headers)
  var body = await resp.body

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

  if resp.code != Http200:
    raise newException(IOError, &"API request failed: {path} — HTTP {resp.code}")

  result = parseJson(body)
