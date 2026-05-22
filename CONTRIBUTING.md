# Contributing

This is a personal showcase lab. Contributions are welcome but the scope is intentionally narrow: vanilla Kubernetes on AWS with kubeadm, OpenTofu, and cloud-init.

## Before opening a PR

Open an issue first to discuss the change. PRs without a prior issue may be closed without review.

## Conventions

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
- Run `tofu validate` in `tofu/envs/lab` before pushing
- No hardcoded IPs, account IDs, or credentials — use variables or SSM
- Add an ADR under `docs/decisions/` for non-trivial decisions

## Response time

This is a side project. There is no SLA on issue or PR responses.
