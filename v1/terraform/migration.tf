# V1 테스트 환경과 V2 서울 간 피어링 경로, 리허설 DB 접근 권한
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

# 서울의 격리된 리허설 DB만 dev DB의 binlog에 접속할 수 있도록 고정 사설 IP 하나를 허용한다.
resource "aws_vpc_security_group_ingress_rule" "dev_data_mysql_from_rehearsal" {
  count = var.migration_rehearsal_enabled ? 1 : 0

  security_group_id = aws_security_group.dev_data_migration.id
  description       = "MySQL replication from Seoul migration rehearsal DB"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = "10.1.11.133/32"

  tags = {
    Name    = "dev-data-mysql-from-rehearsal"
    Service = "meety"
  }
}

# 기존 리허설 규칙을 조건부 관리로 옮겨 기본 비활성 상태에서 제거한다.
moved {
  from = aws_vpc_security_group_ingress_rule.dev_data_mysql_from_rehearsal
  to   = aws_vpc_security_group_ingress_rule.dev_data_mysql_from_rehearsal[0]
}
