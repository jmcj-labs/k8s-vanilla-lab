# Architecture Diagram

`diagram.py` is the single source of truth for the architecture diagram. The SVG and PNG are generated outputs committed alongside the source.

## Files

| File | Purpose |
|------|---------|
| `diagram.py` | Source — edit this to change the diagram |
| `architecture.svg` | Primary output (rendered in GitHub Markdown) |
| `architecture.png` | Fallback output (for clients that don't render SVG) |

## Prerequisites

| Tool | macOS | Linux |
|------|-------|-------|
| Python 3.9+ | preinstalled | preinstalled |
| diagrams | `pip install diagrams==0.25.1` | `pip install diagrams==0.25.1` |
| graphviz | `brew install graphviz` | `apt-get install graphviz` |

Verify graphviz is installed:

```bash
dot -V
```

## Regenerating

```bash
cd docs/architecture
python3 diagram.py
```

This overwrites `architecture.svg` and `architecture.png` in place. Commit both outputs alongside any change to `diagram.py`.

## When to regenerate

- After adding or removing AWS resources in `tofu/`
- After changing network topology (subnets, IGW, security groups)
- After adding new IAM roles or SSM parameter paths
- Before opening a PR that includes infrastructure changes
