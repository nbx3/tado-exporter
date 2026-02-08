import std/[unittest, math, strutils]
import ../src/tado_exporter/metrics

suite "escapeLabel":
  test "no escaping needed":
    check escapeLabel("hello") == "hello"

  test "empty string":
    check escapeLabel("") == ""

  test "escapes backslash":
    check escapeLabel("a\\b") == "a\\\\b"

  test "escapes newline":
    check escapeLabel("a\nb") == "a\\nb"

  test "escapes double quote":
    check escapeLabel("a\"b") == "a\\\"b"

  test "escapes combined special chars":
    check escapeLabel("\\\n\"") == "\\\\\\n\\\""

suite "addGauge":
  test "basic gauge without labels":
    var b = newMetricsBuilder()
    b.addGauge("test_metric", "A test metric", 42.0)
    let output = b.output()
    check "# HELP test_metric A test metric\n" in output
    check "# TYPE test_metric gauge\n" in output
    check "test_metric 42\n" in output

  test "gauge with labels":
    var b = newMetricsBuilder()
    b.addGauge("labeled", "help", 1.0, {"foo": "bar", "baz": "qux"})
    check "labeled{foo=\"bar\",baz=\"qux\"} 1\n" in b.output()

  test "gauge with label escaping":
    var b = newMetricsBuilder()
    b.addGauge("escaped", "help", 1.0, {"key": "val\"ue"})
    check "escaped{key=\"val\\\"ue\"} 1\n" in b.output()

  test "integer value formatting":
    var b = newMetricsBuilder()
    b.addGauge("int_val", "help", 100.0)
    check "int_val 100\n" in b.output()

  test "decimal value formatting":
    var b = newMetricsBuilder()
    b.addGauge("dec_val", "help", 3.14159)
    check "dec_val 3.14159" in b.output()

  test "NaN value":
    var b = newMetricsBuilder()
    b.addGauge("nan_val", "help", NaN)
    check "nan_val NaN\n" in b.output()

  test "positive infinity":
    var b = newMetricsBuilder()
    b.addGauge("inf_val", "help", Inf)
    check "inf_val +Inf\n" in b.output()

  test "negative infinity":
    var b = newMetricsBuilder()
    b.addGauge("neginf_val", "help", NegInf)
    check "neginf_val -Inf\n" in b.output()

  test "zero value":
    var b = newMetricsBuilder()
    b.addGauge("zero_val", "help", 0.0)
    check "zero_val 0\n" in b.output()

  test "declaration deduplication":
    var b = newMetricsBuilder()
    b.addGauge("dup", "help text", 1.0, {"a": "1"})
    b.addGauge("dup", "help text", 2.0, {"a": "2"})
    let output = b.output()
    check output.count("# HELP dup") == 1
    check output.count("# TYPE dup") == 1
    check "dup{a=\"1\"} 1\n" in output
    check "dup{a=\"2\"} 2\n" in output

suite "addCounter":
  test "basic counter":
    var b = newMetricsBuilder()
    b.addCounter("test_counter", "A counter", 100.0)
    let output = b.output()
    check "# TYPE test_counter counter\n" in output
    check "test_counter 100\n" in output

suite "output":
  test "empty builder":
    var b = newMetricsBuilder()
    check b.output() == ""

  test "multiple metrics ordered":
    var b = newMetricsBuilder()
    b.addGauge("metric_a", "help a", 1.0)
    b.addGauge("metric_b", "help b", 2.0)
    let output = b.output()
    check "metric_a 1\n" in output
    check "metric_b 2\n" in output
    check output.find("metric_a") < output.find("metric_b")
