# Without this role EC2 rejects Spot launches and Karpenter silently falls back to on-demand.
resource "aws_iam_service_linked_role" "spot" {
  count = var.create_spot_service_linked_role ? 1 : 0

  aws_service_name = "spot.amazonaws.com"
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = module.eks.cluster_name

  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = var.tags
}

resource "helm_release" "karpenter" {
  namespace  = "kube-system"
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.14.0"

  # Must be true so Karpenter CRDs are registered before the manifests below apply.
  wait    = true
  timeout = 600

  values = [
    <<-EOT
    serviceAccount:
      name: ${module.karpenter.service_account}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
    EOT
  ]

  depends_on = [module.karpenter]
}

locals {
  # One NodePool per architecture. Graviton carries the higher weight, so pods that do not
  # pin an architecture land on cheaper arm64 capacity while x86 stays available on request.
  # Limits are split, not duplicated, so the cluster ceiling stays at 100 vCPU / 200Gi total.
  karpenter_nodepools = {
    graviton = { arch = "arm64", weight = 100, cpu = "70", memory = "140Gi" }
    x86      = { arch = "amd64", weight = 10, cpu = "30", memory = "60Gi" }
  }
}

# Karpenter CRs are shipped through a generic "raw" chart rather than the kubectl provider,
# which would need a cluster endpoint at plan time and force a two-stage apply.
resource "helm_release" "karpenter_resources" {
  namespace  = "kube-system"
  name       = "karpenter-resources"
  repository = "https://bedag.github.io/helm-charts/"
  chart      = "raw"
  version    = "2.0.2"
  wait       = true

  values = [
    yamlencode({
      resources = concat(
        [
          {
            apiVersion = "karpenter.k8s.aws/v1"
            kind       = "EC2NodeClass"
            metadata   = { name = "default" }
            spec = {
              amiSelectorTerms = [{ alias = "al2023@latest" }]
              role             = module.karpenter.node_iam_role_name
              subnetSelectorTerms = [
                { tags = { "karpenter.sh/discovery" = var.cluster_name } }
              ]
              securityGroupSelectorTerms = [
                { tags = { "karpenter.sh/discovery" = var.cluster_name } }
              ]
              blockDeviceMappings = [
                {
                  deviceName = "/dev/xvda"
                  ebs = {
                    volumeSize = "50Gi"
                    volumeType = "gp3"
                    encrypted  = true
                  }
                }
              ]
              tags = { "karpenter.sh/discovery" = var.cluster_name }
            }
          }
        ],
        [
          for name, cfg in local.karpenter_nodepools : {
            apiVersion = "karpenter.sh/v1"
            kind       = "NodePool"
            metadata   = { name = name }
            spec = {
              weight = cfg.weight
              template = {
                spec = {
                  requirements = [
                    { key = "kubernetes.io/arch", operator = "In", values = [cfg.arch] },
                    { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
                    { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["c", "m", "r"] },
                    { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] },
                  ]
                  nodeClassRef = {
                    group = "karpenter.k8s.aws"
                    kind  = "EC2NodeClass"
                    name  = "default"
                  }
                  expireAfter = "720h"
                }
              }
              limits = {
                cpu    = cfg.cpu
                memory = cfg.memory
              }
              disruption = {
                consolidationPolicy = "WhenEmptyOrUnderutilized"
                consolidateAfter    = "1m"
              }
            }
          }
        ]
      )
    })
  ]

  depends_on = [helm_release.karpenter]
}
