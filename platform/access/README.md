# Access module — human verification runbook

CI proves both profiles on every apply (smoke section 8, via the OIDC
entry). The HUMAN path — portal SSO → bridge permission set → stable role →
authenticator → RBAC — is verified manually once per identity, with this
runbook (ADR-005; brief v4 deliverable 6).

## Prerequisites

- `~/.aws/config` with the two **separate** `sso-session` blocks
  (`k8s-platform` / `k8s-dev`) and their profiles — separate on purpose:
  two different humans; one shared session would let a `jm-dev` login
  clobber the platform user's SSO cache. See the main README ("Access").
- `aws-iam-authenticator` client pinned at v0.7.18 (checksum-verified —
  `scripts/iam-kubeconfig.sh` refuses to run otherwise).
- Kubeconfigs generated with a profile that can read SSM (they contain no
  secrets): `make kubeconfig-admin` / `make kubeconfig-dev`.

## Platform admin (existing human user)

```bash
aws sso login --profile k8s-platform        # browser → your normal SSO user
export KUBECONFIG=~/.kube/k8s-vanilla-lab-admin.conf
export AWS_PROFILE=k8s-platform

kubectl auth whoami
# expected: Username platform-admin:<your-session>  ·  Groups [platform-admins system:authenticated]

kubectl get nodes
# expected: 3 nodes Ready — full cluster-admin via the platform-admins group
```

## Developer (jm-dev — the non-escalatable identity)

> **Browser-cookie gotcha (observed 2026-08-11)**: separate sso-sessions
> isolate the CLI caches, but the BROWSER shares the portal cookie — a
> plain `aws sso login` after the platform login authorizes the dev
> session as the WRONG user, and `GetRoleCredentials` fails with
> `ForbiddenException: No access` (correctly: that user has no
> K8sDevBridge assignment). Log in as jm-dev from a **private/incognito
> window** using device code:
>
> ```bash
> aws sso logout --sso-session k8s-dev        # drop any mis-issued token
> aws sso login --profile k8s-dev --use-device-code
> # open the printed URL in an INCOGNITO window, log in as jm-dev
> ```

> **ESTADO: flujo humano SSO VERIFICADO (31-ago-2026).** Login real en
> incógnito como `jm-dev`: `AWSReservedSSO_K8sDevBridge_.../jm-dev`,
> `get pods -n infra` denegado **por el API server**
> (`User "developer:jm-dev" cannot list resource "pods"`), y
> `get pods -n logistics` con acceso concedido. Se conserva el aviso de abajo
> porque el error del portal sigue existiendo y sigue siendo la prueba
> equivocada.
>
> **El aviso original:** Y el matiz que
> hace falta para que la verificación futura valga: este
> `ForbiddenException: No access` es un rechazo de **Identity Center** por la
> sesión del navegador, NO el `Forbidden` de **RBAC de Kubernetes** que exige
> el criterio de aceptación. Son dos errores distintos que se leen igual.
> Darlo por bueno validaría el módulo con la prueba equivocada. La prueba
> válida es un login real como `jm-dev` que termine en un `kubectl` denegado
> **por el API server**, no por el portal.

```bash
aws sso login --profile k8s-dev             # browser → log in AS jm-dev
export KUBECONFIG=~/.kube/k8s-vanilla-lab-dev.conf
export AWS_PROFILE=k8s-dev

kubectl auth whoami
# expected: Username developer:<session>  ·  Groups [developers system:authenticated]

kubectl get pods -n logistics
# expected: OK ("No resources found in logistics namespace." counts as OK)

kubectl get pods -n infra
# expected: Error from server (Forbidden) — this denial IS the feature
```

## Switching identities without mixing them up

The kubeconfig decides the CLUSTER identity (which role the exec block
assumes); `AWS_PROFILE` decides the AWS session that signs it. Always move
them **as a pair**:

```bash
# admin hat
export KUBECONFIG=~/.kube/k8s-vanilla-lab-admin.conf AWS_PROFILE=k8s-platform
# dev hat
export KUBECONFIG=~/.kube/k8s-vanilla-lab-dev.conf  AWS_PROFILE=k8s-dev
```

Mismatched pairs fail safe: the exec plugin's `sts:AssumeRole` is rejected
by the role's trust policy (each bridge can only assume its own role).

When a session expires, re-run the matching `aws sso login --profile …`;
nothing else changes (the kubeconfigs hold no credentials).

## Notes

- `mappings.yaml`/RBAC come from `profiles.yaml` (rendered by
  `platform/install.sh`) — never hand-edit the ConfigMap.
- Break-glass (`make kubeconfig`, static admin cert from SSM) stays for
  emergencies only — e.g. the window during bootstrap before the
  authenticator DaemonSet is up.
