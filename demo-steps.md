# Grafana Observability Stack - Demo Steps

Five hands-on scenarios that showcase the full observability stack (Prometheus, Grafana, Loki, Tempo, OpenTelemetry) running on EKS with the Online Boutique microservices application.

## Prerequisites

- EKS cluster running with the monitoring stack deployed
- Online Boutique deployed to the `boutique` namespace
- Grafana port-forwarded to `localhost:3000`

---

## 1. Trace a Purchase End-to-End Across Microservices

**Goal:** Follow a single user checkout through every service hop using distributed tracing, then pivot seamlessly into the logs for each service involved.

**Steps:**

1. Open the Online Boutique frontend and complete a purchase (add items to cart, proceed to checkout, fill in details, place order).
2. In Grafana, open the **Tempo Trace Explorer** dashboard.
3. Filter by service `frontend` and look for a recent `POST /cart/checkout` span.
4. Click into the trace to open the waterfall view. You should see the full call chain: frontend -> checkoutservice -> cartservice, productcatalogservice, currencyservice, shippingservice, paymentservice, emailservice.
5. Note the total request duration and identify which service contributed the most latency.
6. Click the **Logs for this trace** link on any span -- this uses the pre-configured Tempo-to-Loki correlation to jump directly into Loki filtered by that trace ID.
7. In the Loki view, verify you can see structured log lines from the relevant service containing the same trace ID.

**What this demonstrates:** Full distributed tracing with automatic context propagation across gRPC microservices, and the power of trace-to-log correlation for root cause analysis.

---

## 2. Simulate a Service Failure and Watch Alerts Fire

**Goal:** Intentionally break a service and observe how Prometheus alerts, dashboards, and logs all react in real time.

**Steps:**

1. Open the **RED / Golden Signals** dashboard in Grafana. Note the current baseline error rate and latency.
2. Scale down the `paymentservice` deployment to zero replicas:
   ```bash
   kubectl scale deployment paymentservice -n boutique --replicas=0
   ```
3. The load generator will keep sending traffic. Within 1-2 minutes, observe:
   - **RED dashboard:** Error rate spikes for `checkoutservice` (upstream of payment).
   - **Pod Overview dashboard:** `paymentservice` pod count drops to 0; `checkoutservice` may begin showing restarts.
   - **Loki Log Explorer:** Filter by `checkoutservice` -- you should see error logs about failed gRPC calls to payment.
4. Check Grafana Alerting (bell icon in sidebar). The **HighErrorRate** alert should transition to `firing` (>5% HTTP 5xx sustained for 2 minutes).
5. Restore the service:
   ```bash
   kubectl scale deployment paymentservice -n boutique --replicas=1
   ```
6. Watch the error rate drop back to baseline and the alert resolve.

**What this demonstrates:** Real-time alerting with Prometheus, golden signal monitoring for service health, and how logs provide the diagnostic detail behind metric anomalies.

---

## 3. Explore the Service Dependency Map Under Load

**Goal:** Use the auto-generated service topology graph to understand how microservices communicate, and identify bottlenecks under varying load conditions.

**Steps:**

1. Open the **Service Dependency Map** dashboard in Grafana.
2. Observe the node graph showing all service-to-service connections. Each edge displays request rate, error rate, and p95 latency.
3. Identify the most heavily-called service (likely `productcatalogservice` or `currencyservice`) by looking at edge request rates.
4. Increase the load generator's request rate by scaling it up:
   ```bash
   kubectl scale deployment loadgenerator -n boutique --replicas=3
   ```
5. Watch the dependency map update over the next few minutes:
   - Edge request rates should increase across the board.
   - Look for any edges where p95 latency increases disproportionately -- these are potential bottlenecks.
6. Cross-reference with the **Kubernetes Cluster Overview** dashboard to see if node CPU or memory is approaching capacity.
7. Scale the load generator back down:
   ```bash
   kubectl scale deployment loadgenerator -n boutique --replicas=1
   ```

**What this demonstrates:** Automatic service topology discovery from trace data (via Tempo service graph metrics), and how infrastructure-level metrics correlate with application-level performance.

---

## 4. Debug Slow Requests Using the Three Pillars

**Goal:** Start from a high-level latency anomaly on a dashboard, drill into traces to find the slow span, then check logs for the root cause -- demonstrating the metrics-to-traces-to-logs investigation workflow.

**Steps:**

1. Open the **RED / Golden Signals** dashboard. Look at the Duration (p99) panel and identify any service with elevated latency (or inject latency -- see below).
2. To inject artificial latency, add a network delay to `productcatalogservice`:
   ```bash
   kubectl exec -it deploy/productcatalogservice -n boutique -- \
     env EXTRA_LATENCY=3s /src/server
   ```
   (Alternatively, restart the pod with the `EXTRA_LATENCY` environment variable set.)
3. Wait 2-3 minutes for the p99 latency panel to show the spike for `productcatalogservice`.
4. Switch to the **Tempo Trace Explorer** dashboard. Filter by service `productcatalogservice` and sort by duration descending.
5. Open one of the slow traces. In the waterfall, identify the span with the abnormal duration.
6. Use the trace-to-log link to jump into Loki. Look for log entries around that timestamp from `productcatalogservice` that explain the delay.
7. Check if the **HighLatency** alert has fired (p99 > 2s for 5 minutes).

**What this demonstrates:** The complete observability investigation loop -- starting from a metric anomaly, drilling into traces to identify the exact service and operation, then using correlated logs for root cause diagnosis.

---

## 5. Compare Infrastructure Metrics Against Application Behaviour

**Goal:** Demonstrate the relationship between Kubernetes resource utilisation and application performance by stressing the cluster and watching both infrastructure and application dashboards side-by-side.

**Steps:**

1. Open two browser tabs: the **Kubernetes Cluster Overview** dashboard and the **Node Exporter** dashboard.
2. Note the current baseline: node CPU %, memory %, pod counts.
3. Deploy a resource-hungry stress test pod:
   ```bash
   kubectl run stress --image=progrium/stress -n boutique -- \
     --cpu 2 --vm 2 --vm-bytes 512M --timeout 120s
   ```
4. In the **Node Exporter** dashboard, watch CPU and memory climb on the node where the stress pod landed.
5. Switch to the **Pod Overview** dashboard filtered to the `boutique` namespace. Check whether any Online Boutique pods show increased latency or resource pressure due to contention.
6. Open the **RED / Golden Signals** dashboard. Look for any degradation in request rate or increased latency that correlates with the resource pressure.
7. After 2 minutes the stress pod will self-terminate. Observe all metrics returning to baseline.
8. Clean up:
   ```bash
   kubectl delete pod stress -n boutique
   ```

**What this demonstrates:** How infrastructure-level resource contention (CPU, memory) directly impacts application performance, and why monitoring both layers is essential. Shows the value of having infrastructure and application dashboards in a single pane of glass.
