# OpenTelemetry Instrumentation for Strato Control Plane

## Overview

This directory contains the OpenTelemetry (OTel) configuration for comprehensive observability of the Strato Control Plane, including:

- **Metrics**: Performance and usage metrics (request rates, latency, resource utilization)
- **Logs**: Structured application logs with correlation
- **Traces**: Distributed tracing for request flows

## Current Status

✅ **Fully Functional**

The OpenTelemetry instrumentation is now fully operational:
- Swift toolchain: **6.1.2** ✅
- swift-otel: **1.0.3** ✅
- All code compiles successfully
- Ready for deployment and testing

### Recent Updates

**2025-11-21**: Upgraded from Swift 6.0.2 to 6.1.2 to support swift-otel 1.0+. The modern API is now in use and all features compile without errors.

## Architecture

### Components

1. **Swift Application (Control Plane)**
   - Emits metrics, logs, and traces via swift-otel
   - Exports to OTel Collector via OTLP/gRPC (port 4317)

2. **OTel Collector**
   - Receives OTLP data from the application
   - Processes and enriches telemetry data
   - Exports to various backends:
     - Metrics → Prometheus (remote write + pull endpoint)
     - Traces → Jaeger (optional)
     - Logs → Loki (optional)

3. **Prometheus**
   - Stores metrics with 15-day retention
   - Provides query interface for metrics
   - Can be used with Grafana for visualization

4. **Grafana** (Optional, not included)
   - Visualizes metrics from Prometheus
   - Create dashboards for monitoring

## Files

### Configuration Files

- `otel-collector-config.yaml` - OTel Collector configuration for standalone deployment
- Helm templates in `../helm/strato-control-plane/templates/`:
  - `otel-collector-configmap.yaml` - Kubernetes ConfigMap for collector config
  - `otel-collector-deployment.yaml` - Collector deployment
  - `otel-collector-service.yaml` - Collector service
  - `prometheus-configmap.yaml` - Prometheus configuration
  - `prometheus-statefulset.yaml` - Prometheus with persistent storage
  - `prometheus-service.yaml` - Prometheus service

### Application Code

- `../control-plane/Sources/App/OTelLifecycleHandler.swift` - Manages OTel lifecycle
- `../control-plane/Sources/App/configure.swift` - OTel bootstrap and configuration

## Configuration

### Environment Variables

The Control Plane accepts the following OTel configuration via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OTEL_SERVICE_NAME` | `strato-control-plane` | Service name in traces and metrics |
| `OTEL_SERVICE_VERSION` | `1.0.0` | Service version |
| `OTEL_METRICS_ENABLED` | `true` | Enable metrics collection |
| `OTEL_LOGS_ENABLED` | `true` | Enable log export |
| `OTEL_TRACES_ENABLED` | `true` | Enable distributed tracing |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Auto-configured | OTLP endpoint URL (gRPC) |

### Kubernetes Deployment

When deployed via Helm, the OTel stack is automatically configured:

```bash
# Enable OTel in values.yaml (enabled by default)
opentelemetry:
  enabled: true
  collector:
    enabled: true
  prometheus:
    enabled: true

# Deploy with Skaffold
skaffold dev
```

### Access Prometheus

```bash
# Port-forward to Prometheus
kubectl port-forward -n strato-skaffold svc/strato-prometheus 9090:9090

# Access UI at http://localhost:9090
```

### Access OTel Collector Metrics

```bash
# Port-forward to collector metrics endpoint
kubectl port-forward -n strato-skaffold svc/strato-otel-collector 8888:8888

# View collector's own metrics at http://localhost:8888/metrics
```

## Metrics Collected

The swift-otel library automatically collects metrics from:

- **swift-metrics**: Application-level metrics emitted by Vapor and custom code
- **swift-log**: Log messages (when logs are enabled)
- **swift-distributed-tracing**: Distributed traces (when tracing is enabled)

### Custom Metrics

You can emit custom metrics in your application code:

```swift
import Metrics

// Counter
Counter(label: "api_requests_total", dimensions: [("endpoint", "/health")])
    .increment()

// Gauge
Gauge(label: "active_connections")
    .record(42)

// Histogram
Timer(label: "request_duration_seconds")
    .recordNanoseconds(duration)
```

## Adding Traces

To add tracing to specific operations:

```swift
import Tracing
import ServiceContextModule

func myOperation(context: ServiceContext) async throws {
    let span = InstrumentationSystem.tracer.startSpan("myOperation", context: context)
    defer { span.end() }

    // Your operation here
}
```

## Visualization

### Grafana Setup (Optional)

To add Grafana for visualization:

1. Deploy Grafana to Kubernetes
2. Add Prometheus as a data source
3. Import dashboards for:
   - HTTP request rates and latencies
   - Database query performance
   - WebSocket connection metrics
   - VM lifecycle operations

### Recommended Dashboards

- Swift Application Metrics (custom)
- Node Exporter Full (Prometheus)
- Kubernetes Cluster Monitoring (Prometheus)

## Troubleshooting

### Collector Not Receiving Data

Check the collector logs:
```bash
kubectl logs -n strato-skaffold deployment/strato-otel-collector
```

Verify the endpoint configuration:
```bash
kubectl get cm -n strato-skaffold strato-otel-collector -o yaml
```

### Prometheus Not Scraping

Check Prometheus targets:
```bash
# Port-forward and visit http://localhost:9090/targets
kubectl port-forward -n strato-skaffold svc/strato-prometheus 9090:9090
```

### Application Not Sending Metrics

1. Verify OTel is enabled in environment variables
2. Check application logs for OTel bootstrap messages
3. Verify network connectivity to collector

## Future Enhancements

Once Swift 6.1+ is available:

1. Complete the integration with swift-otel 1.0+
2. Add custom tracing spans for key operations:
   - VM lifecycle operations
   - Database queries
   - WebSocket messages
   - Authorization checks
3. Add custom metrics for:
   - Active VM count
   - WebSocket connections
   - Agent health status
4. Integrate with Jaeger for trace visualization
5. Integrate with Loki for log aggregation
6. Add Grafana dashboards

## References

- [swift-otel Documentation](https://swiftpackageindex.com/swift-otel/swift-otel/documentation)
- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Vapor Blog: OTel Integration](https://blog.vapor.codes/posts/otel-integration/)
