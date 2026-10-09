# V2 네트워크: VPC 1개, 2개 AZ의 public 서브넷, 인터넷 게이트웨이
# ALB와 ECS 태스크가 public 서브넷을 쓴다. DB, Redis용 private 서브넷과 라우팅은 환경별 폴더(staging/, prod/)에서 만든다.

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # ECS 태스크와 VPC 안의 리소스가 DNS 이름으로 서로 찾을 수 있게 켠다
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# AZ마다 public 서브넷 1개. 10.1.0.0/24, 10.1.1.0/24
# 앞쪽 번호(0~9)는 public, 10번대부터는 이후 추가할 private 서브넷용으로 비워 둔다.
resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = var.azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)

  # 서브넷에 뜨는 EC2에 public IP를 자동으로 주지 않는다.
  # ECS 태스크의 public IP는 ECS 서비스 설정(assign_public_ip)에서 따로 켠다.
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-${substr(var.azs[count.index], -1, 1)}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  # VPC 밖으로 나가는 모든 트래픽은 인터넷 게이트웨이로
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
