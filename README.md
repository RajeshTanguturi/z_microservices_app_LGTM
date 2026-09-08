                    Internet
                       │
                       ▼
              Route 53 / Vercel DNS
                       │
          demoapp.rajesh.top
       grafanademo.rajesh.top
                       │
                       ▼
              AWS Application
              Load Balancer
                       │
                HTTPS :443
              ACM certificate
                       │
        ┌──────────────┴──────────────┐
        │                             │
        ▼                             ▼
    demoapp.rajesh.top          grafanademo.rajesh.top
        │                             │
        ▼                             ▼
    frontend target group        grafana target group
        │                             │
        ▼                             ▼
    frontend pod(s)                Grafana pod
                    
                    
                    
                  
                    
                    
                    
                    
                    
                    
                    
                    ┌──────────────────────┐
                    │   Online Boutique    │
                    │   Microservices      │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │ OpenTelemetry        │
                    │ Collector            │
                    │ DaemonSet             │
                    └─────┬─────┬─────┬────┘
                          │     │     │
                ┌─────────┘     │     └─────────┐
                ▼               ▼               ▼
          ┌──────────┐    ┌──────────┐    ┌──────────┐
          │Prometheus│    │   Loki   │    │  Tempo   │
          │ Metrics  │    │   Logs   │    │  Traces  │
          └─────┬────┘    └─────┬────┘    └─────┬────┘
                │               │               │
                └───────────────┼───────────────┘
                                ▼
                         ┌─────────────┐
                         │   Grafana   │
                         │ Visualization│
                         └─────────────┘





Run the deploy.sh 
