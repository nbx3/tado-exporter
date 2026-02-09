## Fetches Tado API data and builds Prometheus metrics output.
## Caches zone metadata at startup, polls state/weather/zoneStates periodically.

import std/[asyncdispatch, json, strutils, strformat, times, logging, tables]
import client, metrics

proc safeGet(c: TadoClient, path: string): Future[JsonNode] {.async.} =
  try:
    result = await c.get(path)
  except:
    warn(&"Failed to fetch {path}: {getCurrentExceptionMsg()}")
    result = newJNull()

proc safeGetHops(c: TadoClient, path: string): Future[JsonNode] {.async.} =
  try:
    result = await c.getHops(path)
  except:
    warn(&"Failed to fetch HOPS {path}: {getCurrentExceptionMsg()}")
    result = newJNull()

type
  ZoneInfo* = object
    id*: int
    name*: string
    zoneType*: string

  TadoCollector* = ref object
    client*: TadoClient
    homeId*: int
    zones: seq[ZoneInfo]
    cachedOutput*: string
    lastSuccess*: bool
    authValid*: bool
    isTadoX*: bool

proc newTadoCollector*(client: TadoClient, isTadoX: bool = false): TadoCollector =
  TadoCollector(
    client: client,
    cachedOutput: "",
    lastSuccess: false,
    authValid: true,
    isTadoX: isTadoX,
  )

proc discover*(c: TadoCollector) {.async.} =
  ## Fetch home ID and zone list (called once at startup).
  let me = await c.client.get("/me")
  let homes = me["homes"]
  if homes.len == 0:
    raise newException(IOError, "No homes found in Tado account")
  c.homeId = homes[0]["id"].getInt()
  info(&"Discovered home ID: {c.homeId}")

  c.zones = @[]
  if c.isTadoX:
    let roomsJson = await c.client.getHops(&"/homes/{c.homeId}/rooms")
    for r in roomsJson:
      c.zones.add(ZoneInfo(
        id: r["id"].getInt(),
        name: r["name"].getStr(),
        zoneType: "HEATING",
      ))
    info(&"Discovered {c.zones.len} rooms (Tado X)")
  else:
    let zonesJson = await c.client.get(&"/homes/{c.homeId}/zones")
    for z in zonesJson:
      c.zones.add(ZoneInfo(
        id: z["id"].getInt(),
        name: z["name"].getStr(),
        zoneType: z["type"].getStr(),
      ))
    info(&"Discovered {c.zones.len} zones")
  for z in c.zones:
    info(&"  Zone {z.id}: {z.name} ({z.zoneType})")

proc collectWeather*(b: var MetricsBuilder, weather: JsonNode) =
  if weather.kind == JNull: return
  let temp = weather{"outsideTemperature"}{"celsius"}.getFloat()
  b.addGauge("tado_temperature_outside_celsius",
    "Outside temperature reported by Tado", temp)

  let solar = weather{"solarIntensity"}{"percentage"}.getFloat()
  b.addGauge("tado_solar_intensity_percentage",
    "Solar intensity percentage", solar)

proc collectPresence*(b: var MetricsBuilder, state: JsonNode) =
  if state.kind == JNull: return
  let presence = state{"presence"}.getStr("")
  let isHome = if presence == "HOME": 1.0 else: 0.0
  b.addGauge("tado_is_resident_present",
    "Whether any resident is at home (1=yes, 0=no)", isHome)

proc collectZoneStates*(b: var MetricsBuilder, zoneStates: JsonNode,
                        zones: seq[ZoneInfo], homeId: int) =
  if zoneStates.kind == JNull: return
  let states = zoneStates{"zoneStates"}
  if states.isNil or states.kind != JObject: return

  # Build zone ID -> ZoneInfo lookup
  var zoneMap: Table[string, ZoneInfo]
  for z in zones:
    zoneMap[$z.id] = z

  for zoneIdStr, state in states:
    let zone = zoneMap.getOrDefault(zoneIdStr)
    if zone.name == "":
      continue

    let labels = {
      "zone_name": zone.name,
      "zone_id": zoneIdStr,
      "home_id": $homeId,
      "zone_type": zone.zoneType,
    }

    # Measured temperature
    let measuredTemp = state{"sensorDataPoints"}{"insideTemperature"}{"celsius"}.getFloat()
    b.addGauge("tado_temperature_measured_celsius",
      "Measured inside temperature", measuredTemp, labels)

    # Set temperature
    let setTemp = state{"setting"}{"temperature"}{"celsius"}.getFloat()
    b.addGauge("tado_temperature_set_celsius",
      "Target temperature setting", setTemp, labels)

    # Humidity
    let humidity = state{"sensorDataPoints"}{"humidity"}{"percentage"}.getFloat()
    b.addGauge("tado_humidity_measured_percentage",
      "Measured humidity percentage", humidity, labels)

    # Heating power
    let heatingPower = state{"activityDataPoints"}{"heatingPower"}{"percentage"}.getFloat()
    b.addGauge("tado_heating_power_percentage",
      "Heating power percentage", heatingPower, labels)

    # Window open
    let windowOpen = state{"openWindowDetected"}.getBool(false)
    b.addGauge("tado_is_window_open",
      "Whether an open window is detected (1=yes, 0=no)",
      if windowOpen: 1.0 else: 0.0, labels)

    # Zone powered (setting.power == "ON")
    let power = state{"setting"}{"power"}.getStr("")
    b.addGauge("tado_is_zone_powered",
      "Whether the zone heating is powered on (1=yes, 0=no)",
      if power == "ON": 1.0 else: 0.0, labels)

proc collectRooms*(b: var MetricsBuilder, rooms: JsonNode,
                    zones: seq[ZoneInfo], homeId: int) =
  ## Collect metrics from Tado X HOPS rooms response.
  if rooms.kind != JArray: return

  # Build room ID -> ZoneInfo lookup
  var zoneMap: Table[int, ZoneInfo]
  for z in zones:
    zoneMap[z.id] = z

  for room in rooms:
    let roomId = room{"id"}.getInt(-1)
    if roomId < 0: continue
    let zone = zoneMap.getOrDefault(roomId)
    if zone.name == "": continue

    let labels = {
      "zone_name": zone.name,
      "zone_id": $roomId,
      "home_id": $homeId,
      "zone_type": zone.zoneType,
    }

    # Measured temperature
    let measuredTemp = room{"sensorDataPoints"}{"insideTemperature"}{"value"}.getFloat()
    b.addGauge("tado_temperature_measured_celsius",
      "Measured inside temperature", measuredTemp, labels)

    # Set temperature
    let setTemp = room{"setting"}{"temperature"}{"value"}.getFloat()
    b.addGauge("tado_temperature_set_celsius",
      "Target temperature setting", setTemp, labels)

    # Humidity
    let humidity = room{"sensorDataPoints"}{"humidity"}{"percentage"}.getFloat()
    b.addGauge("tado_humidity_measured_percentage",
      "Measured humidity percentage", humidity, labels)

    # Heating power
    let heatingPower = room{"heatingPower"}{"percentage"}.getFloat()
    b.addGauge("tado_heating_power_percentage",
      "Heating power percentage", heatingPower, labels)

    # Window open
    let windowOpen = room{"openWindow"}{"activated"}.getBool(false)
    b.addGauge("tado_is_window_open",
      "Whether an open window is detected (1=yes, 0=no)",
      if windowOpen: 1.0 else: 0.0, labels)

    # Zone powered (setting.power == "ON")
    let power = room{"setting"}{"power"}.getStr("")
    b.addGauge("tado_is_zone_powered",
      "Whether the zone heating is powered on (1=yes, 0=no)",
      if power == "ON": 1.0 else: 0.0, labels)

proc collectRateLimit*(b: var MetricsBuilder, rl: RateLimit) =
  if rl.lastUpdated == 0.0: return
  b.addGauge("tado_exporter_ratelimit_remaining",
    "Tado API requests remaining in current rate limit window",
    float(rl.remaining))
  b.addGauge("tado_exporter_ratelimit_exhausted",
    "Whether Tado API rate limit is exhausted (1=yes, 0=no)",
    if rl.exhausted: 1.0 else: 0.0)

proc poll*(c: TadoCollector) {.async.} =
  ## Fetch current state and build metrics output.
  let startTime = epochTime()
  var b = newMetricsBuilder()
  debug("Starting metrics collection")

  # Fire off all requests concurrently; each can fail independently
  let
    fState = c.client.safeGet(&"/homes/{c.homeId}/state")
    fWeather = c.client.safeGet(&"/homes/{c.homeId}/weather")

  var success: float
  if c.isTadoX:
    let fRooms = c.client.safeGetHops(&"/homes/{c.homeId}/rooms")
    let
      state = await fState
      weather = await fWeather
      rooms = await fRooms
    b.collectPresence(state)
    b.collectWeather(weather)
    b.collectRooms(rooms, c.zones, c.homeId)
    b.collectRateLimit(c.client.rateLimit)
    success = if state.kind != JNull and weather.kind != JNull and rooms.kind != JNull: 1.0 else: 0.0
  else:
    let fZoneStates = c.client.safeGet(&"/homes/{c.homeId}/zoneStates")
    let
      state = await fState
      weather = await fWeather
      zoneStates = await fZoneStates
    b.collectPresence(state)
    b.collectWeather(weather)
    b.collectZoneStates(zoneStates, c.zones, c.homeId)
    b.collectRateLimit(c.client.rateLimit)
    success = if state.kind != JNull and weather.kind != JNull and zoneStates.kind != JNull: 1.0 else: 0.0
  if success == 1.0:
    c.authValid = true

  let duration = epochTime() - startTime
  if success == 1.0:
    info(&"Scrape completed in {duration:.3f}s")
  else:
    warn(&"Scrape completed with errors in {duration:.3f}s")

  b.addGauge("tado_exporter_scrape_duration_seconds",
    "Time taken to collect Tado metrics", duration)
  b.addGauge("tado_exporter_scrape_success",
    "Whether last collection succeeded (1/0)", success)
  b.addGauge("tado_exporter_authentication_valid",
    "Whether authentication is valid (1/0)",
    if c.authValid: 1.0 else: 0.0)

  c.cachedOutput = b.output()
  c.lastSuccess = success == 1.0
