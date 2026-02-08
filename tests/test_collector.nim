import std/[unittest, json, strutils]
import ../src/tado_exporter/[metrics, collector]

suite "collectWeather":
  test "outside temperature and solar intensity":
    var b = newMetricsBuilder()
    let weather = parseJson("""
    {
      "outsideTemperature": {"celsius": 18.5, "fahrenheit": 65.3, "precision": {"celsius": 0.01}},
      "solarIntensity": {"type": "PERCENTAGE", "percentage": 72.0, "timestamp": "2024-01-01T12:00:00Z"},
      "weatherState": {"type": "CLOUDY_MOSTLY", "value": "CLOUDY_MOSTLY"}
    }
    """)
    b.collectWeather(weather)
    let output = b.output()
    check "tado_temperature_outside_celsius 18.5" in output
    check "tado_solar_intensity_percentage 72" in output

  test "JNull produces no output":
    var b = newMetricsBuilder()
    b.collectWeather(newJNull())
    check b.output() == ""

suite "collectPresence":
  test "HOME presence":
    var b = newMetricsBuilder()
    b.collectPresence(parseJson("""{"presence": "HOME"}"""))
    check "tado_is_resident_present 1" in b.output()

  test "AWAY presence":
    var b = newMetricsBuilder()
    b.collectPresence(parseJson("""{"presence": "AWAY"}"""))
    check "tado_is_resident_present 0" in b.output()

  test "JNull produces no output":
    var b = newMetricsBuilder()
    b.collectPresence(newJNull())
    check b.output() == ""

suite "collectZoneStates":
  test "full zone with all metrics":
    var b = newMetricsBuilder()
    let zones = @[ZoneInfo(id: 1, name: "Living Room", zoneType: "HEATING")]
    let zoneStates = parseJson("""
    {
      "zoneStates": {
        "1": {
          "sensorDataPoints": {
            "insideTemperature": {"celsius": 21.5},
            "humidity": {"percentage": 45.0}
          },
          "setting": {
            "power": "ON",
            "temperature": {"celsius": 22.0}
          },
          "activityDataPoints": {
            "heatingPower": {"percentage": 75.0}
          },
          "openWindowDetected": false
        }
      }
    }
    """)
    b.collectZoneStates(zoneStates, zones, 12345)
    let output = b.output()
    check "tado_temperature_measured_celsius{zone_name=\"Living Room\",zone_id=\"1\",home_id=\"12345\",zone_type=\"HEATING\"} 21.5" in output
    check "tado_temperature_set_celsius{zone_name=\"Living Room\",zone_id=\"1\",home_id=\"12345\",zone_type=\"HEATING\"} 22" in output
    check "tado_humidity_measured_percentage{zone_name=\"Living Room\",zone_id=\"1\",home_id=\"12345\",zone_type=\"HEATING\"} 45" in output
    check "tado_heating_power_percentage{zone_name=\"Living Room\",zone_id=\"1\",home_id=\"12345\",zone_type=\"HEATING\"} 75" in output
    check "tado_is_window_open{zone_name=\"Living Room\",zone_id=\"1\",home_id=\"12345\",zone_type=\"HEATING\"} 0" in output
    check "tado_is_zone_powered{zone_name=\"Living Room\",zone_id=\"1\",home_id=\"12345\",zone_type=\"HEATING\"} 1" in output

  test "window open detected":
    var b = newMetricsBuilder()
    let zones = @[ZoneInfo(id: 2, name: "Bedroom", zoneType: "HEATING")]
    let zoneStates = parseJson("""
    {
      "zoneStates": {
        "2": {
          "sensorDataPoints": {
            "insideTemperature": {"celsius": 19.0},
            "humidity": {"percentage": 50.0}
          },
          "setting": {
            "power": "ON",
            "temperature": {"celsius": 20.0}
          },
          "activityDataPoints": {
            "heatingPower": {"percentage": 0.0}
          },
          "openWindowDetected": true
        }
      }
    }
    """)
    b.collectZoneStates(zoneStates, zones, 12345)
    check "tado_is_window_open{zone_name=\"Bedroom\",zone_id=\"2\",home_id=\"12345\",zone_type=\"HEATING\"} 1" in b.output()

  test "zone powered off":
    var b = newMetricsBuilder()
    let zones = @[ZoneInfo(id: 3, name: "Office", zoneType: "HEATING")]
    let zoneStates = parseJson("""
    {
      "zoneStates": {
        "3": {
          "sensorDataPoints": {
            "insideTemperature": {"celsius": 17.0},
            "humidity": {"percentage": 55.0}
          },
          "setting": {
            "power": "OFF",
            "temperature": {"celsius": 0.0}
          },
          "activityDataPoints": {
            "heatingPower": {"percentage": 0.0}
          },
          "openWindowDetected": false
        }
      }
    }
    """)
    b.collectZoneStates(zoneStates, zones, 12345)
    check "tado_is_zone_powered{zone_name=\"Office\",zone_id=\"3\",home_id=\"12345\",zone_type=\"HEATING\"} 0" in b.output()

  test "unknown zone ID skipped":
    var b = newMetricsBuilder()
    let zones = @[ZoneInfo(id: 1, name: "Living Room", zoneType: "HEATING")]
    let zoneStates = parseJson("""
    {
      "zoneStates": {
        "99": {
          "sensorDataPoints": {
            "insideTemperature": {"celsius": 20.0},
            "humidity": {"percentage": 40.0}
          },
          "setting": {"power": "ON", "temperature": {"celsius": 21.0}},
          "activityDataPoints": {"heatingPower": {"percentage": 50.0}},
          "openWindowDetected": false
        }
      }
    }
    """)
    b.collectZoneStates(zoneStates, zones, 12345)
    check b.output() == ""

  test "JNull produces no output":
    var b = newMetricsBuilder()
    let zones = @[ZoneInfo(id: 1, name: "Test", zoneType: "HEATING")]
    b.collectZoneStates(newJNull(), zones, 12345)
    check b.output() == ""
