locals {
  # V3 리소스의 이름 접두사. 예: meety-v3-eks-2a
  name_prefix = "${var.project}-v3"

  # V2 shared가 만든 리소스의 이름 접두사. 조회할 때만 쓴다.
  v2_prefix = "${var.project}-v2"

  # 클러스터는 1개이고 prod, staging은 Namespace로 나눈다 (5단계 3번 6.1절)
  cluster_name = local.name_prefix

  # default_tags가 붙지 않는 리소스(ASG로 뜨는 EC2, 노드 그룹 EC2와 볼륨, ENI)에 직접 붙인다
  common_tags = {
    Service   = "meety"
    Project   = var.project
    Version   = "v3"
    Env       = "shared"
    ManagedBy = "terraform"
  }

  # AZ 이름의 마지막 글자(a, c)로 리소스 이름을 구분한다
  az_suffix = { for az in var.azs : az => substr(az, -1, 1) }
}
