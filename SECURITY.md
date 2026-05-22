# Security Policy

This is a personal lab project, not a production system. There is no formal security disclosure process or response SLA.

## Scope

This repo contains Infrastructure-as-Code for a short-lived, single-user Kubernetes lab on AWS. It is not intended to run production workloads or handle sensitive data.

## Reporting a vulnerability

If you find a security issue (e.g. credentials accidentally committed, insecure defaults in IaC), please open a GitHub issue. There is no private disclosure channel.

## Known limitations

- Cluster-admin kubeconfig is stored in SSM Parameter Store for CI use (see ADR-004). Acceptable for a lab; not appropriate for shared or long-lived environments.
- Worker nodes use spot instances and may be reclaimed without notice.
