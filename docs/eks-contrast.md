# Contraste honesto: este control plane HA vs EKS

**Pieza**: S2-3 (ADR-007). Una página, sin vender: la topología de este lab
**no es equivalente a EKS** — EKS es un control plane multi-AZ gestionado.
Este documento existe para que nadie confunda "sobrevive a perder un nodo"
con "sobrevive a perder una zona" ni "yo opero etcd" con "AWS opera etcd".

| Dimensión | Este lab (kubeadm HA, pieza 3) | EKS |
|---|---|---|
| **Responsabilidad del control plane** | Nuestra, entera: etcd (quorum, compactación, restore), API servers, certificados, authenticator en cada CP | De AWS: etcd y API servers invisibles, SLA 99.95% |
| **Topología** | 3 CPs t3.medium, etcd stacked, **una sola AZ** (HA de nodo, no zonal — deuda post-S2 declarada) | Control plane **multi-AZ siempre**, mínimo 2 réplicas de API server en zonas distintas |
| **Endpoint del API** | DNS del NLB propio, TCP/6443 passthrough; **cambia en cada destroy/apply** (refresh de `K8S_SERVER` vivo) | Endpoint gestionado estable con opciones público/privado; no muere con los nodos |
| **Pérdida de un CP** | Sobrevive (drill de aceptación); el reemplazo es **ceremonia nuestra** (tofu + join secuenciado + renovación del certificate-key si >2h) | Invisible: AWS repone réplicas automáticamente, nadie se entera |
| **Pérdida de la AZ** | Cluster muerto; camino = restore HA desde S3 (runbook probado) | El control plane sigue (multi-AZ); los nodos de esa AZ se reponen vía ASG en otras |
| **Upgrades del control plane** | Nuestros, nodo a nodo con kubeadm (pieza 4 — el motivo de esta pieza) | `aws eks update-cluster-version`: AWS rota los API servers; nosotros solo los nodos |
| **Backup/restore de etcd** | Nuestro: CronJob → S3 + ceremonia `etcdutl` con bump-revision (runbook + drill) | No existe como concepto expuesto: AWS lo opera; el usuario hace backup de RECURSOS (Velero), no de etcd |
| **Autenticación IAM** | aws-iam-authenticator operado por nosotros (DaemonSet + material por nodo) | Integrada (access entries / aws-auth), sin servidor que operar |
| **Coste del control plane** | ~3× t3.medium on-demand + IPv4 (≈2,7-2,9 $/día extra sobre 1 CP) | 0,10 $/h ≈ 2,4 $/día por cluster, plano |
| **Valor de aprendizaje** | Total: cada pieza de arriba es visible y rompible | Cero por diseño: todo lo interesante está detrás del telón |

## La frase para dirección

Con la pieza 3 compramos **la mitad de EKS que se puede comprar con nodos**:
supervivencia a la pérdida de un CP y un endpoint estable dentro de la
encarnación. Lo que **no** compramos — y EKS regala — es multi-AZ, reemplazo
automático de CPs y upgrades del plano invisibles. Ese contraste es el motivo
de este lab: operar lo que EKS esconde, sabiendo exactamente qué esconde.
