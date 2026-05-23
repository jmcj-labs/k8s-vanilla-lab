from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2, EC2SpotInstance
from diagrams.aws.network import InternetGateway, PublicSubnet
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
                # EIP is an attribute of the control plane, not a network hop
                cp = EC2("Control Plane\n(t3.medium · on-demand · EIP)")
                workers = [
                    EC2SpotInstance("Worker 1\n(t3.medium · spot)"),
                    EC2SpotInstance("Worker 2\n(t3.medium · spot)"),
                ]

    # OIDC trust: GitHub Actions assumes CI role
    github_actions >> Edge(label="AssumeRoleWithWebIdentity\n(OIDC)") >> ci_role

    # CI manages state backend
    ci_role >> Edge(style="dashed", color="gray") >> tf_state
    ci_role >> Edge(style="dashed", color="gray") >> tf_lock

    # Internet access through IGW to control plane
    igw >> Edge(label="public route") >> cp

    # IAM instance profiles (undirected — association, not data flow)
    cp - Edge(style="dashed", color="gray") - cp_role
    for w in workers:
        w - Edge(style="dashed", color="gray") - worker_role

    # Bootstrap: CP publishes join data and kubeconfig to SSM
    cp >> Edge(label="put join-command\nput kubeconfig") >> ssm

    # Bootstrap: workers poll SSM for join data
    ssm >> Edge(label="poll join-command") >> workers

    # K8s API plane (bidirectional between CP and workers)
    cp >> Edge(label="K8s API") >> workers

    # CI smoke test: reads kubeconfig from SSM post-apply (dashed = read-only)
    ci_role >> Edge(
        label="get kubeconfig\n(smoke test)",
        style="dashed",
        color="steelblue",
    ) >> ssm
