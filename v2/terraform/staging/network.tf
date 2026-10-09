# staging private 네트워크: DB, Redis처럼 인터넷에 직접 노출하지 않을 자원을 둔다.
# 라우팅 테이블의 기본 경로(0.0.0.0/0)는 하나만 둘 수 있어서, prod가 staging NAT에 의존하지 않도록
# private 서브넷과 라우팅은 환경별 폴더에서 만든다. ECS 태스크는 계속 shared의 public 서브넷을 쓴다.

# shared public 서브넷과 같은 AZ에 private 서브넷을 두기 위해 AZ를 읽어 온다
data "aws_subnet" "public" {
  count = length(local.shared.public_subnet_ids)

  id = local.shared.public_subnet_ids[count.index]
}

# AZ마다 private 서브넷 1개. 10.1.10.0/24, 10.1.11.0/24
# staging private 서브넷은 10번대를 쓴다. prod 대역은 prod 구성 때 정한다.
resource "aws_subnet" "private" {
  count = length(data.aws_subnet.public)

  vpc_id            = local.shared.vpc_id
  availability_zone = data.aws_subnet.public[count.index].availability_zone
  cidr_block        = cidrsubnet(local.shared.vpc_cidr, 8, 10 + count.index)

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${substr(data.aws_subnet.public[count.index].availability_zone, -1, 1)}"
    Tier = "private"
  }
}

# 외부로 나가는 경로(FE/NAT 인스턴스)는 아래 aws_route로 따로 둔다
resource "aws_route_table" "private" {
  vpc_id = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

# private 서브넷에서 VPC 밖으로 나가는 트래픽은 FE 인스턴스(NAT)로 보낸다.
# VPC 안의 통신(예: ECS → DB)은 local 경로를 타므로 NAT를 거치지 않는다.
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fe.primary_network_interface_id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
