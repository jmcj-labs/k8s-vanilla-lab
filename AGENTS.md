# AGENTS.md

Repo-wide guidance for AI agents. See `CLAUDE.md` for the full project context and
critical rules (OpenTofu-not-Terraform, templatefile escaping, module layout, ADRs).

## Cursor Cloud specific instructions

This repo is **Infrastructure-as-Code** (OpenTofu + cloud-init for a kubeadm K8s lab on AWS).
There is **no runnable application/server and no unit-test suite** — the local dev loop is
IaC validation, linting, and security scanning.

### Toolchain
The startup update script installs the pinned toolchain: OpenTofu `1.8.0`, tflint `v0.62.1`,
trivy `v0.70.0`, `pre-commit`, `graphviz`, and `diagrams==0.25.1`. Always use `tofu`, never
`terraform` (see `CLAUDE.md` §1). `pre-commit` installs to `~/.local/bin` (already on `PATH`
in login shells).

### Primary dev / "test" commands (no AWS needed)
- `make validate` — the core check: `tofu fmt -check` + hermetic `tofu validate` (uses a temp
  `TF_DATA_DIR`, `-backend=false`; no S3 backend or AWS creds required).
- `pre-commit run --all-files` — runs all hooks (tofu-fmt, tflint, trivy, gitleaks, etc.).
  This is what CI (`.github/workflows/validate.yml`) enforces. Full hook list in
  `docs/development.md`.

### Non-obvious caveats
- `make validate` appends the `linux_amd64` provider hash to
  `tofu/envs/lab/.terraform.lock.hcl`. This is a harmless local artifact — do **not** commit it
  unless you are intentionally updating provider versions.
- `tofu console` does **not** work with `-backend=false`; it demands the real S3 backend. To
  render a `bootstrap/*.yaml` template locally, use a throwaway config in a temp dir with a local
  backend and an `output "x" { value = templatefile("/workspace/bootstrap/...", { ... }) }`.
- Deployment targets (`make init` / `plan` / `apply` / `destroy` / `kubeconfig` / `smoke-test`)
  require real AWS credentials + an S3/DynamoDB backend (`tofu/envs/lab/backend.hcl`) and cost
  money. They are **out of scope** for local dev in this environment.
- Regenerate the architecture diagram with `cd docs/architecture && python3 diagram.py` (needs
  `graphviz` + `diagrams`, installed by the update script); it overwrites `architecture.svg/png`.
