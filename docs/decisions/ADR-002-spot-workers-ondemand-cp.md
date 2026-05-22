# ADR-002: Spot Workers + On-Demand Control Plane

**Status**: Accepted  
**Date**: 2025-05-13  
**Deciders**: Platform Engineering Team

---

## Context

Running a Kubernetes lab cluster on AWS EC2 incurs costs that accumulate quickly. A 3-node cluster (1 control plane + 2 workers) using `t3.medium` instances (2vCPU, 4GB RAM) costs approximately:

- On-Demand: ~$0.042/hour × 3 nodes × 730 hours/month = **~$92/month**
- Spot (70% discount): ~$0.0126/hour × 3 nodes × 730 hours/month = **~$28/month**

However, EC2 Spot instances can be reclaimed by AWS with 2-minute notice when capacity is needed elsewhere. For a **lab environment** (not production), we need to balance cost savings against availability requirements.

---

## Decision

**Use a hybrid capacity model:**

1. **Control Plane**: On-Demand instance (always available)
2. **Worker Nodes**: Spot instances with configurable fallback to On-Demand

**Implementation**:
- Control plane: `t3.medium` On-Demand (1 node)
- Workers: `t3.medium` Spot (2 nodes default)
- Variable `worker_capacity_type` allows switching workers to On-Demand if needed

---

## Consequences

### Positive

- **Cost Reduction**: ~60% total savings ($92 → $36/month for default 1 CP + 2 workers)
- **Control Plane Stability**: Cluster always accessible, API server never interrupted
- **Worker Interruption Tolerance**: Stateless workers can be replaced without data loss
- **Flexibility**: `worker_capacity_type = "on-demand"` variable for critical workloads
- **Graceful Degradation**: Cluster remains functional with 1 worker if 1 spot reclaimed

### Negative

- **Worker Interruptions**: Spot workers can be terminated with 2-minute notice
- **Workload Disruption**: Running pods on spot workers will be evicted on reclamation
- **Inconsistent Availability**: Worker count may temporarily drop during spot reclamation
- **Not Production-Ready**: This pattern is unsuitable for production workloads without additional safeguards

### Mitigations

- Document spot interruption behavior explicitly in README
- Configure spot instances with `instance_interruption_behavior = "stop"` for manual stops (AWS reclamations always terminate regardless)
- Provide clear variable (`worker_capacity_type`) to switch to On-Demand for critical testing
- Tag workers with `WorkerIndex` for identification and replacement

---

## Alternatives Considered

### Alternative 1: All On-Demand

**Rejected** because:
- **Cost**: $92/month is 2.6× more expensive than hybrid model
- **Overkill**: Lab environments don't require 99.9% uptime
- **Learning Opportunity**: Spot instances teach cloud cost optimization

### Alternative 2: All Spot (including control plane)

**Rejected** because:
- **Cluster Unavailability**: Control plane reclamation makes entire cluster inaccessible
- **State Loss Risk**: etcd data loss if control plane spot instance terminated
- **Backup Complexity**: Requires automated etcd backups to S3 for disaster recovery
- **User Experience**: Cluster going offline unexpectedly is frustrating for learning

### Alternative 3: EKS Managed Control Plane

**Rejected** because:
- **Cost**: EKS control plane costs $0.10/hour ($73/month) alone
- **Learning Goal**: This is a **vanilla Kubernetes** lab for learning kubeadm, not managed services
- **Lock-in**: EKS-specific patterns don't transfer to other clouds or on-prem

### Alternative 4: Spot Fleet with On-Demand Fallback

**Rejected** because:
- **Complexity**: Spot Fleet adds significant Terraform complexity
- **Overkill**: Not needed for lab with 2 workers
- **Maintenance**: Spot Fleet configuration is harder to debug and maintain

---

## Cost Comparison (t3.medium, us-east-1, 730 hours/month)

| Configuration | Hourly | Monthly | Savings |
|---------------|--------|---------|---------|
| 3× On-Demand | $0.126 | $92 | Baseline |
| 1 OD + 2 Spot | $0.0546 | $36 | **60%** |
| 3× Spot | $0.0378 | $28 | **70%** (but risky) |

---

## References

- [AWS Spot Instance Pricing](https://aws.amazon.com/ec2/spot/pricing/)
- [EC2 Instance Interruption Behavior](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
- [Kubernetes Spot Best Practices](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/)
