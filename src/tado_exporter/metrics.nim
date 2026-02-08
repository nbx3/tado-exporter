## Prometheus text format rendering.
## Builds metric output conforming to the Prometheus exposition format.

import std/[strutils, strformat, math]

type
  MetricsBuilder* = object
    buf: string
    declared: seq[string]  # tracks which metrics have had HELP/TYPE emitted

proc newMetricsBuilder*(): MetricsBuilder =
  MetricsBuilder(buf: "", declared: @[])

proc escapeLabel*(value: string): string =
  ## Escape a label value per Prometheus spec:
  ## backslash → \\, newline → \n, double-quote → \"
  result = value
  result = result.replace("\\", "\\\\")
  result = result.replace("\n", "\\n")
  result = result.replace("\"", "\\\"")

proc formatLabels(labels: openArray[(string, string)]): string =
  if labels.len == 0:
    return ""
  var parts: seq[string]
  for (k, v) in labels:
    parts.add(&"{k}=\"{escapeLabel(v)}\"")
  result = "{" & parts.join(",") & "}"

proc formatValue(value: float): string =
  ## Format a float value per Prometheus exposition format.
  if classify(value) == fcNan:
    return "NaN"
  if classify(value) == fcInf:
    return "+Inf"
  if classify(value) == fcNegInf:
    return "-Inf"
  # Use integer representation when the value is a whole number
  if value == floor(value) and abs(value) < 1e15:
    return $int64(value)
  result = formatFloat(value, ffDecimal, 6).strip(leading = false, trailing = true, chars = {'0'})
  if result.endsWith('.'):
    result.add('0')

proc declareMetric(b: var MetricsBuilder, name, help, metricType: string) =
  if name notin b.declared:
    b.declared.add(name)
    b.buf.add(&"# HELP {name} {help}\n")
    b.buf.add(&"# TYPE {name} {metricType}\n")

proc addGauge*(b: var MetricsBuilder, name, help: string, value: float,
               labels: openArray[(string, string)] = []) =
  b.declareMetric(name, help, "gauge")
  let labelStr = formatLabels(labels)
  let valStr = formatValue(value)
  b.buf.add(&"{name}{labelStr} {valStr}\n")

proc addCounter*(b: var MetricsBuilder, name, help: string, value: float,
                 labels: openArray[(string, string)] = []) =
  b.declareMetric(name, help, "counter")
  let labelStr = formatLabels(labels)
  let valStr = formatValue(value)
  b.buf.add(&"{name}{labelStr} {valStr}\n")

proc output*(b: MetricsBuilder): string =
  b.buf
