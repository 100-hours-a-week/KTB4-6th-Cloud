# V1 dev → V2 staging(서울) DB 이전 리허설용 리소스 (2026-10-12)
# - 피어링 자체는 v2/terraform/shared에서 만들고 수락한다. 여기서는 오하이오 쪽 경로와 접근 허용만 둔다.
# - public 라우트 테이블의 경로는 aws_route로 관리한다. route 블록 안에 경로를 추가하면 Terraform이
#   기존 인터넷 경로까지 지웠다가 다시 만드는 것으로 계획할 수 있어, prod 인터넷 경로를 건드리지 않도록 분리했다.

# 기존 인터넷 경로. 리소스만 import하고 값은 그대로다.
import {
  to = aws_route.public_internet
  id = "rtb-006dcab3f189780a2_0.0.0.0/0"
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# V2(서울) VPC로 가는 트래픽은 피어링으로 보낸다.
resource "aws_route" "public_v2" {
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = var.v2_vpc_cidr
  vpc_peering_connection_id = data.aws_vpc_peering_connection.v2.id
}

# v2/shared가 만든 피어링을 이름 태그로 찾는다.
data "aws_vpc_peering_connection" "v2" {
  status = "active"

  tags = {
    Name = "meety-v2-to-v1"
  }
}

# dev DB에만 붙이는 보안 그룹. data-sg-v1은 prod DB와 같이 쓰므로 여기에 규칙을 넣지 않는다.
resource "aws_security_group" "dev_data_migration" {
  name        = "dev-data-migration-sg-v1"
  description = "V2 staging DB dumps and replicates dev MySQL"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "dev-data-migration-sg-v1"
    Service = "meety"
  }
}

# 서울의 리허설용 MySQL이 덤프와 복제를 위해 접속한다.
# 처음에는 V2 staging DB(10.1.10.132)를 리허설에 썼으나, staging 앱 전용으로 되돌리면서 리허설용 인스턴스로 옮겼다 (2026-10-16)
resource "aws_vpc_security_group_ingress_rule" "dev_data_mysql_from_v2_migration_db" {
  security_group_id = aws_security_group.dev_data_migration.id
  description       = "MySQL from V2 migration rehearsal DB over peering"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = "${var.v2_migration_db_ip}/32"

  tags = {
    Name    = "dev-data-mysql-from-v2-migration-db"
    Service = "meety"
  }
}
