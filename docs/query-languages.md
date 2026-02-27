# Query Language Reference: PromQL, LogQL, TraceQL

A beginner-friendly guide to querying metrics, logs, and traces. Starts simple, gets progressively deeper. Every query uses real metrics and services from this cluster.

## Where to Run Queries

This stack has two web UIs. Get the URLs by running `terraform output` in the `infra/` directory.

**Prometheus UI** -- a standalone web page with a query box at the top. You type a PromQL query, click Execute, and see results. It has two result views: Table (raw data) and Graph (chart over time).

**Grafana** -- the main dashboards UI. It can query all three data sources. To run ad-hoc queries, click the compass icon ("Explore") in the left sidebar, then pick a data source from the dropdown at the top: Prometheus, Loki, or Tempo.

| Language | What it queries | Where to run it |
|----------|----------------|-----------------|
| PromQL | Metrics (numbers over time) | Prometheus UI or Grafana Explore (select "Prometheus") |
| LogQL | Logs (text lines) | Grafana Explore (select "Loki") |
| TraceQL | Traces (request flows across services) | Grafana Explore (select "Tempo") |

**Services in this cluster** (namespace `boutique`): frontend, checkoutservice, cartservice, productcatalogservice, currencyservice, shippingservice, paymentservice, emailservice, adservice, recommendationservice, redis-cart, loadgenerator.

**Observability stack** (namespace `monitoring`): Prometheus, Grafana, Loki, Tempo, kube-state-metrics, node-exporter.

---

## 1. PromQL (Prometheus Query Language)

Prometheus collects numbers (metrics) from your cluster every few seconds and stores them as time series. Each time series has a name and a set of labels (key-value pairs that identify what the metric is about).

### Your First Query

Open the Prometheus UI. Type this in the query box and click Execute:

```promql
kube_pod_info
```

This returns one row per pod in your cluster. Each row shows the metric name, its labels (namespace, pod name, node, etc.), and the current value. This is the simplest possible query -- just a metric name.

### Filtering with Labels

You can narrow results by adding label filters inside curly braces:

```promql
kube_pod_info{namespace="boutique"}
```

This shows only pods in the `boutique` namespace. You can add multiple filters separated by commas:

```promql
kube_pod_info{namespace="boutique", pod=~"checkout.*"}
```

The `=~` operator matches a regex pattern. The four filter operators are:

| Operator | Meaning | Example |
|----------|---------|---------|
| `=` | Equals | `{namespace="boutique"}` |
| `!=` | Not equals | `{namespace!="kube-system"}` |
| `=~` | Regex match | `{pod=~"frontend.*"}` |
| `!~` | Regex exclusion | `{container!~"POD\|"}` |

### Aggregation: Counting and Summing

To count things or add values together, use aggregation functions:

```promql
count(kube_pod_info)
```

This returns a single number: how many pods exist. To break it down by namespace:

```promql
sum by (namespace) (kube_pod_info)
```

The `by (namespace)` clause groups the results. Other useful aggregation functions: `avg`, `min`, `max`, `topk`, `bottomk`.

**Total running pods:**

```promql
sum(kube_pod_status_phase{phase="Running"})
```

**Node count:**

```promql
count(kube_node_info)
```

### Understanding Time Windows: the [5m] Syntax

So far, every query has returned a single value per time series (the most recent measurement). This is called an **instant vector**.

Sometimes you need to look at a window of time. Adding `[5m]` to a query means "give me all the samples from the last 5 minutes". This is called a **range vector**:

```promql
kube_pod_info[5m]
```

A range vector returns multiple data points per series instead of one. This is useful, but it creates a practical problem: you can't plot a list of raw samples on a graph. Graphs need one value per point in time, not a bundle of samples.

This is why you'll almost always wrap a range vector in a function like `rate()` or `count_over_time()`, which collapses those multiple samples back into a single number.

#### Where you can run range vector queries

**Prometheus UI**: click Execute, then view results under the **Table** tab (not the Graph tab). The Table tab runs an "instant query" which can display range vectors as raw data.

**Grafana Explore**: by default, Grafana runs queries in "Range" mode (evaluating repeatedly over a time window to build a graph). Range mode can't accept a range vector expression. To run a raw range vector query, change the query type from **Range** to **Instant** using the toggle near the query box. In Instant mode, Grafana evaluates the query once and shows a table of results.

In practice, you'll rarely need to run raw range vectors. The main reason to understand `[5m]` is so you can use it inside functions like `rate()`.

### rate() -- How Fast Is Something Changing?

Most interesting metrics are counters that only go up (like "total requests served" or "total CPU seconds used"). To see how fast a counter is increasing, use `rate()`:

```promql
rate(container_cpu_usage_seconds_total{namespace="boutique", container!="", container!="POD"}[5m])
```

This returns CPU usage in cores (seconds of CPU per second of wall time) averaged over the last 5 minutes. The `[5m]` inside `rate()` is the lookback window.

`rate()` always takes a range vector (the `[5m]` part) and returns an instant vector (one value per series), so you can graph it normally.

**CPU usage per pod:**

```promql
sum by (pod) (
  rate(container_cpu_usage_seconds_total{namespace="boutique", container!="", container!="POD"}[5m])
)
```

The `sum by (pod)` groups CPU usage from all containers in a pod into one number per pod.

**Request rate per service** (from Tempo service graph metrics):

```promql
sum by (service) (
  rate(traces_service_graph_request_total{service=~"frontend|checkoutservice"}[5m])
)
```

### increase() -- Total Change Over a Window

`increase()` is like `rate()` but returns the total increase instead of a per-second rate:

```promql
increase(kube_pod_container_status_restarts_total[5m])
```

This shows how many times each container restarted in the last 5 minutes.

### Dividing Metrics: Ratios and Percentages

You can divide one query by another to compute ratios.

**Error rate per service** (failed requests / total requests):

```promql
sum by (service) (rate(traces_service_graph_request_failed_total[5m]))
/
sum by (service) (rate(traces_service_graph_request_total[5m]))
```

**CPU requests vs capacity** (how much of the cluster's CPU is requested):

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

### histogram_quantile() -- Latency Percentiles

Some metrics use histograms to record distributions (like request latency). These have a `_bucket` suffix and a special `le` (less-than-or-equal) label. Use `histogram_quantile()` to extract percentiles:

**p50 latency (median) by service:**

```promql
histogram_quantile(0.50,
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

The `le` label must always be in the `by` clause -- it identifies the histogram buckets.

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

**Error rate per service-to-service edge:**

```promql
sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))
/
sum by (client, server) (rate(traces_service_graph_request_total[5m]))
```

---

## 2. LogQL (Loki)

Loki stores log lines from all pods in the cluster. LogQL lets you search and filter those logs. A query has two parts: first you select which log streams to look at, then you optionally filter or parse the lines.

### Your First Log Query

In Grafana, go to Explore (compass icon) and select "Loki" from the data source dropdown. Type:

```logql
{namespace="boutique"}
```

This returns all log lines from pods in the `boutique` namespace. The part inside `{}` is a stream selector -- it picks which logs to fetch using labels.

```logql
{namespace="boutique", pod=~"frontend.*"}
```

This narrows it to just the frontend pods. Labels available in this stack: `namespace`, `pod`, `container`, `node_name`, `job`, `stream` (stdout/stderr).

### Filtering Log Lines by Content

After the stream selector, add filters to search within the log text:

```logql
{namespace="boutique"} |= "error"
```

The `|=` means "line contains this string". This returns only log lines that contain the word "error".

| Operator | Meaning | Example |
|----------|---------|---------|
| `\|=` | Line contains string | `\|= "error"` |
| `!=` | Line does not contain | `!= "health"` |
| `\|~` | Line matches regex | `\|~ "status=[45]\\d{2}"` |
| `!~` | Line does not match regex | `!~ "GET /healthz"` |

You can chain multiple filters:

```logql
{namespace="boutique", pod=~"checkoutservice.*"} |= "error" != "healthz"
```

This finds error logs from the checkout service, excluding lines about health checks.

**Find logs mentioning specific HTTP status codes:**

```logql
{namespace="boutique", pod=~"frontend.*"} |~ "status=[45]\\d{2}"
```

### Parsing Structured Logs

Many services output JSON logs. You can parse them into labels to filter on specific fields:

```logql
{namespace="boutique", pod=~"frontend.*"} | json
```

After `| json`, each JSON field becomes a label. If a log line is `{"level":"error","msg":"connection refused"}`, you get labels `level` and `msg` that you can filter on:

```logql
{namespace="boutique", pod=~"frontend.*"} | json | level="error"
```

```logql
{namespace="boutique", pod=~"frontend.*"} | json | status >= 400
```

For `key=value` formatted logs, use `| logfmt` instead of `| json`:

```logql
{namespace="monitoring"} | logfmt
```

For unstructured logs, extract fields with regex:

```logql
{namespace="boutique", pod=~"frontend.*"} | regexp `(?P<method>GET|POST|PUT|DELETE) (?P<path>/[^ ]*) (?P<status>\d{3})`
```

### Counting Logs Over Time

LogQL can turn logs into numbers, which you can then graph.

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

**Top 5 pods by error log volume:**

```logql
topk(5,
  sum by (pod) (
    count_over_time({namespace="boutique"} |= "error" [5m])
  )
)
```

### Trace-to-Log Correlation

This stack links traces to logs automatically. When viewing a trace in Grafana's Tempo panel, each span has a "Logs" link that searches Loki for:

```logql
{job="<service.name>"} |= `<traceId>`
```

You can also search for a trace ID manually:

```logql
{namespace="boutique"} |= "abc123def456"
```

Replace `abc123def456` with a real trace ID from Tempo.

---

## 3. TraceQL (Tempo)

Traces show how a single request flows through multiple services. Each step in the flow is called a span. A trace is a tree of spans showing the full call chain.

### Your First Trace Query

In Grafana, go to Explore and select "Tempo". Switch to the "Search" tab for a guided UI, or use the "TraceQL" tab to type queries directly.

```traceql
{resource.service.name="frontend"}
```

This finds all traces that include a span from the frontend service. Each result is a trace you can expand to see its full span tree.

Attributes prefixed with `resource.` describe the service (name, version, etc.). Attributes prefixed with `span.` describe the individual operation (HTTP method, URL, etc.).

### Filtering Spans

**Spans with errors:**

```traceql
{status=error}
```

**Spans slower than 500ms:**

```traceql
{duration>500ms}
```

**Spans for a specific HTTP method:**

```traceql
{span.http.method="POST"}
```

**Spans for a specific route:**

```traceql
{span.http.target="/api/cart"}
```

### Combining Conditions

Use `&&` (AND) and `||` (OR) within a selector:

**Error spans from the checkout service:**

```traceql
{resource.service.name="checkoutservice" && status=error}
```

**Slow requests to payment or shipping:**

```traceql
{resource.service.name=~"paymentservice|shippingservice" && duration>500ms}
```

**Error spans or very slow spans from any boutique service:**

```traceql
{resource.service.name=~".*service" && (status=error || duration>2s)}
```

### Structural Queries: Following Call Chains

This is where TraceQL gets powerful. You can query based on how services call each other.

**Traces where the frontend calls the checkout service:**

```traceql
{resource.service.name="frontend"} >> {resource.service.name="checkoutservice"}
```

`>>` means "is an ancestor of" (at any depth in the call tree). `>` means "is a direct parent of" (one level).

**Traces where checkout calls payment and it errors:**

```traceql
{resource.service.name="checkoutservice"} >> {resource.service.name="paymentservice" && status=error}
```

**Traces where frontend eventually calls a slow product catalog query:**

```traceql
{resource.service.name="frontend"} >> {resource.service.name="productcatalogservice" && duration>200ms}
```

### Trace-Level Filters

Filter entire traces based on aggregate properties using the pipe `|` operator:

**Traces with more than 20 spans** (complex call chains):

```traceql
{resource.service.name=~".*"} | count() > 20
```

**Traces with more than 3 error spans:**

```traceql
{status=error} | count() > 3
```

**Traces where the average span duration exceeds 1 second:**

```traceql
{resource.service.name="frontend"} | avg(duration) > 1s
```

### How Traces Connect to Logs and Metrics

This stack has three correlation paths configured in Grafana:

**Trace to Logs (Tempo to Loki):** Each span in a trace has a "Logs" link that searches Loki for `{job="<service.name>"} |= <traceId>` within a +/-1h time window around the span.

**Trace to Metrics (Tempo to Prometheus):** Tempo's metrics generator produces `traces_service_graph_request_*` metrics from traces. These power the service dependency map dashboard and RED (Rate, Errors, Duration) queries in PromQL.

**Log to Trace (Loki to Tempo):** When a log line contains a trace ID matching the pattern `traceID=...` or `trace_id: ...`, Grafana renders it as a clickable link that opens the trace in Tempo.

---

## Quick Reference

### PromQL Cheat Sheet

| What you want | Query |
|---------------|-------|
| All pods | `kube_pod_info` |
| Pods in a namespace | `kube_pod_info{namespace="boutique"}` |
| Pod count by namespace | `sum by (namespace) (kube_pod_info)` |
| CPU usage by pod | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="boutique", container!="", container!="POD"}[5m]))` |
| Memory usage by pod | `sum by (pod) (container_memory_working_set_bytes{namespace="boutique", container!="", container!="POD"})` |
| Request rate by service | `sum by (service) (rate(traces_service_graph_request_total[5m]))` |
| Error rate by service | `sum by (service) (rate(traces_service_graph_request_failed_total[5m])) / sum by (service) (rate(traces_service_graph_request_total[5m]))` |
| p99 latency by service | `histogram_quantile(0.99, sum by (le, service) (rate(traces_service_graph_request_server_seconds_bucket[5m])))` |
| Node CPU % | `1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Pod restarts | `increase(kube_pod_container_status_restarts_total{namespace="boutique"}[5m])` |

### LogQL Cheat Sheet

| What you want | Query |
|---------------|-------|
| All logs from a namespace | `{namespace="boutique"}` |
| Logs from a specific pod | `{namespace="boutique", pod=~"frontend.*"}` |
| Filter by content | `{namespace="boutique"} \|= "error"` |
| Parse JSON and filter | `{namespace="boutique"} \| json \| level="error"` |
| Log volume per pod | `sum by (pod) (count_over_time({namespace="boutique"}[1m]))` |
| Find logs by trace ID | `{namespace="boutique"} \|= "<trace-id>"` |

### TraceQL Cheat Sheet

| What you want | Query |
|---------------|-------|
| Spans from a service | `{resource.service.name="frontend"}` |
| Error spans | `{resource.service.name="checkoutservice" && status=error}` |
| Slow spans | `{resource.service.name="frontend" && duration>500ms}` |
| Call chain | `{resource.service.name="frontend"} >> {resource.service.name="checkoutservice"}` |
| Traces with many errors | `{status=error} \| count() > 3` |
