# Runbook post-apply — del cluster recién creado a la app desplegada

Secuencia operativa tras `make apply` (o el workflow Apply). Nace de las
tres fricciones reales del 15-ago: logins SSO que "no funcionan", `Token
has expired` en `make kubeconfig`, y variables de Repo 2 sin refrescar.

## 0. Logins — qué sesión SSO renueva qué

Tres perfiles, tres usos. Un `aws sso login` solo renueva **su** perfil:

| Perfil | Renueva | Lo usan |
|--------|---------|---------|
| `k8s-vanilla-lab` | la sesión de infra | tofu (`apply/plan/destroy` vía tfvars) y la CLI de los targets de make |
| `k8s-platform` | bridge de admin (ADR-005) | `make kubeconfig-admin` y tu kubectl diario como admin |
| `k8s-dev` | bridge de jm-dev | `make kubeconfig-dev` — **login desde incógnito con `--use-device-code`** (el navegador comparte cookie de portal; ver `platform/access/README.md`) |

Para el ciclo post-apply basta el primero:

```bash
aws sso login --profile k8s-vanilla-lab
```

> **Precondición de S2-1 (una sola vez, no por ciclo)**: las access keys de
> barman deben estar depositadas en SSM
> (`/k8s/persistent/<cluster>/cnpg-backup-keys`) — `make platform` falla
> con instrucciones si faltan. Alta y rotación en
> `tofu/envs/persistent/README.md`.

## 1. Kubeconfig — exporta el perfil o el login no te sirve

Los targets de CLI (`kubeconfig`, `platform`, `smoke-test`,
`smoke-app-contract`) **no llevan `--profile`**: resuelven del ambiente.
Sin `AWS_PROFILE` exportado usan el perfil `default` → `Token has expired`
aunque el login de arriba haya ido bien (tabla completa en
[CLUSTER.md](CLUSTER.md) §4):

```bash
export AWS_PROFILE=k8s-vanilla-lab     # o direnv con .envrc
make kubeconfig                        # → ~/.kube/k8s-vanilla-lab.conf
export KUBECONFIG=~/.kube/k8s-vanilla-lab.conf
kubectl get nodes                      # 4/4 Ready
```

## 2. Refresh de variables en logistics-lab (solo cambian 2)

Cada apply desde cero cambia `K8S_SERVER` y `K8S_CA_DATA`; el resto
(`K8S_CLUSTER_ID`, `AWS_ROLE_ARN`, `AWS_REGION`, `K8S_DEVELOPER_ROLE_ARN`)
es estable. Extrae ambos del kubeconfig de SSM y ponlos:

```bash
KC=$(aws ssm get-parameter --profile k8s-vanilla-lab --region eu-west-1 \
  --name /k8s/k8s-vanilla-lab/kubeconfig --with-decryption \
  --query Parameter.Value --output text)
gh variable set K8S_SERVER  --repo jmcj-labs/logistics-lab \
  --body "$(awk '$1=="server:"{print $2}' <<<"$KC")"
gh variable set K8S_CA_DATA --repo jmcj-labs/logistics-lab \
  --body "$(awk '$1=="certificate-authority-data:"{print $2}' <<<"$KC")"
```

## 3. Deploy y verificación

```bash
gh workflow run deploy.yml --repo jmcj-labs/logistics-lab   # build→scan→push→helm→e2e
# cuando termine, con el SHA que desplegó:
make smoke-app-contract GITHUB_SHA=<sha>
```

## Al final del día (destroy)

El espejo de este runbook: `make destroy` **+** borrar `K8S_SERVER` en
logistics-lab (su deploy queda en skipped, no en rojo) **+** barrer los
volúmenes EBS huérfanos del CSI. Pasos exactos en
[troubleshooting.md](troubleshooting.md).
