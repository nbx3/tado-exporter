# Package
version       = "0.1.0"
author        = "Nick"
description   = "Prometheus exporter for Tado smart thermostats"
license       = "MIT"
srcDir        = "src"
bin           = @["tado_exporter"]

# Dependencies
requires "nim >= 2.0.0"
