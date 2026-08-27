# Development Guide

Local development workflow for contributors. Covers pre-commit hooks, manual validation, and debugging.

---

## 1. Prerequisites

In addition to the tools listed in the [Bootstrap Guide](bootstrap.md), local development requires:

| Tool | macOS | Linux |
|------|-------|-------|
| pre-commit | `pip install pre-commit` or `brew install pre-commit` | `pip install pre-commit` |
| tflint | `brew install tflint` | `curl -sfL https://github.com/terraform-linters/tflint/releases/download/v0.62.1/tflint_linux_amd64.zip -o /tmp/tflint.zip && unzip /tmp/tflint.zip -d /usr/local/bin` |
| trivy | `brew install trivy` | `curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/v0.70.0/contrib/install.sh \| sh -s -- -b /usr/local/bin v0.70.0` |
| Python 3.9+ | preinstalled | preinstalled |
| graphviz | `brew install graphviz` | `apt-get install graphviz` |
| GNU coreutils (for `timeout`) | `brew install coreutils` | preinstalled |

gitleaks is installed automatically by pre-commit on first run (via `language: golang`).

### GNU `timeout` on macOS

`scripts/smoke-test.sh` bounds its two NLB target-health polls with GNU
`timeout`, which macOS does not ship. **`brew install coreutils` does not by
itself put a binary named `timeout` on your `PATH`** — Homebrew installs the
GNU tools with a `g` prefix to avoid shadowing the system ones. The script
therefore accepts either name and prefers `timeout`:

```bash
timeout   # if present
gtimeout  # the Homebrew-prefixed name, used as the fallback
```

So `brew install coreutils` is enough. If you would rather have the unprefixed
names for everything, add the gnubin directory to your `PATH`:

```bash
PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"
```

The script fails fast at startup when neither name is found, before creating
any temporary cluster resources — a missing tool must never be reported as a
sick cluster (INCIDENTS #17's shape, pointing the other way).

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

The `validate` workflow (`.github/workflows/validate.yml`) runs `pre-commit/action@v3.0.1` against every PR and push to `main`. Any hook failure blocks the merge. CI installs Trivy via `aquasecurity/setup-trivy@v0.2.6` and tflint via `terraform-linters/setup-tflint@v6.2.2`; gitleaks is installed automatically by pre-commit.

---

## 8. Regenerating the architecture diagram

The diagram source lives in `docs/architecture/diagram.py`. After any infrastructure change:

```bash
pip install diagrams==0.25.1   # first time only
cd docs/architecture
python3 diagram.py             # overwrites architecture.svg and architecture.png
git add architecture.svg architecture.png
```

See [docs/architecture/README.md](architecture/README.md) for full prerequisites and regeneration details.

---

## 9. Dependency updates (Dependabot)

GitHub-native automation that opens PRs to bump dependency versions weekly.
Configured in `.github/dependabot.yml`. Monitors two ecosystems:

- **github-actions** — pins like `actions/checkout@v4` in workflow files get bumped
  when a new major version is released.
- **terraform** — the AWS provider `version` constraint in `tofu/envs/lab/` gets
  bumped when HashiCorp publishes a new release.

Each PR is labeled `dependencies` and arrives with the upstream changelog inline,
so review is straightforward: check the changelog for breaking changes, run CI,
merge if green.

### PR handling by type

| Type | Example | Risk | Action |
|------|---------|------|--------|
| GitHub Actions bump | `actions/checkout` 4→6 | Low | Merge when CI green |
| Provider minor bump | `hashicorp/aws` 5.x→5.y | Low | Merge when CI green |
| Provider major bump | `hashicorp/aws` 5.x→6.x | **High** | Review CHANGELOG for breaking changes before merging |

### Stale CI on Dependabot PRs

If a Dependabot PR was opened before a fix landed on `main`, its CI check may show
"Waiting for status to be reported" and never trigger. Fix: comment on the PR:

```
@dependabot rebase
```

This rebases the branch onto the updated `main` and triggers a fresh CI run.

This complements the explicit version pinning of Kubernetes, containerd, and
Cilium in `bootstrap/common.yaml` and `bootstrap/control-plane.yaml` — pinning
controls *when* you update, Dependabot surfaces *what* is available to update.
