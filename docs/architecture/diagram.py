from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2, EC2SpotInstance
from diagrams.aws.network import (
    ElbNetworkLoadBalancer,
    InternetGateway,
    PublicSubnet,
)
from diagrams.aws.storage import S3
from diagrams.aws.database import Dynamodb
from diagrams.aws.management import SystemsManagerParameterStore
from diagrams.aws.security import IAMRole
from diagrams.onprem.ci import GithubActions

CLUSTER_NAME = "k8s-vanilla-lab"
OUTPUT_FILE = "architecture"

graph_attr = {
    "fontsize": "13",
    "bgcolor": "white",
    "pad": "0.8",
    "nodesep": "0.6",
    "ranksep": "1.0",
}

with Diagram(
    f"{CLUSTER_NAME} — Architecture",
    filename=OUTPUT_FILE,
    outformat=["svg", "png"],
    direction="LR",
    show=False,
    graph_attr=graph_attr,
):
    github_actions = GithubActions("GitHub Actions\n(validate / apply / destroy)")

    with Cluster("AWS Account"):
        ci_role = IAMRole("IAM Role\nk8s-vanilla-lab-\ngithub-actions\n(OIDC)")

        # IAM roles are account-scoped — not inside VPC or subnet
        cp_role = IAMRole("IAM Role\ncp-node\n(SSM write)")
        worker_role = IAMRole("IAM Role\nworker-node\n(SSM read)")

        ssm = SystemsManagerParameterStore(
            f"SSM Parameter Store\n/k8s/{CLUSTER_NAME}/*"
        )

        with Cluster("State Backend"):
            tf_state = S3("S3\ntfstate bucket")
            tf_lock = Dynamodb("DynamoDB\ntflock table")

        with Cluster(f"VPC — {CLUSTER_NAME}-vpc"):
            igw = InternetGateway("Internet\nGateway")

            with Cluster("Public Subnet (10.0.1.0/24)"):
                # Single internet-facing NLB, two listeners: the application
                # entry (TCP/443 → Gateway NodePort) and the Kubernetes API
                # endpoint (TCP/6443 → control planes). Declared coupling,
                # ADR-007. No EIP exists since S2 piece 3.
                nlb = ElbNetworkLoadBalancer(
                    "NLB (internet-facing)\n:443 app · :6443 API"
                )
                # 3 control planes, stacked etcd — node HA, single AZ
                cps = [
                    EC2("Control Plane 0\n(kubeadm init)"),
                    EC2("Control Plane 1\n(join)"),
                    EC2("Control Plane 2\n(join)"),
                ]
                workers = [
                    EC2SpotInstance("Worker 1\n(t3.medium · spot)"),
                    EC2SpotInstance("Worker 2\n(t3.medium · spot)"),
                    EC2SpotInstance("Worker 3\n(t3.medium · spot)"),
                ]

    # OIDC trust: GitHub Actions assumes CI role
    github_actions >> Edge(label="AssumeRoleWithWebIdentity\n(OIDC)") >> ci_role

    # CI manages state backend
    ci_role >> Edge(style="dashed", color="gray") >> tf_state
    ci_role >> Edge(style="dashed", color="gray") >> tf_lock

    # Public entry: everything from the internet lands on the NLB
    igw >> Edge(label="public route") >> nlb

    # NLB listeners: API to the control planes, application to the workers
    for c in cps:
        nlb >> Edge(label=":6443 API", color="firebrick") >> c
    for w in workers:
        nlb >> Edge(label=":443 → :30443", color="darkgreen") >> w

    # IAM instance profiles (undirected — association, not data flow)
    for c in cps:
        c - Edge(style="dashed", color="gray") - cp_role
    for w in workers:
        w - Edge(style="dashed", color="gray") - worker_role

    # Bootstrap: CP-0 publishes join data, join material and kubeconfig
    cps[0] >> Edge(label="put join-command\nput cp/certificate-key\nput kubeconfig") >> ssm

    # Bootstrap: joining CPs and workers poll SSM
    ssm >> Edge(label="poll join material\n(cp/joined-count gate)") >> cps[1]
    ssm >> Edge(label="poll join-command") >> workers[0]

    # K8s API plane: every node reaches the API through the NLB endpoint,
    # never through a node address (ADR-007). One representative edge —
    # drawing it per node turns the graph into noise.
    workers[0] >> Edge(
        label="kubelets / kubectl\n→ :6443 endpoint",
        style="dotted",
        color="firebrick",
    ) >> nlb

    # CI smoke test: reads kubeconfig from SSM post-apply (dashed = read-only)
    ci_role >> Edge(
        label="get kubeconfig\n(smoke test)",
        style="dashed",
        color="steelblue",
    ) >> ssm
