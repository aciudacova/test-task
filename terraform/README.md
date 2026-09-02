# EKS with Karpenter, Graviton & Spot

An EKS cluster in its own VPC, autoscaled by [Karpenter](https://karpenter.sh/) across x86 and ARM64 (Graviton) nodes on Spot.

## What gets created

| Component | Details |
|---|---|
| VPC | 3 AZs, public + private subnets, one NAT per AZ, flow logs |
| EKS 1.36 | Secrets encrypted with KMS, public + private API endpoint |
| System nodes | 2× `m7g.medium` on-demand, runs Karpenter and CoreDNS |
| Karpenter | Two NodePools: `graviton` (arm64, weight 100, 70 vCPU) and `x86` (amd64, weight 10, 30 vCPU) |

Both pools try Spot first and fall back to On-Demand. Instance families `c`/`m`/`r`, generation 6+, encrypted gp3 disks.

## Files

```
main.tf        Providers, data sources, locals
versions.tf    Version constraints, S3 backend
variables.tf   Inputs
outputs.tf     Outputs
vpc.tf         VPC
eks.tf         Cluster and system node group
karpenter.tf   Karpenter, NodePools, EC2NodeClass
bootstrap.sh   Creates the state bucket, writes backend.hcl
backend.hcl    Name of the state bucket (commit this)
```

## Prerequisites

Ensure you have the following tools installed and configured before proceeding:

* **[Terraform](https://developer.hashicorp.com/terraform/downloads)** `>= 1.15.3`
* **[AWS CLI](https://aws.amazon.com/cli/)** configured with valid credentials. The IAM user or role must have sufficient permissions to provision the infrastructure (e.g., `AdministratorAccess` for development/testing).
* **[kubectl](https://kubernetes.io/docs/tasks/tools/)** for interacting with the provisioned Kubernetes cluster.


## Deploy

```bash
cd terraform/
./bootstrap.sh                            # once: creates the state bucket
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`bootstrap.sh` creates a versioned, encrypted, private S3 bucket with a random name suffix, and records
the name in `backend.hcl`. The name can't go in `versions.tf` because `backend` blocks only accept
literal values. Re-running the script is safe — it reuses the bucket already in `backend.hcl`.

Then connect and check:

```bash
$(terraform output -raw configure_kubectl)
kubectl get nodepools
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
```

## Running on x86 or Graviton

The pod asks for an architecture; Karpenter provides it. Set `nodeSelector`:

| You want | Add this | Provisioned by |
|---|---|---|
| Graviton (ARM64) | `kubernetes.io/arch: arm64` | `graviton` pool |
| x86 (AMD64) | `kubernetes.io/arch: amd64` | `x86` pool |
| Don't care | nothing | `graviton` pool (higher weight) |

**Leaving it out ("unpinned")** means the pod will run on either architecture. Kubernetes may schedule
it onto any node with room, arm64 or amd64. If no node has room, Karpenter checks the `graviton` pool
first because of its higher weight, so new capacity is arm64.

Only leave it out if your image is multi-arch. Kubernetes does **not** check image architecture when
scheduling, so a single-arch image is still placed on a node of the wrong architecture — it just never
starts, with either `ImagePullBackOff` ("no matching manifest for linux/arm64") or `CrashLoopBackOff`
with `exec format error`. This is intermittent: the pod works while it lands on matching nodes and
breaks as soon as it doesn't. Thus, always pin the architecture.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-graviton
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-graviton
  template:
    metadata:
      labels:
        app: app-graviton
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64      # use amd64 for x86
      containers:
        - name: app
          image: public.ecr.aws/nginx/nginx:latest
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
```

To pin capacity type, add `karpenter.sh/capacity-type: spot` (or `on-demand`) to the same
`nodeSelector`.

Check what Karpenter built:

```bash
kubectl get nodeclaims -L karpenter.sh/nodepool,kubernetes.io/arch,karpenter.sh/capacity-type
```

```
NAME        TYPE        CAPACITY  ZONE        NODE          READY  AGE  NODEPOOL  ARCH   CAPACITY-TYPE
graviton-*  c7g.xlarge  spot      eu-west-1b  ip-10-0-24-*  True   20m  graviton  arm64  spot
x86-*       c6i.large   spot      eu-west-1c  ip-10-0-34-*  True   91m  x86       amd64  spot
```

Karpenter nodes carry `karpenter.sh/capacity-type`; the system node group uses
`eks.amazonaws.com/capacityType` instead, and is always `ON_DEMAND`.

New nodes only appear when pods don't fit on existing ones. Karpenter then picks the smallest
instance that fits, so **node size follows your `resources.requests`**, not this Terraform code.

## Variables

| Variable | Description | Default |
|---|---|---|
| `region` | AWS region | `eu-west-1` |
| `environment` | Deployment environment (`dev`, `staging`, `prod`) | `prod` |
| `cluster_name` | EKS cluster name | `startup-eks` |
| `cluster_version` | Kubernetes version (`MAJOR.MINOR`) | `1.36` |
| `vpc_cidr` | VPC CIDR block | `10.0.0.0/16` |
| `single_nat_gateway` | Route all private subnets through one NAT gateway (dev/POC cost saving) | `false` |
| `create_spot_service_linked_role` | Create the EC2 Spot service-linked role (one per account) | `true` |
| `tags` | Additional tags for all resources | `{}` |

## Cleanup

Review what will be destroyed before confirming:

```bash
terraform plan -destroy -out=destroy.tfplan
terraform apply destroy.tfplan
```

Delete test workloads first so Karpenter drains its nodes rather than leaving orphaned instances.

## Design notes

**Region `eu-west-1`.** Deepest Spot pools in the EU, widest Graviton selection, cheapest EU pricing.
Switch with `-var="region=eu-central-1"` if your users are further east.

**Two NodePools instead of one.** `weight` is a NodePool-level field, so one pool cannot express
"prefer Graviton". Two weighted pools can. Limits are split (70/30 vCPU), not duplicated, so the
cluster ceiling stays at 100 vCPU. The cost: Karpenter only consolidates within a pool, so an
arch-agnostic pod on Graviton will never move to a cheaper x86 node. Revisit as the cluster grows.

**Spot service-linked role.** Without `aws_iam_service_linked_role.spot`, EC2 rejects Spot launches and
Karpenter quietly falls back to On-Demand — Spot looks configured but is never used. It's one per
account, so set `create_spot_service_linked_role = false` if the account already has it.

**Public + private API endpoint.** Developers get `kubectl` without a VPN. To harden, restrict
`endpoint_public_access_cidrs` to office ranges.

**Karpenter CRs via the `bedag/raw` Helm chart.** The `kubectl`/`kubernetes` providers need a cluster
endpoint when Terraform configures providers, which doesn't exist on the first run — that forces a
two-stage `-target` apply. The Helm provider connects only at apply time, so the whole stack deploys in
one `terraform apply`.

**Community modules.** `terraform-aws-modules/vpc` and `/eks` used directly, plus the EKS module's
Karpenter submodule for IAM and SQS.

**Security defaults.** KMS-encrypted secrets, encrypted gp3 disks, VPC flow logs, control plane logs
(`api`, `audit`, `authenticator` — the other two are noisy and rarely useful), VPC-CNI prefix
delegation, Pod Identity for Karpenter.

**One NAT per AZ.** Avoids a single-AZ egress failure. Set `single_nat_gateway = true` to save roughly
$70/month in dev.

## Multiple environments

Flat layout on purpose — one cluster, one state. To split dev/prod later: move `vpc.tf` and `eks.tf`
into `modules/eks-cluster/`, add `environments/dev|prod/` that call it, and give each its own backend
key.
