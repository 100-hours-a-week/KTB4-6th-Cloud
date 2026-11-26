# EKS 클러스터와 platform 노드 그룹 (5단계 3번 아키텍처, 4번 네트워크, 5번 노드, 8번 배포 7.1절)
# - Terraform은 클러스터, platform 노드, EKS 기본 애드온, AWS 쪽 리소스까지 만든다.
#   Karpenter, LBC, KEDA, metrics-server, NodePool, Argo CD는 Argo CD가 v3/deploy/platform/으로 관리한다.
# - 모듈은 terraform-aws-modules/eks를 버전 고정해 쓴다. 공식 IAM 정책을 모듈이 관리해 권한 누락을 줄인다.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.30.2"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  # API는 비공개만 둔다. 구축 초기와 비상 시에만 담당자 IP로 공개를 잠시 켠다(4번 6장).
  endpoint_private_access      = true
  endpoint_public_access       = length(var.public_access_cidrs) > 0
  endpoint_public_access_cidrs = var.public_access_cidrs

  vpc_id     = data.aws_vpc.v2.id
  subnet_ids = [for s in aws_subnet.eks : s.id]

  # 접속 권한은 EKS access entry로만 준다(aws-auth ConfigMap을 쓰지 않는다).
  authentication_mode = "API"
  # Pod IAM은 Pod Identity로만 준다(9번 5.1절). IRSA용 OIDC 공급자는 만들지 않는다.
  enable_irsa = false
  # 클러스터를 만든 Cloud 담당자(meety-infra)에게 관리자 권한을 준다(9번 7장).
  enable_cluster_creator_admin_permissions = true
  access_entries = {
    bastion = {
      principal_arn = aws_iam_role.bastion.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # 접속용 EC2에서 비공개 API(443)로 들어온다
  security_group_additional_rules = {
    bastion = {
      description              = "Cluster API from access instance"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.bastion.id
    }
  }

  # Kubernetes Secret은 EKS 기본 암호화(AWS 소유 키)로 충분하다. 고객 관리 KMS 키(월 $1)는 두지 않는다.
  create_kms_key    = false
  encryption_config = null

  # 감사, 인증 로그만 남긴다. api 로그는 양이 많아 CloudWatch 수집 요금이 커서 끈다.
  enabled_log_types                      = ["audit", "authenticator"]
  cloudwatch_log_group_retention_in_days = 14

  # Karpenter가 노드 보안 그룹을 찾는 태그
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  addons = {
    # 노드가 뜨기 전에 있어야 Pod 네트워크와 Pod IAM이 동작한다
    vpc-cni = {
      before_compute = true
      most_recent    = false
      pod_identity_association = [{
        role_arn        = module.vpc_cni_pod_identity.iam_role_arn
        service_account = "aws-node"
      }]
    }
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = false
    }
    kube-proxy = {
      most_recent = false
    }
    # platform 노드의 taint를 견디도록 toleration을 넣는다. 없으면 Pending이 된다.
    coredns = {
      most_recent = false
      configuration_values = jsonencode({
        nodeSelector = { "worker-group" = "platform" }
        tolerations  = [{ key = "worker-group", operator = "Equal", value = "platform", effect = "NoSchedule" }]
      })
    }
    aws-ebs-csi-driver = {
      most_recent = false
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
      configuration_values = jsonencode({
        controller = {
          nodeSelector = { "worker-group" = "platform" }
          tolerations  = [{ key = "worker-group", operator = "Equal", value = "platform", effect = "NoSchedule" }]
        }
      })
    }
  }

  eks_managed_node_groups = {
    # 운영 도구(Karpenter, Argo CD, LBC, CoreDNS 등)만 올리는 고정 노드. AZ마다 1대(5번 3장, 6.3절)
    platform = {
      name            = "${local.name_prefix}-platform"
      use_name_prefix = false

      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.platform_instance_type]

      min_size     = 2
      max_size     = 2
      desired_size = 2

      labels = { "worker-group" = "platform" }
      taints = {
        platform = { key = "worker-group", value = "platform", effect = "NO_SCHEDULE" }
      }

      # VPC CNI 권한은 노드 역할이 아니라 Pod Identity로 준다(9번 5.3절). 디버깅용 SSM 접속만 더한다.
      iam_role_attach_cni_policy = false
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # 노드 교체는 1대씩 한다
      update_config = { max_unavailable = 1 }

      launch_template_tags = local.common_tags
    }
  }
}

# Karpenter의 AWS 쪽 리소스: 컨트롤러 역할(Pod Identity), 노드 역할과 access entry, 중단 알림 큐
# Karpenter 컨트롤러와 NodePool 자체는 2단계에서 Argo CD로 올린다.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.30.2"

  cluster_name = module.eks.cluster_name

  iam_role_name            = "${local.name_prefix}-karpenter-controller"
  iam_role_use_name_prefix = false
  # 컨트롤러 정책이 관리형 정책 한도(6,144자)를 넘어 인라인 정책(10,240자)으로 만든다
  enable_inline_policy = true

  node_iam_role_name             = "${local.name_prefix}-karpenter-node"
  node_iam_role_use_name_prefix   = false
  node_iam_role_attach_cni_policy = false
  node_iam_role_additional_policies = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  queue_name = "${local.name_prefix}-karpenter"

  # 컨트롤러는 kube-system의 karpenter ServiceAccount로 동작한다
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"
}
