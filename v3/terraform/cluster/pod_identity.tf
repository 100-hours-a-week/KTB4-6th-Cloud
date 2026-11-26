# Pod Identity: ServiceAccount와 IAM 역할 연결 (5단계 9번 보안과 격리 설계 5.1절)
# - 연결은 Terraform이 만든다. 모듈이 공식 권한 정책을 붙인다.
# - VPC CNI, EBS CSI는 애드온 설정에서 연결한다(eks.tf). LBC, ESO는 여기서 연결한다.

module "vpc_cni_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name            = "${local.name_prefix}-vpc-cni"
  use_name_prefix = false

  attach_aws_vpc_cni_policy = true
  aws_vpc_cni_enable_ipv4   = true
}

module "ebs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name            = "${local.name_prefix}-ebs-csi"
  use_name_prefix = false

  attach_aws_ebs_csi_policy = true
}

module "lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name            = "${local.name_prefix}-lb-controller"
  use_name_prefix = false

  attach_aws_lb_controller_policy = true

  associations = {
    main = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

# ESO 컨트롤러는 Parameter Store를 직접 읽지 않고, 환경별 읽기 역할(meety-v3-eso-prod, meety-v3-eso-staging)을
# 넘겨받아(assume) 읽는다(9번 6.2절). 환경별 역할은 3단계에서 만든다.
module "eso_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "2.11.0"

  name            = "${local.name_prefix}-eso-controller"
  use_name_prefix = false

  attach_custom_policy = true
  policy_statements = [{
    sid       = "AssumeEnvironmentReadRoles"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name_prefix}-eso-*"]
  }]

  associations = {
    main = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}
