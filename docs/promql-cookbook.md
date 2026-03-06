# PromQL Cookbook: 100 Queries for This Cluster

Run these in Grafana Explore (select "Prometheus" datasource) or in the Prometheus UI.

This cluster runs kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics), Online Boutique microservices in the `boutique` namespace, and the observability stack (Loki, Tempo, OTel Collector) in the `monitoring` namespace.

---

## The First Query (1)

**1. Is everything up?**
```promql
up
```
The traditional starting point. Every Prometheus scrape target reports an `up` metric: `1` means the target responded successfully, `0` means the scrape failed. This returns one time series per target, so you can instantly see which components in your cluster are healthy and which are unreachable.

---

## Cluster Health (2-11)

**2. Total number of running pods**
```promql
count(kube_pod_status_phase{phase="Running"})
```
`kube_pod_status_phase` is a gauge from kube-state-metrics with a `phase` label for each pod. The label selector `{phase="Running"}` filters to only running pods. `count()` collapses all those series into a single number -- the total.

**3. Pods NOT in Running phase**
```promql
kube_pod_status_phase{phase!="Running"} == 1
```
The `!=` operator is a negative label matcher -- it returns series where `phase` is anything other than "Running". The `== 1` filters to phases that are actually active (kube-state-metrics emits a `0` for each phase a pod is NOT in, so without this filter you'd get noise).

**4. Pods in CrashLoopBackOff (restarting frequently)**
```promql
increase(kube_pod_container_status_restarts_total[10m]) > 3
```
`kube_pod_container_status_restarts_total` is a counter that goes up by 1 each time a container restarts. `increase(...[10m])` calculates how much that counter grew over the last 10 minutes. The `> 3` filter keeps only containers that restarted more than 3 times in that window -- a strong signal of crash-looping.

**5. Nodes that are not Ready**
```promql
kube_node_status_condition{condition="Ready", status="true"} == 0
```
Each node's conditions are exposed as metrics. This selects the "Ready" condition where the reported status label is "true" and checks if the metric value is 0 -- meaning the node is reporting it is NOT ready. A healthy cluster returns no results here.

**6. Cluster-wide CPU usage percentage**
```promql
100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```
`node_cpu_seconds_total` is a counter that tracks seconds spent in each CPU mode. `rate(...[5m])` converts it to a per-second rate over 5 minutes. Filtering to `mode="idle"` gives the fraction of time CPUs were idle. `avg()` averages across all CPU cores on all nodes. Subtracting from 100 flips "idle" into "busy" -- giving you a single cluster-wide CPU usage percentage.

**7. Memory usage percentage per node**
```promql
100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```
Two gauges from node-exporter: available memory and total memory. Dividing gives the fraction that's free; subtracting from 1 gives the fraction in use; multiplying by 100 converts to a percentage. You get one result per node.

**8. Filesystem usage percentage per node (regex: exclude tmpfs)**
```promql
100 * (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})
```
Same pattern as memory, but for disk. The `!~` operator is a negative regex matcher -- `"tmpfs|overlay"` excludes in-memory and container overlay filesystems that would pollute the results. The `|` inside the regex means "or".

**9. Number of pods per namespace**
```promql
count by (namespace) (kube_pod_info)
```
`kube_pod_info` has one series per pod with labels including `namespace`. `count by (namespace)` groups all those series by their namespace label and counts how many are in each group. This tells you how your workload is distributed.

**10. Total container restarts per namespace in the last hour**
```promql
sum by (namespace) (increase(kube_pod_container_status_restarts_total[1h]))
```
`increase(...[1h])` computes how much the restart counter grew per container over the last hour. `sum by (namespace)` adds those up per namespace. A high number in the `boutique` namespace might indicate application instability.

**11. Pods stuck in Pending**
```promql
kube_pod_status_phase{phase="Pending"} == 1
```
Filters to pods where the Pending phase is active (value `1`). Pods stuck here usually have scheduling problems -- not enough resources, node affinity mismatches, or missing PersistentVolumes.

---

## CPU Metrics (12-21)

**12. CPU usage per pod in the boutique namespace**
```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="boutique"}[5m]))
```
`container_cpu_usage_seconds_total` is a counter of CPU seconds consumed. `rate(...[5m])` turns it into cores used per second (1.0 = one full core). A pod may have multiple containers, so `sum by (pod)` adds them up to give total CPU per pod.

**13. Top 5 CPU-consuming pods across the cluster**
```promql
topk(5, sum by (pod, namespace) (rate(container_cpu_usage_seconds_total[5m])))
```
Same CPU rate calculation, but now grouped by both pod and namespace (to avoid name collisions). `topk(5, ...)` returns only the 5 highest values -- useful for quickly finding the greediest workloads.

**14. CPU usage vs requests ratio (over-provisioned pods)**
```promql
sum by (pod, namespace) (rate(container_cpu_usage_seconds_total[5m]))
/
sum by (pod, namespace) (kube_pod_container_resource_requests{resource="cpu"})
```
Divides actual CPU usage by the CPU request each pod declared. A value of 0.1 means the pod is only using 10% of what it requested -- it's over-provisioned. A value above 1.0 means it's using more than it asked for (and may get throttled if it also exceeds its limit).

**15. Pods using more CPU than their request**
```promql
(
  sum by (pod, namespace) (rate(container_cpu_usage_seconds_total[5m]))
  /
  sum by (pod, namespace) (kube_pod_container_resource_requests{resource="cpu"})
) > 1
```
Same ratio as above, but the `> 1` comparison filter drops everything at or below 100% utilization. Only over-consuming pods remain in the result.

**16. CPU throttling per container**
```promql
rate(container_cpu_cfs_throttled_seconds_total[5m])
```
When a container hits its CPU limit, the kernel's CFS scheduler throttles it. This counter tracks how many seconds were spent throttled. A non-zero rate here means the container is hitting its CPU ceiling and its processes are being forced to wait.

**17. CPU saturation: system load vs CPU count**
```promql
node_load1 / count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})
```
`node_load1` is the 1-minute load average (number of processes wanting CPU time). Dividing by the number of CPU cores (counted by stripping the `cpu` and `mode` labels from the idle metric) normalizes it. A value above 1.0 means more work is queued than cores can handle.

**18. Per-CPU core usage (regex: filter specific cores)**
```promql
rate(node_cpu_seconds_total{mode!="idle", cpu=~"0|1"}[5m])
```
The `cpu=~"0|1"` regex matcher limits results to cores 0 and 1 specifically. `mode!="idle"` excludes idle time. You get a breakdown by mode (user, system, iowait, etc.) for just those two cores -- useful for investigating per-core imbalances.

**19. CPU usage by mode (user, system, iowait, etc.)**
```promql
sum by (mode) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))
```
Sums CPU time across all nodes and cores, grouped only by `mode`. This gives you a cluster-wide view of where CPU time is going: user-space code, kernel (system), waiting on I/O, etc.

**20. Average CPU usage of monitoring namespace pods**
```promql
avg by (pod) (rate(container_cpu_usage_seconds_total{namespace="monitoring"}[5m]))
```
Same as the per-pod CPU query but scoped to the monitoring namespace and using `avg` instead of `sum`. Since monitoring pods like Prometheus and Grafana typically have one container each, `avg` and `sum` give the same result -- but `avg` is the safer choice if a sidecar is present.

**21. CPU request utilization across the entire cluster**
```promql
sum(rate(container_cpu_usage_seconds_total[5m])) / sum(kube_pod_container_resource_requests{resource="cpu"}) * 100
```
Total actual CPU usage divided by total requested CPU, as a percentage. This tells you how efficiently the cluster's CPU budget is being used. If this is 20%, pods have collectively requested 5x more CPU than they're consuming.

---

## Memory Metrics (22-31)

**22. Memory usage per pod in boutique namespace**
```promql
sum by (pod) (container_memory_working_set_bytes{namespace="boutique", container!=""})
```
`container_memory_working_set_bytes` is the amount of memory in active use (not reclaimable cache). The `container!=""` filter excludes the pod-level cgroup summary entry that Kubernetes adds (which would double-count). `sum by (pod)` totals across all containers in each pod.

**23. Top 5 memory-consuming pods**
```promql
topk(5, sum by (pod, namespace) (container_memory_working_set_bytes{container!=""}))
```
Groups memory by pod and namespace, then `topk(5, ...)` returns only the top 5. Useful for finding the biggest memory consumers at a glance.

**24. Pods using more memory than their request**
```promql
(
  sum by (pod, namespace) (container_memory_working_set_bytes{container!=""})
  /
  sum by (pod, namespace) (kube_pod_container_resource_requests{resource="memory"})
) > 1
```
Actual memory divided by requested memory, filtered to ratios above 1.0. These pods are using more memory than they asked for. Unlike CPU (which gets throttled), exceeding memory requests makes a pod a candidate for eviction if the node runs low on memory.

**25. Memory usage as percentage of limit**
```promql
sum by (pod, namespace) (container_memory_working_set_bytes{container!=""})
/
sum by (pod, namespace) (kube_pod_container_resource_limits{resource="memory"})
* 100
```
Same idea, but against the hard limit instead of the request. A pod approaching 100% here will be OOM-killed by the kernel. Use this to find pods in danger of being killed.

**26. OOM-killed containers**
```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
```
kube-state-metrics records the reason a container was last terminated. Filtering to `reason="OOMKilled"` shows every container that has been killed for exceeding its memory limit. The metric persists until the pod is deleted, so this is a historical record.

**27. Node memory pressure**
```promql
kube_node_status_condition{condition="MemoryPressure", status="true"}
```
Kubelet sets this condition when available memory drops below a threshold. If this returns a value of 1 for any node, that node is actively under memory pressure and the kubelet may start evicting pods.

**28. Free memory per node in GB**
```promql
node_memory_MemAvailable_bytes / 1024 / 1024 / 1024
```
Simple unit conversion: bytes to gigabytes by dividing by 1024 three times. `MemAvailable` accounts for reclaimable caches, so it's more accurate than `MemFree` for gauging actual headroom.

**29. Memory used by containers with names matching "service" (regex)**
```promql
sum by (container) (container_memory_working_set_bytes{container=~".*service.*"})
```
The `=~` operator is a regex match. `".*service.*"` matches any container name containing "service" anywhere. This picks up checkoutservice, currencyservice, productcatalogservice, etc. in one query. `sum by (container)` groups by the matched container name.

**30. Memory RSS vs working set (cache overhead)**
```promql
sum by (pod) (container_memory_rss{namespace="boutique"})
/
sum by (pod) (container_memory_working_set_bytes{namespace="boutique"})
```
RSS (Resident Set Size) is memory that's actually in physical RAM. Working set includes RSS plus recently accessed file cache. A ratio close to 1.0 means the pod has very little cache overhead; a lower ratio means significant memory is going to file-backed pages.

**31. Total cluster memory utilization**
```promql
sum(container_memory_working_set_bytes{container!=""}) / sum(node_memory_MemTotal_bytes) * 100
```
All container memory usage divided by all node memory, as a percentage. A quick check on overall cluster memory pressure.

---

## Network Metrics (32-41)

**32. Network receive bytes per pod in boutique**
```promql
sum by (pod) (rate(container_network_receive_bytes_total{namespace="boutique"}[5m]))
```
`container_network_receive_bytes_total` is a counter of bytes received. `rate(...[5m])` converts to bytes per second. `sum by (pod)` handles pods with multiple network interfaces. This shows how much inbound traffic each boutique pod is handling.

**33. Network transmit bytes per pod**
```promql
sum by (pod) (rate(container_network_transmit_bytes_total{namespace="boutique"}[5m]))
```
Same as above but for outbound traffic. Comparing receive and transmit helps you understand whether a service is a net producer or consumer of data.

**34. Network errors (receive side)**
```promql
rate(node_network_receive_errs_total[5m]) > 0
```
Counts per-second receive errors at the node level. Any result here means packets are being corrupted or dropped at the NIC. The `> 0` filter hides interfaces with no errors.

**35. Network errors (transmit side)**
```promql
rate(node_network_transmit_errs_total[5m]) > 0
```
Same but for outbound packets. Transmit errors often indicate driver bugs, NIC saturation, or cable problems.

**36. Bytes received per network interface (regex: exclude lo and veth)**
```promql
rate(node_network_receive_bytes_total{device!~"lo|veth.*|cali.*|flannel.*"}[5m])
```
The negative regex `!~"lo|veth.*|cali.*|flannel.*"` excludes the loopback interface, per-pod virtual ethernet pairs, and CNI bridge interfaces. What remains are the "real" physical or cloud network interfaces, giving you actual node-level traffic.

**37. Total bandwidth in Mbps per node**
```promql
(
  sum by (instance) (rate(node_network_receive_bytes_total{device!~"lo|veth.*"}[5m]))
  +
  sum by (instance) (rate(node_network_transmit_bytes_total{device!~"lo|veth.*"}[5m]))
) * 8 / 1024 / 1024
```
Adds receive and transmit bytes per second, then converts bytes to megabits (`* 8 / 1024 / 1024`). Grouping by `instance` gives one bandwidth number per node. Useful for checking if you're approaching NIC capacity.

**38. Dropped packets per interface**
```promql
rate(node_network_receive_drop_total[5m]) > 0
```
Dropped packets mean the kernel's network stack couldn't process packets fast enough. Non-zero results here indicate potential network saturation or misconfigured buffers.

**39. Pod network I/O ratio (transmit / receive)**
```promql
sum by (pod) (rate(container_network_transmit_bytes_total{namespace="boutique"}[5m]))
/
sum by (pod) (rate(container_network_receive_bytes_total{namespace="boutique"}[5m]))
```
Divides outbound by inbound traffic per pod. A ratio above 1 means the pod sends more than it receives (e.g., a service returning large responses). Below 1 means it receives more (e.g., a service ingesting data).

**40. Top 3 pods by inbound traffic**
```promql
topk(3, sum by (pod, namespace) (rate(container_network_receive_bytes_total[5m])))
```
`topk(3, ...)` picks the 3 pods receiving the most bytes per second. Helps you quickly identify the busiest network consumers.

**41. Network receive bytes across selected namespaces (regex: boutique or monitoring)**
```promql
sum by (namespace) (rate(container_network_receive_bytes_total{namespace=~"boutique|monitoring"}[5m]))
```
The regex `=~"boutique|monitoring"` matches either namespace. `sum by (namespace)` gives a total per namespace, so you can compare application traffic vs observability stack traffic.

---

## Kubernetes Object State (42-51)

**42. Deployments with unavailable replicas**
```promql
kube_deployment_status_replicas_unavailable > 0
```
kube-state-metrics exposes the number of unavailable replicas per deployment. Filtering to `> 0` shows deployments that aren't fully healthy -- maybe a pod is crashing or stuck in scheduling.

**43. Deployments not at desired replica count**
```promql
kube_deployment_spec_replicas != kube_deployment_status_replicas_available
```
Compares what you asked for (`spec_replicas`) with what's actually running (`status_replicas_available`). The `!=` operator returns results only when these differ. A mismatch means the deployment is still rolling out, scaling, or has pods failing to start.

**44. All deployments in boutique namespace with their replica counts**
```promql
kube_deployment_spec_replicas{namespace="boutique"}
```
A simple selector query -- no functions, no math. Returns one time series per deployment in the boutique namespace, where the value is the desired replica count. Good for a quick inventory.

**45. StatefulSets not fully ready**
```promql
kube_statefulset_status_replicas_ready != kube_statefulset_status_replicas
```
Same pattern as the deployment check. Compares ready replicas to total replicas for each StatefulSet. Results appear only when they don't match.

**46. DaemonSet pods not scheduled**
```promql
kube_daemonset_status_desired_number_scheduled - kube_daemonset_status_number_ready > 0
```
Subtracts ready pods from desired pods. A positive result means some nodes are missing their DaemonSet pods -- possibly due to taints, resource limits, or scheduling failures.

**47. Jobs that have failed**
```promql
kube_job_status_failed > 0
```
Each Kubernetes Job tracks how many pods have failed. Any non-zero value here indicates a job that had at least one pod failure.

**48. PersistentVolumeClaims not bound**
```promql
kube_persistentvolumeclaim_status_phase{phase!="Bound"} == 1
```
PVCs go through phases: Pending, Bound, Lost. The negative matcher `!="Bound"` catches anything that isn't successfully attached to a PersistentVolume. Unbound PVCs block pods from starting.

**49. Container waiting reasons across the cluster**
```promql
sum by (reason) (kube_pod_container_status_waiting_reason)
```
When containers are waiting (not running), kube-state-metrics records the reason: CrashLoopBackOff, ImagePullBackOff, CreateContainerConfigError, etc. `sum by (reason)` counts how many containers are in each waiting state.

**50. Pods per node**
```promql
count by (node) (kube_pod_info)
```
Counts pods grouped by the `node` label. Shows how evenly your workload is distributed across nodes. A significantly higher count on one node might indicate a scheduling imbalance.

**51. Services in boutique namespace (regex: match names ending in "service")**
```promql
kube_service_info{namespace="boutique", service=~".*service"}
```
Uses a regex `=~".*service"` to match any service name that ends with "service". This picks up checkoutservice, currencyservice, paymentservice, etc. while excluding things like "frontend" and "redis-cart".

---

## Rate, Increase, and Delta Patterns (52-61)

**52. Per-second rate of container restarts**
```promql
rate(kube_pod_container_status_restarts_total[5m])
```
`rate()` takes a counter and returns the per-second average rate of increase over the given window. Applied to restarts, this tells you how frequently each container is restarting. A value of 0.01 means roughly one restart every 100 seconds.

**53. Total new restarts in the last hour per pod**
```promql
increase(kube_pod_container_status_restarts_total[1h])
```
`increase()` is like `rate()` but returns the total increase rather than a per-second value. Over a 1-hour window, this tells you exactly how many restarts occurred. More intuitive for counters where the absolute count matters.

**54. Rate of network bytes received, smoothed over 15m**
```promql
rate(container_network_receive_bytes_total{namespace="boutique"}[15m])
```
Using a longer range window (15m vs 5m) produces a smoother line that hides short spikes. Useful for seeing overall trends rather than momentary bursts.

**55. Compare 5m rate vs 1h rate to spot spikes**
```promql
rate(container_cpu_usage_seconds_total{namespace="boutique"}[5m])
/
rate(container_cpu_usage_seconds_total{namespace="boutique"}[1h])
```
Divides a short-window rate by a long-window rate. If CPU usage is steady, this ratio stays near 1.0. A spike to 3.0 means the last 5 minutes had 3x the CPU usage of the last hour's average -- a clear anomaly signal.

**56. Delta of memory usage over 10 minutes (growing pods)**
```promql
delta(container_memory_working_set_bytes{namespace="boutique", container!=""}[10m]) > 0
```
`delta()` works on gauges (unlike `increase()` which works on counters). It returns the difference between the value now and the value 10 minutes ago. Positive deltas mean memory is growing.

**57. Containers with steadily increasing memory (potential leak)**
```promql
deriv(container_memory_working_set_bytes{namespace="boutique", container!=""}[30m]) > 1000
```
`deriv()` fits a least-squares linear regression to the gauge values over the window and returns the slope (per-second rate of change). A positive slope sustained over 30 minutes strongly suggests a memory leak. The `> 1000` threshold means memory is growing by more than 1KB/s.

**58. Rate of all process forks per node**
```promql
rate(node_forks_total[5m])
```
`node_forks_total` counts every `fork()` system call. A high rate means many new processes are being created, which can indicate runaway shell scripts, aggressive cron jobs, or a fork bomb.

**59. Increase in context switches over 5 minutes**
```promql
increase(node_context_switches_total[5m])
```
Context switches happen when the CPU swaps between processes. A sudden increase can indicate too many runnable threads competing for CPU time. Reported as a total count over the 5-minute window.

**60. Rate of disk reads per device (regex: exclude loop devices)**
```promql
rate(node_disk_reads_completed_total{device!~"loop.*"}[5m])
```
`loop.*` matches loopback devices (loop0, loop1, etc.) used for snap packages -- not interesting for real I/O monitoring. The negative regex excludes them, leaving only real block devices.

**61. irate (instant rate) of CPU usage for more responsive graphs**
```promql
sum by (pod) (irate(container_cpu_usage_seconds_total{namespace="boutique"}[2m]))
```
`irate()` calculates the rate using only the last two data points in the window, instead of averaging over the whole window like `rate()`. This makes it much more responsive to sudden changes but also noisier. The `[2m]` just needs to contain at least two samples.

---

## Disk and I/O (62-68)

**62. Disk I/O utilization per device**
```promql
rate(node_disk_io_time_seconds_total{device!~"loop.*"}[5m])
```
This counter tracks seconds during which I/O was in progress. A `rate()` of 1.0 means the disk was busy 100% of the time (fully saturated). Values above 0.7 are worth investigating.

**63. Disk write throughput in MB/s**
```promql
rate(node_disk_written_bytes_total{device!~"loop.*"}[5m]) / 1024 / 1024
```
Converts the bytes-written counter to a per-second rate, then divides twice by 1024 to get megabytes per second. Gives you actual disk write throughput per device.

**64. Disk read latency per operation**
```promql
rate(node_disk_read_time_seconds_total{device!~"loop.*"}[5m])
/
rate(node_disk_reads_completed_total{device!~"loop.*"}[5m])
```
Total read time divided by number of reads gives average latency per read operation in seconds. On SSDs this should be under 1ms (0.001); on spinning disks, under 10ms. Values climbing above that suggest disk contention.

**65. Filesystem inodes usage percentage**
```promql
100 * (1 - node_filesystem_files_free{fstype!~"tmpfs|overlay"} / node_filesystem_files{fstype!~"tmpfs|overlay"})
```
Even with free disk space, running out of inodes (file entries) makes it impossible to create new files. This calculates inode usage the same way we calculate disk usage: free divided by total, subtracted from 1. Rare in practice, but catastrophic when it happens.

**66. PV disk usage in the monitoring namespace**
```promql
kubelet_volume_stats_used_bytes{namespace="monitoring"}
/
kubelet_volume_stats_capacity_bytes{namespace="monitoring"}
* 100
```
The kubelet exposes volume stats for mounted PersistentVolumes. This shows how full each PV in the monitoring namespace is. Important for Prometheus data storage -- if it fills up, metrics collection stops.

**67. Write-heavy devices (top 3)**
```promql
topk(3, rate(node_disk_written_bytes_total[5m]))
```
Finds the 3 block devices with the highest write throughput across all nodes. Helps identify which disks are under the most write pressure.

**68. Disk I/O queue depth**
```promql
rate(node_disk_io_time_weighted_seconds_total{device!~"loop.*"}[5m])
```
This metric weights I/O time by the number of operations in the queue. A higher value means more operations were waiting concurrently. Compare this with the non-weighted I/O time (query 62) -- if this is much higher, operations are queueing up.

---

## Prometheus Internal Metrics (69-76)

**69. Total number of active time series**
```promql
prometheus_tsdb_head_series
```
The head block is Prometheus's in-memory store of recent data. This gauge shows how many unique time series are currently being tracked. A high number (hundreds of thousands) increases memory usage and query latency. Useful for cardinality monitoring.

**70. Ingestion rate (samples per second)**
```promql
rate(prometheus_tsdb_head_samples_appended_total[5m])
```
Counts how many individual data points Prometheus is ingesting per second across all scrape targets. Multiply by your storage retention to estimate total disk usage. A sudden increase might indicate a new high-cardinality metric.

**71. Scrape pool sync count**
```promql
prometheus_target_scrape_pool_sync_total
```
Tracks how many times Prometheus has synchronized its list of scrape targets. This happens when service discovery detects changes (new pods, removed pods). Frequent syncs indicate a lot of churn in the cluster.

**72. Failed scrapes by job**
```promql
sum by (job) (up == 0)
```
`up == 0` selects only targets that failed their last scrape. `sum by (job)` counts how many targets are down per scrape job. Helps identify which job has the most failing targets.

**73. All targets that are down**
```promql
up == 0
```
The simplest health check. Returns every individual target that Prometheus couldn't reach on its last scrape attempt. Each result includes labels identifying the exact target (job, instance, namespace, pod).

**74. Prometheus memory usage**
```promql
process_resident_memory_bytes{job="prometheus"}
```
The RSS (Resident Set Size) of the Prometheus process itself. Prometheus exposes standard Go process metrics. Watch this to ensure Prometheus isn't approaching your container's memory limit.

**75. Currently firing alerts**
```promql
ALERTS{alertstate="firing"}
```
`ALERTS` is a special metric that Prometheus generates for each active alert rule. The `alertstate` label is either "pending" (condition met but waiting for `for` duration) or "firing" (fully triggered). This shows everything that's actively firing.

**76. Pending alerts (not yet firing)**
```promql
ALERTS{alertstate="pending"}
```
Alerts in "pending" have met their condition but haven't sustained it long enough to fire (controlled by the `for` clause in alert rules). These are early warnings -- conditions that are flapping or just starting.

---

## Aggregation and Grouping Patterns (77-86)

**77. Average CPU usage grouped by namespace**
```promql
avg by (namespace) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
```
`avg by (namespace)` computes the mean CPU rate across all containers in each namespace. This tells you the typical per-container CPU consumption in each namespace, not the total (use `sum` for total).

**78. Max memory usage per namespace**
```promql
max by (namespace) (container_memory_working_set_bytes{container!=""})
```
`max by (namespace)` returns only the single largest memory value within each namespace. Quick way to find the biggest memory hog in each namespace without seeing every pod.

**79. Sum of CPU requests by namespace (capacity planning)**
```promql
sum by (namespace) (kube_pod_container_resource_requests{resource="cpu"})
```
Adds up all CPU requests per namespace. This is how much CPU the scheduler has reserved, regardless of actual usage. If this approaches your cluster's total CPU capacity, new pods won't be able to schedule.

**80. Count of containers per pod (multi-container pod detection)**
```promql
count by (pod, namespace) (kube_pod_container_info) > 1
```
Counts containers in each pod and filters to those with more than 1. Multi-container pods have sidecars (like Istio proxies or log collectors). Useful for understanding your pod architecture.

**81. Standard deviation of CPU usage across boutique pods**
```promql
stddev(rate(container_cpu_usage_seconds_total{namespace="boutique", container!=""}[5m]))
```
`stddev()` measures how spread out CPU usage is across all boutique containers. A high value means some containers use much more CPU than others. A low value means they're all similar -- good for uniform workloads.

**82. Quantile: 95th percentile memory usage across pods**
```promql
quantile(0.95, container_memory_working_set_bytes{container!=""})
```
`quantile(0.95, ...)` finds the value below which 95% of all container memory values fall. Unlike `max`, this ignores the top 5% outliers. Good for setting memory requests -- you want to cover 95% of normal behavior.

**83. bottomk: 5 least busy pods by CPU**
```promql
bottomk(5, sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="boutique"}[5m])))
```
The opposite of `topk` -- returns the 5 pods with the lowest CPU usage. Helps identify idle or nearly-idle workloads that might be candidates for scaling down or removal.

**84. group_left: Join pod CPU with its owning deployment**
```promql
sum by (pod, namespace) (rate(container_cpu_usage_seconds_total{namespace="boutique"}[5m]))
* on (pod, namespace) group_left(owner_name)
label_replace(kube_pod_owner{owner_kind="ReplicaSet"}, "owner_name", "$1", "owner_name", "(.*)-[a-z0-9]+")
```
This is PromQL's version of a SQL JOIN. The left side has CPU usage per pod. The right side has pod ownership info. `* on (pod, namespace) group_left(owner_name)` joins them on matching pod/namespace labels and brings in the `owner_name` label. The `label_replace` strips the ReplicaSet hash suffix to get the Deployment name. The result is CPU per pod with the deployment name attached.

**85. count_values: Distribution of pod phases**
```promql
count_values("phase", kube_pod_status_phase)
```
`count_values` is unique -- it takes a metric's values and groups by them. Each distinct value becomes a label, and the result is how many series had that value. Here it shows how many time series exist for each pod phase value.

**86. Aggregate CPU by regex-matched pod groups**
```promql
sum by (service) (
  label_replace(
    rate(container_cpu_usage_seconds_total{namespace="boutique", container!=""}[5m]),
    "service", "$1", "pod", "(.*)-[a-f0-9]+-[a-z0-9]+"
  )
)
```
Pods in Kubernetes are named like `checkoutservice-abc123-xyz`. `label_replace` uses the regex capture group `(.*)` to extract everything before the ReplicaSet and pod hash suffixes, storing it in a new label called "service". Then `sum by (service)` aggregates all pods belonging to the same deployment. You get CPU usage per logical service.

---

## Regex and Label Manipulation (87-94)

**87. Pods whose names start with "frontend" or "checkout"**
```promql
kube_pod_info{pod=~"(frontend|checkout).*"}
```
The regex `(frontend|checkout).*` uses alternation (`|`) inside a group to match pods starting with either prefix. The `.*` matches the rest of the pod name (the hash suffixes). This is how you select multiple services in a single query.

**88. All metrics from jobs matching a pattern**
```promql
up{job=~".*kube.*"}
```
The `.*kube.*` regex matches any job name containing "kube" anywhere. This catches kube-state-metrics, kube-apiserver, kubelet, etc. -- all the Kubernetes infrastructure scrape targets.

**89. Exclude specific namespaces with negative regex**
```promql
sum by (namespace) (kube_pod_info{namespace!~"kube-system|kube-public|default"})
```
The `!~` operator means "does NOT match this regex". The pipe-separated list excludes three system namespaces at once. Only user-created namespaces (boutique, monitoring, etc.) remain.

**90. label_replace: Extract deployment name from pod name**
```promql
label_replace(
  container_memory_working_set_bytes{namespace="boutique", container!=""},
  "deployment", "$1", "pod", "(.*)-[a-f0-9]+-[a-z0-9]+"
)
```
`label_replace(metric, "new_label", "replacement", "source_label", "regex")` creates a new label by applying a regex to an existing label. The regex `(.*)-[a-f0-9]+-[a-z0-9]+` captures everything before the ReplicaSet hash and pod suffix. `$1` refers to the first capture group. So pod `frontend-abc123-xyz` gets `deployment="frontend"`.

**91. label_replace: Shorten node names**
```promql
label_replace(
  node_memory_MemAvailable_bytes,
  "short_node", "$1", "instance", "([^:]+):.*"
)
```
Node instance labels are often like `10.0.1.5:9100`. The regex `([^:]+):.*` captures everything before the colon (the hostname or IP) and puts it in a new `short_node` label. Cleaner for display in dashboards.

**92. Match containers from a specific registry (regex)**
```promql
kube_pod_container_info{image=~"gcr\\.io/google-samples/.*"}
```
The double backslash `\\.` is needed to match a literal dot in the regex (since `.` normally means "any character"). This finds all containers running images from Google's sample registry -- the Online Boutique microservices.

**93. Metrics from pods with numeric suffixes (regex capture groups)**
```promql
kube_pod_info{pod=~".+-[0-9]+$"}
```
The `$` anchors the regex to the end of the string. `.+-[0-9]+$` matches pods ending with a dash and one or more digits, like `redis-cart-0` -- typical of StatefulSet pods. Deployment pods end with random alphanumeric strings, so they won't match.

**94. Pods NOT in boutique or monitoring**
```promql
kube_pod_info{namespace!~"boutique|monitoring|kube-system|kube-public|default"}
```
Negative regex matching to exclude multiple known namespaces. Whatever's left might be unexpected workloads. Useful as a security/audit query to find pods running where they shouldn't be.

---

## Alerting Patterns and Thresholds (95-100)

**95. Containers with CPU usage above 80% of their limit**
```promql
(
  sum by (pod, namespace, container) (rate(container_cpu_usage_seconds_total[5m]))
  /
  sum by (pod, namespace, container) (kube_pod_container_resource_limits{resource="cpu"})
) > 0.8
```
Actual CPU divided by the CPU limit, filtered to above 80%. Containers near their limit will experience throttling (the kernel pauses them to stay within budget). This is a common alert threshold -- it gives you warning before performance degrades.

**96. Nodes with less than 10% free disk space**
```promql
(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) < 0.1
```
Available divided by total gives the free fraction. The `< 0.1` filter shows only filesystems with less than 10% free. A full disk can crash applications, prevent logging, and block kubelet from functioning.

**97. predict_linear: Disk will fill within 24 hours**
```promql
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 24 * 3600) < 0
```
`predict_linear(metric[window], seconds)` fits a linear regression to the last 6 hours of data and projects the value 24 hours into the future (86400 seconds). If the predicted value is negative, the disk is on track to fill up within a day. This is the single most useful alerting function in PromQL -- it lets you act before a problem hits.

**98. Services with error rate above 5% (regex: match 5xx status codes)**
```promql
sum by (service) (rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
/
sum by (service) (rate(http_server_requests_seconds_count[5m]))
> 0.05
```
The regex `5..` matches any 3-character string starting with "5" -- covering 500, 501, 502, etc. The numerator counts error requests; the denominator counts all requests. Dividing gives the error ratio. The `> 0.05` threshold means more than 5% of requests are failing.

**99. High p99 latency (histogram_quantile)**
```promql
histogram_quantile(0.99,
  sum by (le, service) (rate(http_server_requests_seconds_bucket[5m]))
) > 2
```
Histogram metrics store request durations in buckets (e.g., "requests under 0.1s", "under 0.5s", "under 1s"). `histogram_quantile(0.99, ...)` computes the 99th percentile from those buckets. The `le` label (less-than-or-equal) is required for this to work -- it's the bucket boundary. The result is the latency in seconds that 99% of requests are faster than. `> 2` filters to services where p99 exceeds 2 seconds.

**100. absent: Alert when a critical metric disappears**
```promql
absent(up{job="kube-prometheus-stack-prometheus"})
```
`absent()` returns 1 when the specified metric has NO data at all, and returns nothing when data exists. This is the inverse of normal querying. Use it to detect when something that should always be present goes missing -- like Prometheus not being able to scrape itself. Essential for "dead man's switch" alerts.

---

## Tips for Exploring Further

- Use the Prometheus UI's autocomplete: start typing a metric name and browse what's available.
- Add `{namespace="boutique"}` to any query to scope it to the demo app.
- Wrap any query in `count()` to see how many time series it returns before graphing.
- Use the `/api/v1/label/__name__/values` endpoint on Prometheus to list all metric names.
