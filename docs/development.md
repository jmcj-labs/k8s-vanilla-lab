# Development Guide

Local development workflow for contributors. Covers pre-commit hooks, manual validation, and debugging.

---

## 1. Prerequisites

In addition to the tools listed in the [Bootstrap Guide](bootstrap.md), local development requires:

| Tool | Version | Install |
|------|---------|---------|
| pre-commit | ≥3.x | `pip install pre-commit` or `brew install pre-commit` |
| trivy | v0.70.0+ | `brew install trivy` / [aquasecurity/trivy releases](https://github.com/aquasecurity/trivy/releases) |

tflint and gitleaks are installed automatically by pre-commit on first run (via `language: golang`).

---

## 2. Installing the hooks

After cloning the repo, run once:

```bash
pre-commit install
```

This installs the hooks into `.git/hooks/pre-commit`. From this point, hooks run automatically on every `git commit`.

---

## 3. What the hooks check

| Hook | When it runs | What it checks |
|------|-------------|----------------|
| `trailing-whitespace` | always | Trailing spaces (Markdown two-space linebreaks preserved) |
| `end-of-file-fixer` | always | Files end with a single newline |
| `check-yaml` | always | YAML syntax (`bootstrap/` excluded — shell scripts named `.yaml`) |
| `check-added-large-files` | always | No file > 500 KB staged |
| `check-merge-conflict` | always | No leftover `<<<<<<<` markers |
| `detect-private-key` | always | No PEM/private key material staged |
| `mixed-line-ending` | always | Consistent line endings |
| `tofu-fmt` | on `.tf` changes | `tofu fmt -check -recursive tofu/` |
| `terraform_tflint` | on `.tf` changes | tflint with AWS ruleset (downloads plugins on first run) |
| `trivy-config` | on `.tf` changes | IaC scan for HIGH/CRITICAL misconfigurations |
| `gitleaks` | always | Secret detection |

---

## 4. Running manually

Run all hooks against every file in the repo (useful before opening a PR):

```bash
pre-commit run --all-files
```

Run a single hook:

```bash
pre-commit run trailing-whitespace --all-files
pre-commit run tofu-fmt --all-files
pre-commit run trivy-config --all-files
```

---

## 5. Skipping hooks (when justified)

For commits that don't need hook validation (e.g., a docs-only typo fix after hours):

```bash
git commit --no-verify -m "docs: fix typo"
```

Use sparingly — CI will catch anything skipped locally.

---

## 6. Updating hook versions

Hooks are pinned to specific revisions in `.pre-commit-config.yaml`. To update all hooks to their latest compatible version:

```bash
pre-commit autoupdate
```

Review the diff before committing — major version bumps may introduce breaking changes. Dependabot is configured to open PRs for hook updates weekly (see `.github/dependabot.yml`).

---

## 7. CI enforcement

The `validate` workflow (`.github/workflows/validate.yml`) runs `pre-commit/action@v3.0.1` against every PR and push to `main`. Any hook failure blocks the merge. CI installs Trivy via `aquasecurity/setup-trivy`; tflint and gitleaks are installed automatically by pre-commit.
