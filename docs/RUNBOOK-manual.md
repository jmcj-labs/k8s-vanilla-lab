> **Documento histórico** de la ejecución manual del 2026-08-10. Refleja lo
> ejecutado tal cual, incluidas versiones ya superadas (1.35.5→1.35.7,
> Cilium 1.19.4→1.19.6). Los fixes están consolidados en
> [docs/INCIDENTS.md](INCIDENTS.md) y en la IaC — no usar como referencia viva.

# Sprint logistics-lab — Runbook de montaje manual (Día 1-2)

Desde AWS CloudShell hasta cluster completo con toda la plataforma que la app necesita.
Región: `eu-west-1`. Todo copy-paste, en orden. Cada bloque termina con su validación.

---

## FASE A — Infraestructura AWS (desde CloudShell)

### A.0 Variables de sesión

```bash
export AWS_REGION=eu-west-1
export CLUSTER=logistics-sprint
export MY_IP=$(curl -s https://checkip.amazonaws.com)/32
echo "Mi IP: $MY_IP"
```

### A.1 VPC y red

```bash
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$CLUSTER-vpc},{Key=Project,Value=$CLUSTER}]" \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support

SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 \
  --availability-zone ${AWS_REGION}a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$CLUSTER-public}]" \
  --query 'Subnet.SubnetId' --output text)

aws ec2 modify-subnet-attribute --subnet-id $SUBNET_ID --map-public-ip-on-launch

IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$CLUSTER-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$CLUSTER-rt}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_ID

echo "VPC=$VPC_ID SUBNET=$SUBNET_ID"
```

**Validación:** `aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].State'` → `available`

### A.2 Security Groups

```bash
SG_CP=$(aws ec2 create-security-group --group-name $CLUSTER-cp --description "control plane" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)
SG_WK=$(aws ec2 create-security-group --group-name $CLUSTER-worker --description "workers" \
  --vpc-id $VPC_ID --query 'GroupId' --output text)

# CP: SSH y API desde mi IP
aws ec2 authorize-security-group-ingress --group-id $SG_CP --protocol tcp --port 22 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_CP --protocol tcp --port 6443 --cidr $MY_IP
# CP: todo desde workers y desde sí mismo (etcd, kubelet, cilium vxlan/health)
aws ec2 authorize-security-group-ingress --group-id $SG_CP --protocol -1 --source-group $SG_WK
aws ec2 authorize-security-group-ingress --group-id $SG_CP --protocol -1 --source-group $SG_CP
# Workers: SSH desde mi IP, NodePort desde mi IP, todo desde CP y entre sí
aws ec2 authorize-security-group-ingress --group-id $SG_WK --protocol tcp --port 22 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_WK --protocol tcp --port 30000-32767 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_WK --protocol -1 --source-group $SG_CP
aws ec2 authorize-security-group-ingress --group-id $SG_WK --protocol -1 --source-group $SG_WK

echo "SG_CP=$SG_CP SG_WK=$SG_WK"
```

### A.3 IAM (EBS CSI vía instance profile)

```bash
cat > trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF

aws iam create-role --role-name $CLUSTER-node --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name $CLUSTER-node \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws iam create-instance-profile --instance-profile-name $CLUSTER-node
aws iam add-role-to-instance-profile --instance-profile-name $CLUSTER-node --role-name $CLUSTER-node
sleep 10   # propagación IAM
```

### A.4 Key pair

```bash
aws ec2 create-key-pair --key-name $CLUSTER-key --query 'KeyMaterial' --output text > ~/$CLUSTER.pem
chmod 400 ~/$CLUSTER.pem
```

⚠️ CloudShell es efímero por región pero el home persiste. Aun así, descárgate el .pem (Actions → Download file) hoy mismo.

### A.5 Instancias EC2

```bash
AMI=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query 'Parameter.Value' --output text)

# Control plane — on-demand
CP_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.medium \
  --key-name $CLUSTER-key --subnet-id $SUBNET_ID --security-group-ids $SG_CP \
  --iam-instance-profile Name=$CLUSTER-node \
  --metadata-options HttpTokens=required \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$CLUSTER-cp},{Key=Project,Value=$CLUSTER}]" \
  --query 'Instances[0].InstanceId' --output text)

# Workers — spot
for i in 1 2; do
aws ec2 run-instances --image-id $AMI --instance-type t3.medium \
  --key-name $CLUSTER-key --subnet-id $SUBNET_ID --security-group-ids $SG_WK \
  --iam-instance-profile Name=$CLUSTER-node \
  --metadata-options HttpTokens=required \
  --instance-market-options 'MarketType=spot,SpotOptions={SpotInstanceType=one-time}' \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","Encrypted":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$CLUSTER-w$i},{Key=Project,Value=$CLUSTER}]" \
  --query 'Instances[0].InstanceId' --output text
done

aws ec2 wait instance-running --filters "Name=tag:Project,Values=$CLUSTER"

# EIP para el CP (IP estable para el certSAN de kubeadm)
EIP_ALLOC=$(aws ec2 allocate-address --query 'AllocationId' --output text)
aws ec2 associate-address --instance-id $CP_ID --allocation-id $EIP_ALLOC
CP_IP=$(aws ec2 describe-addresses --allocation-ids $EIP_ALLOC --query 'Addresses[0].PublicIp' --output text)

W_IPS=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$CLUSTER" "Name=tag:Name,Values=$CLUSTER-w1,$CLUSTER-w2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)

echo "CP: $CP_IP  Workers: $W_IPS"
```

**Validación:** 3 instancias `running`, EIP asociada al CP.

---

## FASE B — Preparación de nodos (EN LOS 3 NODOS)

SSH desde CloudShell: `ssh -i ~/$CLUSTER.pem ubuntu@<IP>`

En **CP y ambos workers**. Primero, SOLO esto, y espera al prompt `root@`:

```bash
sudo -i
```

Después pega este bloque completo. Escribe un script y lo ejecuta — así `apt-get` no puede comerse el resto del paste (stdin):

```bash
cat > /root/prep-node.sh <<'SCRIPT'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Kernel y sysctl
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Swap off (Ubuntu 24.04 cloud no trae swap, pero por si acaso)
swapoff -a

# containerd (repo Docker)
apt-get update && apt-get install -y ca-certificates curl gpg apt-transport-https
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update && apt-get install -y containerd.io

containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd

# kubeadm/kubelet/kubectl 1.35
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update && apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
SCRIPT

chmod +x /root/prep-node.sh
/root/prep-node.sh
```

`set -euxo pipefail` hace que el script pare y grite en el primer error — nada de fallos silenciosos.

**Validación (cada nodo, como root):**

```bash
containerd --version && kubeadm version && lsmod | grep br_netfilter
```

Los tres deben responder; si `containerd` no se encuentra, el bloque anterior no se ejecutó completo — repítelo (es idempotente).

---

## FASE C — kubeadm init (SOLO CP)

Solo esto primero, espera al prompt `root@`:

```bash
sudo -i
```

Luego (sustituye la EIP antes de pegar):

```bash
CP_PUBLIC_IP=<EIP del paso A.5>

cat > kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.5
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
apiServer:
  certSANs:
  - $CP_PUBLIC_IP
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
skipPhases:
- addon/kube-proxy
EOF

kubeadm init --config kubeadm-config.yaml
```

⚠️ `skipPhases: addon/kube-proxy` — sin kube-proxy porque Cilium va con `kubeProxyReplacement=true`. Este es el cambio clave vs el lab anterior.

```bash
# kubectl para el usuario ubuntu
exit
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes   # CP en NotReady — normal, no hay CNI aún
```

Guarda el `kubeadm join ...` que imprime init. Si lo pierdes: `kubeadm token create --print-join-command`.

---

## FASE D — Cilium con kubeProxyReplacement=true (CP)

```bash
# Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

CP_PRIVATE_IP=$(hostname -I | awk '{print $1}')

helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --version 1.19.4 -n kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=$CP_PRIVATE_IP \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set gatewayAPI.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

⚠️ `gatewayAPI.enabled=true` requiere las CRDs de Gateway API ANTES de que arranque el operator. Instálalas ya:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl -n kube-system rollout restart deploy/cilium-operator
```

**Validación:**
```bash
kubectl -n kube-system get pods -l app.kubernetes.io/part-of=cilium   # Running
kubectl get nodes                                                      # CP Ready
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement   # True
```

---

## FASE E — Join workers (EN CADA WORKER)

```bash
sudo kubeadm join <CP_PRIVATE_IP>:6443 --token <...> --discovery-token-ca-cert-hash sha256:<...>
```

**Validación (CP):** `kubectl get nodes` → 3 Ready. Luego:
```bash
cilium_pod=$(kubectl -n kube-system get pod -l k8s-app=cilium -o name | head -1)
kubectl -n kube-system exec $cilium_pod -- cilium-dbg status --brief   # OK
```

---

## FASE F — Plataforma (CP, todo con Helm)

### F.1 EBS CSI + StorageClass (lo necesitan Postgres y Kafka)

```bash
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver -n kube-system

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
EOF
```

**Validación:**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: test-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: test-pvc-pod}
spec:
  containers:
  - name: t
    image: busybox
    command: ["sh","-c","echo ok > /data/ok && sleep 5"]
    volumeMounts: [{name: v, mountPath: /data}]
  volumes: [{name: v, persistentVolumeClaim: {claimName: test-pvc}}]
EOF
kubectl wait --for=condition=Ready pod/test-pvc-pod --timeout=120s && \
kubectl delete pod test-pvc-pod && kubectl delete pvc test-pvc
```

### F.2 Namespaces

```bash
kubectl create ns infra
kubectl create ns data
kubectl create ns logistics
kubectl label ns logistics pod-security.kubernetes.io/enforce=baseline
```

### F.3 cert-manager + ClusterIssuer self-signed

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager -n infra --set crds.enabled=true

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned}
spec: {selfSigned: {}}
EOF
```

### F.4 Gateway compartido (entrada de la app)

```bash
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gw
  namespace: infra
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "*.logistics.lab"
    tls:
      mode: Terminate
      certificateRefs: [{name: logistics-tls}]
    allowedRoutes:
      namespaces:
        from: Selector
        selector: {matchLabels: {kubernetes.io/metadata.name: logistics}}
EOF
```

**Validación:** `kubectl -n infra get gateway shared-gw` → `Accepted=True, Programmed=True`. El Service del Gateway saldrá como LoadBalancer `pending` (no hay cloud LB) — se accede vía NodePort del Service generado. Anótalo: es decisión de diseño pendiente de la sesión de decisiones.

### F.5 Operators de datos: CloudNativePG + Strimzi

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm install cnpg cnpg/cloudnative-pg -n data

helm repo add strimzi https://strimzi.io/charts/
helm install strimzi strimzi/strimzi-kafka-operator -n data
```

**Validación:** ambos operators `Running` en `data`. (Los clusters PG/Kafka se crean en la sesión de la app — son decisiones de app, no de plataforma.)

### F.6 kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack -n infra \
  --set grafana.service.type=NodePort \
  --set alertmanager.enabled=false
```

**Validación:** `kubectl -n infra get pods` todo Running; Grafana accesible en `http://<worker-ip>:<nodeport>` (pass: `kubectl -n infra get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d`).

---

## FASE G — Smoke tests finales del cluster

```bash
# 1. Conectividad Cilium end-to-end (instala CLI en el CP)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz | sudo tar xz -C /usr/local/bin
cilium connectivity test

# 2. KPR activo
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement

# 3. Storage dinámico (ya validado en F.1)
# 4. Gateway Programmed=True (ya validado en F.4)
# 5. Hubble
cilium hubble port-forward &
hubble status
```

## ✅ Cluster coronado cuando

1. 3 nodos Ready, sin kube-proxy, KPR=True
2. `cilium connectivity test` pasa
3. PVC gp3 dinámico funciona
4. Gateway `Programmed=True` con TLS de cert-manager
5. Operators CNPG + Strimzi corriendo
6. Grafana con targets up

---

## Decisiones abiertas para la sesión post-montaje (traer al chat)

1. Exposición del Gateway: NodePort vs NLB manual vs hostPort — sin cloud-controller no hay LB automático
2. Sizing del cluster PG (instancias, storage) y del Kafka KRaft 1-broker
3. Topología de namespaces definitiva y NetworkPolicies base
4. Estrategia de imágenes: ECR vs GHCR para logistics-lab
5. Qué servicios entran en el MVP del sprint (propuesta: shipments-api, routing, tracking-events + traffic-generator)
