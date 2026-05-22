# ADR-001: OpenTofu vs Terraform

**Status**: Accepted  
**Date**: 2025-05-13  
**Deciders**: Platform Engineering Team

---

## Context

HashiCorp changed Terraform's license from MPL 2.0 to BSL (Business Source License) in August 2023, restricting commercial use and forking. OpenTofu emerged as a community-driven, Linux Foundation-backed fork maintaining the MPL 2.0 license.

For a golden path infrastructure repository intended for learning, collaboration, and potential commercial use, we needed to choose between:
- Continuing with Terraform (BSL license, vendor lock-in risk)
- Migrating to OpenTofu (MPL 2.0, community-driven, Terraform-compatible)

---

## Decision

**We will use OpenTofu for all infrastructure-as-code.**

All tooling, documentation, and CI/CD pipelines will reference `tofu` commands and `opentofu/setup-opentofu` GitHub Actions, not Terraform equivalents.

---

## Consequences

### Positive

- **License Freedom**: MPL 2.0 allows unrestricted commercial and educational use
- **Community Governance**: Linux Foundation stewardship reduces vendor lock-in risk
- **Terraform Compatibility**: 1:1 command parity (`tofu` replaces `terraform`), no syntax changes
- **Ecosystem Support**: Major providers (AWS, Azure, GCP) committed to OpenTofu compatibility
- **Ethical Alignment**: Supports open-source principles over proprietary licensing

### Negative

- **Adoption Risk**: OpenTofu is newer (less mature) than Terraform
- **Documentation Gap**: Most existing guides reference Terraform, not OpenTofu
- **Tool Confusion**: Mixed ecosystem may confuse newcomers unfamiliar with the fork
- **Long-term Uncertainty**: OpenTofu's future depends on community momentum

### Mitigations

- Pin OpenTofu version in GitHub Actions (`tofu_version: 1.8.0`) for stability
- Document OpenTofu usage explicitly in README and CLAUDE.md
- Maintain compatibility with Terraform syntax to allow easy migration if needed

---

## Alternatives Considered

### Alternative 1: Continue with Terraform

**Rejected** because:
- BSL license restricts commercial use cases
- HashiCorp's pricing model and future direction uncertain
- Risk of vendor lock-in with proprietary features

### Alternative 2: Use Pulumi or CDK for Terraform (CDKTF)

**Rejected** because:
- Pulumi uses imperative programming (TypeScript/Python), not declarative HCL
- CDKTF adds unnecessary abstraction layer over Terraform/OpenTofu
- HCL is the industry standard for infrastructure-as-code
- Learning curve for HCL is valuable for platform engineers

### Alternative 3: CloudFormation (AWS-specific)

**Rejected** because:
- AWS-only (vendor lock-in)
- Verbose YAML/JSON syntax compared to HCL
- Limited ecosystem compared to Terraform/OpenTofu

---

## References

- [OpenTofu Announcement](https://opentofu.org/blog/opentofu-is-going-ga/)
- [Terraform License Change](https://www.hashicorp.com/blog/hashicorp-adopts-business-source-license)
- [Linux Foundation Press Release](https://www.linuxfoundation.org/press/opentofu-announces-fork-of-terraform)
