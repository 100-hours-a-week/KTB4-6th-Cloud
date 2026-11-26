# EKS 전용 프라이빗 서브넷과 라우팅 (5단계 4번 네트워크 설계 3장, 5장)
# - 노드와 Pod는 이 서브넷에만 둔다. VPC CNI는 Pod마다 VPC IP를 쓰므로 AZ마다 /20으로 크게 잡는다.
# - 기본 경로(0.0.0.0/0)는 Terraform이 아니라 NAT 인스턴스가 부팅할 때 자기 자신으로 만든다(nat.tf).
#   NAT는 크기 1 Auto Scaling 그룹이라 교체되면 인스턴스 ID가 바뀌기 때문이다.

resource "aws_subnet" "eks" {
  for_each = var.eks_subnet_cidrs

  vpc_id            = data.aws_vpc.v2.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${local.name_prefix}-eks-${local.az_suffix[each.key]}"
    # 내부 로드밸런서를 둘 서브넷과, Karpenter가 노드를 띄울 서브넷을 찾는 태그
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = local.cluster_name
  }
}

# AZ마다 라우팅 테이블을 따로 둔다. NAT 장애 때 그 AZ의 기본 경로만 다른 AZ NAT로 바꾸기 위해서다(4번 5.3절).
# route 블록을 쓰지 않아 Terraform은 테이블 안의 경로를 관리하지 않는다. 기본 경로는 NAT가 만든다.
resource "aws_route_table" "eks" {
  for_each = var.eks_subnet_cidrs

  vpc_id = data.aws_vpc.v2.id

  tags = {
    Name = "${local.name_prefix}-eks-${local.az_suffix[each.key]}"
  }
}

resource "aws_route_table_association" "eks" {
  for_each = var.eks_subnet_cidrs

  subnet_id      = aws_subnet.eks[each.key].id
  route_table_id = aws_route_table.eks[each.key].id
}

# 이미지 레이어(ECR이 S3에 저장)를 NAT를 거치지 않고 받는다. 추가 요금이 없다(4번 5.4절).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.aws_vpc.v2.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.eks : rt.id]

  tags = {
    Name = "${local.name_prefix}-s3"
  }
}
