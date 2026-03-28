# deploy-bootstrap

Ansible roles for infrastructure configuration management, security hardening and app deployment.

## Overview

Each role is self-contained with its own defaults and templates. Infrastructure-specific configuration (endpoints, ARNs, resource IDs) is pulled from AWS SSM Parameter Store at runtime, set by CloudFormation stacks. Application-level config (versions, ports, TTLs, tuning) lives in role defaults.

Roles generally pull in `vars/default.yml` and `vars/<OS family>.yml` for OS-specific configuration.

## Usage
```
ansible-playbook -i localhost, -e var=value -c local playbook.yml
```
### Requirements
```
ansible-galaxy collection install -r requirements.yml
```
These are not meant to be reference implementations, these are what I actually use to configure, deploy, and manage services across ~200 nodes in production. A lot of this is tightly integrated with the rest of my infrastructure (SSM parameters set in CloudFormation, cross-account KMS signing, OIDC federation). Those repos should be public soon.

These were mostly written for Ubuntu. The core roles support any Debian, Amazon Linux, or RHEL family system, but many application roles are only configured for Ubuntu. That's typically a few-line change per role (package name, config path, firewalld instead of ufw rules).

## Notes

These are run locally on the node being configured as part of either golden image creation or initial bootstrapping of a production instance.

They are idempotent, but not designed for repeated runs as part of ongoing updates as the intended use-case (would cache downloads, parameterize more vars, separate tasks into install/configure, etc).

All nodes are designed for ephemeral local storage. State is stored in RDS, S3, SecretsManager, SSM, etc - no role depends on local disk persistence.

## Architecture

### Supply Chain & Trust

```mermaid
graph LR
    subgraph "Build & Sign"
        A[GitHub Push] --> B[GitHub Actions]
        B -->|OIDC Token| M[Fulcio]
        M -->|Ephemeral Cert| B
        M -->|Certificate Log| CT[TesseraCT]
        B --> C[Cosign Sign via KMS]
        C -->|Request Timestamp| N[Timestamp Authority]
        N -->|RFC 3161 Token| C
        C --> D[Attestation → Rekor]
        C -->|Binary + Bundle| S3[S3]
        D -->|Transparency| O[Tessera/S3]
        CT -->|Transparency| O
    end

    subgraph "Deploy & Verify"
        F[Node Bootstrap] <-->|Fetch| S3
        F --> G[Cosign Verify + SHA256]
        G --> H[Atomic Deploy]
        H --> R[Running Workload]
    end

    subgraph "Node Identity"
        J[SPIRE Server] <-->|Upstream CA| SM[AWS Secrets Manager]
        J[SPIRE Server] <-->|Leaf Signing| L[AWS KMS]
        K[SPIRE Agent] -->|Attest + Fetch SVID| J
        J -->|SVID + Registrations| K
        K -->|Workload SVID| R
    end
```

Binaries are built in GitHub Actions using my [build system](https://github.com/keithlinneman/build-system), signed with Cosign via KMS, timestamped via timestamp-authority, and logged to Rekor and TesseraCT for transparency. Nodes fetch artifacts from S3 and verify signatures and checksums before deploying. SPIRE provides runtime workload identity via SPIFFE SVIDs backed by a KMS upstream certificate authority signed by a YubiKey-backed root CA.

### Observability & Alerting

```mermaid
graph LR
    subgraph "Collection"
        R[Workloads] -->|metrics| NE[Node Exporter]
        R -->|metrics| EB[eBPF Exporter]
        R -->|profiles| AL[Alloy]
        R -->|logs/traces| OT[OTel Collector]
    end

    subgraph "Aggregation"
        NE <--> P[Prometheus]
        EB <--> P
    end

    subgraph "Storage & Query"
        P -->|remote write| MI[Mimir]
        OT -->|logs| LO[Loki]
        OT -->|traces| TE[Tempo]
        AL -->|profiles| PY[Pyroscope]
        TE -->|metrics-generator| MI
    end

    subgraph "Visualization & Alerting"
        GR[Grafana] --> MI
        GR --> LO
        GR --> TE
        GR --> PY
        P --> AM[Alertmanager]
        AM --> VI[Vigil]
        VI -->|Claude API| AI[AI Triage]
        AI --> SL[Slack]
        AM --> SL[Slack]
    end
```

Metrics are scraped by per-account Prometheus instances and remote-written to Mimir for long-term storage. Logs and traces flow through OTel Collector to Loki and Tempo. Alloy handles continuous profiling to Pyroscope and also forwards instrumented application profiles. Tempo generates RED metrics from traces back to Mimir. Alerts route through Alertmanager to both Slack and [Vigil](https://github.com/linnemanlabs/vigil), which uses the Claude API to query Prometheus, Loki, and AWS at alert time and post AI-assisted triage to Slack.

### Security Monitoring

```mermaid
graph LR
    subgraph "Endpoint Agents"
        OQ[osquery]:::agent -->|results log| WA[Wazuh Agent]:::agent
        WA -->|FIM, SCA, rootcheck| LD[Local Detection]:::agent
        LD -->|events| WA
    end

    subgraph "Agent Traffic"
        NLB[NLB]:::infra
    end

    subgraph "User Traffic"
        ALB[ALB]:::infra
    end

    WA -->|events 1514| NLB
    WA -->|enrollment 1515| MM

    subgraph "Manager Cluster"
        subgraph MASTER[Master]
            MM[Manager Master]:::manager
        end
        subgraph WORKERS[Workers]
            MW1[Manager Worker 1]:::manager
            MW2[Manager Worker 2]:::manager
        end
        MM <-->|cluster 1516| MW1
        MM <-->|cluster 1516| MW2
    end

    NLB --> MASTER
    NLB --> WORKERS

    subgraph INDEXERS[Indexer Cluster]
        IDX1[Indexer 1]:::indexer
        IDX2[Indexer 2]:::indexer
        IDX3[Indexer 3]:::indexer
        IDX1 <-->|transport 9300| IDX2
        IDX2 <-->|transport 9300| IDX3
    end

    MASTER -->|Filebeat direct| INDEXERS
    WORKERS -->|Filebeat direct| INDEXERS
    INDEXERS -->|segments + translog| S3[S3 Remote Store]:::storage

    subgraph "Visualization"
        DB[Dashboard]:::dashboard
    end

    USER[User/VPN]:::infra -->|HTTPS 443| ALB
    ALB -->|5601| DB
    DB -->|API 55000 direct| MM
    DB -->|queries 9200| ALB
    ALB -->|9200| INDEXERS

    classDef agent fill:#2d5a3d,stroke:#4a9,color:#fff
    classDef manager fill:#4a3d5a,stroke:#96c,color:#fff
    classDef indexer fill:#3d4a5a,stroke:#69c,color:#fff
    classDef storage fill:#5a4a2d,stroke:#c96,color:#fff
    classDef dashboard fill:#2d4a5a,stroke:#6cc,color:#fff
    classDef infra fill:#3a3a3a,stroke:#999,color:#fff
```

Wazuh provides host intrusion detection, file integrity monitoring, vulnerability detection, and CIS compliance scanning across all nodes. Agents report to a clustered manager which ships alerts via Filebeat to an S3-backed OpenSearch indexer cluster. osquery provides deep endpoint visibility with BPF process tracing, listening port snapshots, and system inventory. All component TLS is backed by KMS-signed certificates chained to a YubiKey root CA.

## Roles

### System
- `common` - Base OS setup, package management, timezone, swap, services, MOTD
- `common-security` - CIS benchmark hardening (SSH, PAM, auditd, AIDE, sysctl, kernel modules, cron, firewall, password policy, AppArmor)
- `bastion` - Bastion/jump host configuration

### Observability
- `prometheus` - Prometheus server, blackbox exporter, scrape configs, recording and alerting rules
- `prometheus-monitored-instance` - Node exporter and eBPF exporter for monitored instances
- `mimir` - Grafana Mimir long-term metrics storage
- `loki` - Grafana Loki log aggregation
- `tempo` - Grafana Tempo distributed tracing
- `pyroscope` - Grafana Pyroscope continuous profiling
- `grafana` - Grafana visualization and dashboards
- `alertmanager` - Prometheus Alertmanager with cluster peering
- `alloy` - Grafana Alloy telemetry collector
- `otel-collector` - OpenTelemetry Collector with journald, syslog, and OTLP pipelines
- `vigil` - AI-Powered alert analysis and triage. [Vigil sourcecode on GitHub](https://github.com/linnemanlabs/vigil)

### Trust & Transparency
- `spire-server` - SPIFFE/SPIRE server with KMS-backed leaf signing and PostgreSQL datastore
- `spire-agent` - SPIRE agent with workload attestation
- `fulcio` - Sigstore Fulcio certificate authority for keyless code signing
- `rekor-tiles` - Sigstore Rekor transparency log (v2/Tessera backend)
- `tesseract` - TesseraCT certificate transparency log
- `timestamp-authority` - Sigstore Timestamp Authority (RFC 3161)

### Security
- `wazuh-indexer` - Wazuh indexer cluster (OpenSearch) with S3 remote-backed storage, KMS-signed component certificates
- `wazuh-manager` - Wazuh manager cluster with Filebeat alert shipping, clustered master/worker topology
- `wazuh-dashboard` - Wazuh dashboard (OpenSearch Dashboards) with Wazuh plugin
- `wazuh-agent` - Wazuh agent for endpoint monitoring, file integrity, SCA, vulnerability detection
- `osquery` - osquery endpoint visibility with BPF process monitoring, scheduled queries, and Wazuh integration

### Infrastructure
- `memcached` - Memcached with Prometheus exporter
- `vpn-wireguard` - WireGuard VPN server with route forwarding

### Applications
- `linnemanlabs-web-server` - LinnemanLabs webserver deployment with Cosign verification
- `linnemanlabs-trust-portal` - LinnemanLabs trust portal deployment with Cosign verification

## License

MIT. Copy it, steal it, modify it, learn from it, share your improvements with me. Or don't. It's code, do what you want with it.