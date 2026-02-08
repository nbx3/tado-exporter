## OAuth2 device code flow for Tado API.
## Handles initial authorization, token persistence, and refresh.

import std/[asyncdispatch, httpclient, json, strformat, strutils, logging, os, times]

const
  ClientId = "1bb50063-6b0c-4d11-bd99-387f4a91cc46"
  DeviceAuthorizeUrl = "https://login.tado.com/oauth2/device_authorize"
  TokenUrl = "https://login.tado.com/oauth2/token"

type
  TokenData* = object
    accessToken*: string
    refreshToken*: string
    expiresAt*: float  # Unix timestamp

  TadoAuth* = ref object
    tokenPath*: string
    clientId: string
    token*: TokenData

proc newTadoAuth*(tokenPath: string): TadoAuth =
  TadoAuth(
    tokenPath: tokenPath,
    clientId: ClientId,
    token: TokenData(),
  )

proc saveToken*(auth: TadoAuth) =
  let j = %*{
    "access_token": auth.token.accessToken,
    "refresh_token": auth.token.refreshToken,
    "expires_at": auth.token.expiresAt,
  }
  let dir = parentDir(auth.tokenPath)
  if dir != "" and not dirExists(dir):
    createDir(dir)
  writeFile(auth.tokenPath, $j)
  debug("Token saved to ", auth.tokenPath)

proc loadToken*(auth: TadoAuth): bool =
  if not fileExists(auth.tokenPath):
    return false
  try:
    let j = parseJson(readFile(auth.tokenPath))
    auth.token = TokenData(
      accessToken: j{"access_token"}.getStr(),
      refreshToken: j{"refresh_token"}.getStr(),
      expiresAt: j{"expires_at"}.getFloat(),
    )
    if auth.token.refreshToken == "":
      return false
    info("Loaded token from ", auth.tokenPath)
    return true
  except:
    warn(&"Failed to load token: {getCurrentExceptionMsg()}")
    return false

proc refreshToken*(auth: TadoAuth) {.async.} =
  ## Refresh the access token using the refresh token.
  let client = newAsyncHttpClient()
  defer: client.close()

  let body = &"grant_type=refresh_token&client_id={auth.clientId}&refresh_token={auth.token.refreshToken}"
  let resp = await client.request(TokenUrl, httpMethod = HttpPost,
    body = body,
    headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"}))
  let respBody = await resp.body

  if resp.code != Http200:
    raise newException(IOError, &"Token refresh failed: HTTP {resp.code} - {respBody}")

  let j = parseJson(respBody)
  auth.token = TokenData(
    accessToken: j["access_token"].getStr(),
    refreshToken: j{"refresh_token"}.getStr(auth.token.refreshToken),
    expiresAt: epochTime() + j["expires_in"].getFloat() - 30,
  )
  auth.saveToken()
  info("Token refreshed successfully")

proc deviceCodeFlow*(auth: TadoAuth) {.async.} =
  ## Run the OAuth2 device code flow for initial authorization.
  let client = newAsyncHttpClient()
  defer: client.close()

  # Step 1: Request device code
  let body = &"client_id={auth.clientId}&scope=home.user"
  let resp = await client.request(DeviceAuthorizeUrl, httpMethod = HttpPost,
    body = body,
    headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"}))
  let respBody = await resp.body

  if resp.code != Http200:
    raise newException(IOError, &"Device authorize failed: HTTP {resp.code} - {respBody}")

  let j = parseJson(respBody)
  let deviceCode = j["device_code"].getStr()
  let userCode = j["user_code"].getStr()
  let verificationUri = j["verification_uri_complete"].getStr(
    j["verification_uri"].getStr() & "?user_code=" & userCode)
  let interval = j{"interval"}.getInt(5)

  echo ""
  echo "=== Tado Authorization Required ==="
  echo &"Visit: {verificationUri}"
  echo &"Code:  {userCode}"
  echo "Waiting for authorization..."
  echo ""

  # Step 2: Poll for token
  while true:
    await sleepAsync(interval * 1000)

    let pollClient = newAsyncHttpClient()
    defer: pollClient.close()

    let pollBody = &"grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id={auth.clientId}&device_code={deviceCode}"
    let pollResp = await pollClient.request(TokenUrl, httpMethod = HttpPost,
      body = pollBody,
      headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"}))
    let pollRespBody = await pollResp.body

    if pollResp.code == Http200:
      let tokenJson = parseJson(pollRespBody)
      debug("Token response: ", pollRespBody)
      let refreshTok = tokenJson{"refresh_token"}.getStr("")
      auth.token = TokenData(
        accessToken: tokenJson["access_token"].getStr(),
        refreshToken: refreshTok,
        expiresAt: epochTime() + tokenJson["expires_in"].getFloat() - 30,
      )
      auth.saveToken()
      if refreshTok == "":
        warn("No refresh_token in token response — token refresh will not work")
      info("Device authorization completed successfully")
      return

    let errorJson = parseJson(pollRespBody)
    let error = errorJson{"error"}.getStr("")
    case error
    of "authorization_pending":
      debug("Still waiting for user authorization...")
    of "slow_down":
      debug("Slowing down polling...")
      await sleepAsync(5000)
    of "expired_token":
      raise newException(IOError, "Device code expired. Please restart the exporter to try again.")
    of "access_denied":
      raise newException(IOError, "Authorization was denied by the user.")
    else:
      raise newException(IOError, &"Unexpected error during device flow: {error} - {pollRespBody}")

proc initAuth*(auth: TadoAuth) {.async.} =
  ## Initialize authentication: load existing token or run device flow.
  if auth.loadToken():
    # Check if token needs refresh
    if epochTime() >= auth.token.expiresAt:
      info("Token expired, refreshing...")
      await auth.refreshToken()
  else:
    info("No token found, starting device authorization flow...")
    await auth.deviceCodeFlow()

proc getAccessToken*(auth: TadoAuth): Future[string] {.async.} =
  ## Return a valid access token, refreshing if needed.
  if epochTime() >= auth.token.expiresAt:
    await auth.refreshToken()
  return auth.token.accessToken

proc isAuthenticated*(auth: TadoAuth): bool =
  auth.token.accessToken != "" and auth.token.refreshToken != ""
