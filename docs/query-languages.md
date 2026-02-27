# Query Language Reference: PromQL, LogQL, TraceQL

A hands-on guide to querying metrics, logs, and traces in this observability stack. Every query below uses metrics, labels, and services that actually exist in this cluster.

## Where to Run Each Query

| Language | Data Source | Where to Run |
|----------|------------|--------------|
| PromQL | Prometheus | Prometheus UI (`localhost:9090`) or Grafana Explore (`localhost:3000`, select "Prometheus") |
| LogQL | Loki | Grafana Explore (`localhost:3000`, select "Loki") |
| TraceQL | Tempo | Grafana Explore (`localhost:3000`, select "Tempo") |

**Services deployed in this cluster** (namespace `boutique`): frontend, checkoutservice, cartservice, productcatalogservice, currencyservice, shippingservice, paymentservice, emailservice, adservice, recommendationservice, redis-cart, loadgenerator.

**Observability stack** (namespace `monitoring`): Prometheus, Grafana, Loki, Tempo, kube-state-metrics, node-exporter.

---

## 1. PromQL (Prometheus)

PromQL queries Prometheus time-series data. Each time series is identified by a metric name and a set of key-value labels.

### Instant Vectors vs Range Vectors

An **instant vector** returns the most recent value for each matching time series:

```promql
kube_pod_info
```

A **range vector** returns all samples within a time window -- required by functions like `rate()`:

```promql
kube_pod_info[5m]
```

You cannot graph a range vector directly. Wrap it in a function (like `rate()` or `count_over_time()`) to collapse it back to an instant vector.

### Label Selectors

Filter time series by label values. Four matchers are available:

| Operator | Meaning | Example |
|----------|---------|---------|
| `=` | Exact match | `{namespace="boutique"}` |
| `!=` | Not equal | `{namespace!="kube-system"}` |
| `=~` | Regex match | `{pod=~"frontend.*"}` |
| `!~` | Regex exclusion | `{container!~"POD\|"}` |

Examples from this cluster:

```promql
-- All pods in the boutique namespace
kube_pod_info{namespace="boutique"}

-- All pods except kube-system
kube_pod_info{namespace!="kube-system"}

-- Pods matching a pattern
kube_pod_info{namespace="boutique", pod=~"checkout.*"}
```

### rate() -- Computing Per-Second Rates

`rate()` calculates the per-second average rate of increase of a counter over a range window. This is the most common function you'll use.

**CPU usage per pod in the boutique namespace:**

```promql
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="boutique", container!="", container!="POD"}[5m])
)
```

**Request rate per service** (from Tempo service graph metrics):

```promql
sum by (service) (
  rate(traces_service_graph_request_total{service=~"frontend|checkoutservice"}[5m])
)
```

**Pod restart rate:**

```promql
increase(kube_pod_container_status_restarts_total[5m])
```

`increase()` is syntactic sugar for `rate() * range_seconds` -- it returns the total increase over the window instead of a per-second rate.

### Aggregation Operators

Collapse multiple time series into fewer series using aggregation.

**Count pods per namespace:**

```promql
sum by (namespace) (kube_pod_info)
```

**Total running pods across the cluster:**

```promql
sum(kube_pod_status_phase{phase="Running"})
```

**Pods in a non-running state:**

```promql
sum(kube_pod_status_phase{phase=~"Pending|Failed|Unknown"})
```

**Node count:**

```promql
count(kube_node_info)
```

Common aggregation operators: `sum`, `avg`, `min`, `max`, `count`, `topk`, `bottomk`, `quantile`.

The `by` clause keeps specified labels; `without` drops specified labels and keeps the rest.

### histogram_quantile() -- Latency Percentiles

Histograms store observations in buckets. Use `histogram_quantile()` to compute percentiles from `_bucket` metrics.

**p50 latency by service:**

```promql
histogram_quantile(0.50,
  sum by (le, service) (
    rate(traces_service_graph_request_server_seconds_bucket{service=~"frontend|checkoutservice"}[5m])
  )
)
```

**p90 latency by service:**

```promql
histogram_quantile(0.90,
  sum by (le, service) (
    rate(traces_service_graph_request_server_seconds_bucket[5m])
  )
)
```

**p99 latency by service:**

```promql
histogram_quantile(0.99,
  sum by (le, service) (
    rate(traces_service_graph_request_server_seconds_bucket[5m])
  )
)
```

The `le` (less-than-or-equal) label must always be preserved in the `by` clause -- it identifies the histogram buckets.

### Binary Operators and Error Rates

Divide two instant vectors to compute ratios. Labels must match on both sides.

**Error rate per service** (failed requests / total requests):

```promql
sum by (service) (rate(traces_service_graph_request_failed_total[5m]))
/
sum by (service) (rate(traces_service_graph_request_total[5m]))
```

**Error rate per service-to-service edge:**

```promql
sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))
/
sum by (client, server) (rate(traces_service_graph_request_total[5m]))
```

**CPU requests vs capacity** (cluster-wide):

```promql
sum(kube_pod_container_resource_requests{resource="cpu"})
/
sum(kube_node_status_allocatable{resource="cpu"})
```

**Memory requests vs capacity:**

```promql
sum(kube_pod_container_resource_requests{resource="memory"})
/
sum(kube_node_status_allocatable{resource="memory"})
```

### Common Patterns

These patterns appear in the dashboards and alert rules deployed in this stack.

**CPU utilization by node** (percentage):

```promql
1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

**Memory utilization by node** (percentage):

```promql
1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

**Disk usage** (percentage):

```promql
1 - (
  node_filesystem_avail_bytes{mountpoint="/", fstype!="tmpfs"}
  /
  node_filesystem_size_bytes{mountpoint="/", fstype!="tmpfs"}
)
```

**Network throughput** (bits/sec received):

```promql
rate(node_network_receive_bytes_total{device!~"lo|veth.*|docker.*|flannel.*|cali.*|cbr.*"}[5m]) * 8
```

**Pod crash looping** (alert rule -- fires when restarts exceed 3 in 5 minutes):

```promql
increase(kube_pod_container_status_restarts_total[5m]) > 3
```

**Node not ready** (alert rule):

```promql
kube_node_status_condition{condition="Ready", status="true"} == 0
```

**Container CPU usage vs limits** (useful for spotting throttling):

```promql
sum by (container) (
  rate(container_cpu_usage_seconds_total{namespace="boutique", pod=~"frontend.*", container!="", container!="POD"}[5m])
)
/
sum by (container) (
  kube_pod_container_resource_limits{namespace="boutique", pod=~"frontend.*", resource="cpu"}
)
```

**Container memory usage vs limits:**

```promql
sum by (container) (
  container_memory_working_set_bytes{namespace="boutique", pod=~"frontend.*", container!="", container!="POD"}
)
/
sum by (container) (
  kube_pod_container_resource_limits{namespace="boutique", pod=~"frontend.*", resource="memory"}
)
```

---

## 2. LogQL (Loki)

LogQL queries log streams stored in Loki. A query has two parts: a **stream selector** (which logs to fetch) and optional **pipeline stages** (how to filter and transform them).

### Stream Selectors

Stream selectors use the same label matcher syntax as PromQL. Labels are assigned to log streams at ingestion time.

```logql
{namespace="boutique"}
```

```logql
{namespace="boutique", pod=~"frontend.*"}
```

```logql
{namespace="boutique", pod=~"frontend.*", container=~"server"}
```

Labels available in this stack: `namespace`, `pod`, `container`, `node_name`, `job`, `stream` (stdout/stderr).

### Line Filters

After the stream selector, filter log lines by content. These are fast because they operate on raw text before parsing.

| Operator | Meaning | Example |
|----------|---------|---------|
| `\|=` | Line contains string | `\|= "error"` |
| `!=` | Line does not contain | `!= "health"` |
| `\|~` | Line matches regex | `\|~ "status=[45]\\d{2}"` |
| `!~` | Line does not match regex | `!~ "GET /healthz"` |

**Find error logs from the checkout service, excluding health checks:**

```logql
{namespace="boutique", pod=~"checkoutservice.*"} |= "error" != "healthz"
```

**Find logs mentioning specific HTTP status codes:**

```logql
{namespace="boutique", pod=~"frontend.*"} |~ "status=[45]\\d{2}"
```

### Parser Stages

Parse structured log lines into labels you can filter on.

**JSON logs** (common in Online Boutique services):

```logql
{namespace="boutique", pod=~"frontend.*"} | json
```

After `| json`, fields from the JSON payload become labels. If a log line is `{"level":"error","msg":"connection refused"}`, you get labels `level` and `msg`.

**Logfmt logs:**

```logql
{namespace="monitoring"} | logfmt
```

Parses `key=value key2=value2` formatted lines.

**Regex extraction** (for unstructured logs):

```logql
{namespace="boutique", pod=~"frontend.*"} | regexp `(?P<method>GET|POST|PUT|DELETE) (?P<path>/[^ ]*) (?P<status>\d{3})`
```

### Label Filters After Parsing

Once parsed, filter on extracted labels:

```logql
{namespace="boutique", pod=~"frontend.*"} | json | level="error"
```

```logql
{namespace="boutique", pod=~"frontend.*"} | json | status >= 400
```

```logql
{namespace="boutique"} | json | duration > 500ms
```

Comparison operators work on numbers if the label value is numeric. Supported: `=`, `!=`, `>`, `>=`, `<`, `<=`.

### Metric Queries

LogQL can compute metrics from log streams, turning logs into time series.

**Log volume per pod** (lines per minute):

```logql
sum by (pod) (
  count_over_time({namespace="boutique", pod=~"frontend.*"}[1m])
)
```

**Error log rate:**

```logql
sum by (pod) (
  count_over_time({namespace="boutique"} |= "error" [5m])
)
```

**Log bytes rate** (useful for spotting verbose pods):

```logql
sum by (pod) (
  bytes_rate({namespace="boutique"}[5m])
)
```

**Rate of log lines per second:**

```logql
sum by (pod) (
  rate({namespace="boutique"}[5m])
)
```

### Aggregations

**Top 5 pods by error log volume:**

```logql
topk(5,
  sum by (pod) (
    count_over_time({namespace="boutique"} |= "error" [5m])
  )
)
```

**Total log volume by namespace:**

```logql
sum by (namespace) (
  count_over_time({namespace=~"boutique|monitoring"}[5m])
)
```

### Trace-to-Log Correlation

This stack extracts trace IDs from logs using the regex pattern:

```
(?:traceID|trace_id|TraceId)[=:]\s*(\w+)
```

This matches log lines containing `traceID=abc123`, `trace_id: abc123`, or `TraceId=abc123`.

**Find all logs for a specific trace:**

```logql
{namespace="boutique"} |= "abc123def456"
```

Replace `abc123def456` with an actual trace ID from Tempo. Grafana automates this -- clicking a trace ID in Tempo runs a query like:

```logql
{job="frontend"} |= `<trace-id>`
```

This is configured via the Tempo data source's `tracesToLogsV2` setting, which builds the query:

```
{job="<service.name>"} |= `<traceId>`
```

It uses a time window of -1h to +1h around the span's start time to account for clock skew.

---

## 3. TraceQL (Tempo)

TraceQL queries distributed traces stored in Tempo. It operates on **spans** -- individual operations within a trace.

### Basic Span Selectors

Select spans by resource or span attributes using `{}` syntax:

**All spans from the frontend service:**

```traceql
{resource.service.name="frontend"}
```

**All spans from the checkout service:**

```traceql
{resource.service.name="checkoutservice"}
```

Resource attributes (prefixed `resource.`) describe the service emitting the span. Span attributes (prefixed `span.`) describe the individual operation.

### Span Attribute Filters

**Spans with error status:**

```traceql
{status=error}
```

**Spans slower than 500ms:**

```traceql
{duration>500ms}
```

**Spans slower than 1 second:**

```traceql
{duration>1s}
```

**Spans for a specific HTTP method:**

```traceql
{span.http.method="POST"}
```

**Spans for a specific HTTP route:**

```traceql
{span.http.target="/api/cart"}
```

### Combining Conditions

Use `&&` (AND) and `||` (OR) within a span selector:

**Error spans from the checkout service:**

```traceql
{resource.service.name="checkoutservice" && status=error}
```

**Slow requests to either payment or shipping:**

```traceql
{resource.service.name=~"paymentservice|shippingservice" && duration>500ms}
```

**Error spans or very slow spans from any boutique service:**

```traceql
{resource.service.name=~".*service" && (status=error || duration>2s)}
```

### Structural Queries

Select traces based on parent-child span relationships. This is powerful for understanding call chains.

**Traces where the frontend calls the checkout service:**

```traceql
{resource.service.name="frontend"} >> {resource.service.name="checkoutservice"}
```

`>>` means "is an ancestor of" (any depth). `>` means "is a direct parent of".

**Traces where checkout calls payment and it errors:**

```traceql
{resource.service.name="checkoutservice"} >> {resource.service.name="paymentservice" && status=error}
```

**Traces where frontend eventually calls a slow productcatalog query:**

```traceql
{resource.service.name="frontend"} >> {resource.service.name="productcatalogservice" && duration>200ms}
```

### Scalar Filters (Trace-Level Aggregation)

Apply aggregate conditions to entire traces using pipe expressions.

**Traces with more than 20 spans** (complex call chains):

```traceql
{resource.service.name=~".*"} | count() > 20
```

**Traces where total duration exceeds 5 seconds:**

```traceql
{resource.service.name="frontend"} | avg(duration) > 1s
```

**Traces with more than 3 error spans:**

```traceql
{status=error} | count() > 3
```

### Linking Traces to Logs and Metrics

This stack has three correlation paths configured:

**Trace to Logs (Tempo -> Loki):**
When viewing a trace in Grafana, each span has a "Logs" link that runs:

```logql
{job="<service.name>"} |= `<traceId>`
```

This is configured in the Tempo data source's `tracesToLogsV2` setting with `filterByTraceID=true` and a +/-1h time window.

**Trace to Metrics (Tempo -> Prometheus):**
The Tempo data source has `tracesToMetrics` configured with the Prometheus data source. Tempo's service graph processor generates the `traces_service_graph_request_*` metrics that power the RED dashboards and service dependency map.

Key metrics generated from traces:
- `traces_service_graph_request_total` -- request count by client/server
- `traces_service_graph_request_failed_total` -- failed request count
- `traces_service_graph_request_server_seconds_bucket` -- latency histogram

**Log to Trace (Loki -> Tempo):**
The Loki data source has `derivedFields` configured to extract trace IDs from logs using:

```
(?:traceID|trace_id|TraceId)[=:]\s*(\w+)
```

When Grafana detects a trace ID in a log line, it renders a clickable link that opens the trace in Tempo.

---

## Quick Reference

### PromQL Cheat Sheet

| Pattern | Query |
|---------|-------|
| Pod count by namespace | `sum by (namespace) (kube_pod_info)` |
| CPU usage by pod | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="boutique", container!="", container!="POD"}[5m]))` |
| Memory usage by pod | `sum by (pod) (container_memory_working_set_bytes{namespace="boutique", container!="", container!="POD"})` |
| Request rate by service | `sum by (service) (rate(traces_service_graph_request_total[5m]))` |
| Error rate by service | `sum by (service) (rate(traces_service_graph_request_failed_total[5m])) / sum by (service) (rate(traces_service_graph_request_total[5m]))` |
| p99 latency by service | `histogram_quantile(0.99, sum by (le, service) (rate(traces_service_graph_request_server_seconds_bucket[5m])))` |
| Node CPU % | `1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Pod restarts | `increase(kube_pod_container_status_restarts_total{namespace="boutique"}[5m])` |

### LogQL Cheat Sheet

| Pattern | Query |
|---------|-------|
| All logs from a service | `{namespace="boutique", pod=~"frontend.*"}` |
| Filter by content | `{namespace="boutique"} \|= "error"` |
| Parse JSON and filter | `{namespace="boutique"} \| json \| level="error"` |
| Log volume per pod | `sum by (pod) (count_over_time({namespace="boutique"}[1m]))` |
| Find logs by trace ID | `{namespace="boutique"} \|= "<trace-id>"` |

### TraceQL Cheat Sheet

| Pattern | Query |
|---------|-------|
| Spans from a service | `{resource.service.name="frontend"}` |
| Error spans | `{resource.service.name="checkoutservice" && status=error}` |
| Slow spans | `{resource.service.name="frontend" && duration>500ms}` |
| Call chain | `{resource.service.name="frontend"} >> {resource.service.name="checkoutservice"}` |
| High span count traces | `{status=error} \| count() > 3` |
