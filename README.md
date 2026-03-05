# deploy-bootstrap

Ansible roles for infrastructure configuration management, security hardening and app deployment.

## Overview

Each role is self-contained and contains a vars file with the vars that role uses. They generally pull in `vars/default.yml` and `vars/<OS family>.yml` for OS-specific vars.

## Usage

`ansible-playbook -i localhost, -e var=value -c local tasks/playbook.yml`

These are not meant to be reference implementations, these are what I actually use to configure, deploy, and manage services in my infrastructure. A lot of this is tightly integrated with the rest of my infrastructure (ssm vars set in CloudFormation that control a lot of configuration variables for example). Those repos should be public soon also.

These were mostly written for Ubuntu. The core roles are already built with support for any Debian, AWS, or RHEL family system, but many of the application roles are only configured for Ubuntu. That's typically a few-line change per role though (maybe defining a RedHat package name, config file location, firewalld instead of ufw rules).

If you are on a modern Ubuntu then all required collections are built-in. For RHEL, depending which roles you run you may need the `community.general`, `ansible.posix`, or `amazon.aws` collections. If you run something else you probably know your OS well enough to have ansible configured properly.

## Notes

These are run locally on the node being configured as part of either golden image creation or initial bootstrapping of a production instance.

They are idempotent, but not designed for repeated runs as part of ongoing updates as the intended use-case (would cache downloads, parameterize more vars, separate playbooks into install/configure, etc).

Everything is designed for ephemeral storage, there are no stateful services in this repo.

## Roles

### System
- `common` - Base OS setup, package management, timezone, services, MOTD
- `common-security` - CIS benchmark hardening (SSH, PAM, auditd, AIDE, sysctl, kernel modules, cron, firewall, password policy)

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

### Infrastructure
- `etcd` - etcd key-value store
- `memcached` - Memcached with Prometheus exporter
- `vpn-wireguard` - WireGuard VPN server with route forwarding

### Applications
- `linnemanlabs-web-server` - LinnemanLabs site deployment with Cosign verification

## License

MIT. Copy it, steal it, modify it, learn from it, share your improvements with me. Or don't. It's code, do what you want with it.