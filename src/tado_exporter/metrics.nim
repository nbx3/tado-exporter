## Prometheus text format rendering.
## Builds metric output conforming to the Prometheus exposition format.

import std/[strutils, strformat]

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

proc declareMetric(b: var MetricsBuilder, name, help, metricType: string) =
  if name notin b.declared:
    b.declared.add(name)
    b.buf.add(&"# HELP {name} {help}\n")
    b.buf.add(&"# TYPE {name} {metricType}\n")

proc addGauge*(b: var MetricsBuilder, name, help: string, value: float,
               labels: openArray[(string, string)] = []) =
  b.declareMetric(name, help, "gauge")
  let labelStr = formatLabels(labels)
  b.buf.add(&"{name}{labelStr} {value}\n")

proc addCounter*(b: var MetricsBuilder, name, help: string, value: float,
                 labels: openArray[(string, string)] = []) =
  b.declareMetric(name, help, "counter")
  let labelStr = formatLabels(labels)
  b.buf.add(&"{name}{labelStr} {value}\n")

proc output*(b: MetricsBuilder): string =
  b.buf
