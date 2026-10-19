# V1 테스트 환경과 V2 서울 간 피어링 경로, 오하이오 DB 복제 접근 권한
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

# 기존 prod DB 인스턴스를 dev DB의 리허설용 복제본으로 재사용한다.
# 동일 VPC이므로 복제본의 전용 보안 그룹에서 오는 MySQL 접속만 허용한다.
resource "aws_vpc_security_group_ingress_rule" "dev_data_mysql_from_rehearsal" {
  security_group_id            = aws_security_group.dev_data_migration.id
  description                  = "MySQL replication from Ohio rehearsal DB"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = aws_security_group.prod_data_migration.id

  tags = {
    Name    = "dev-data-mysql-from-rehearsal"
    Service = "meety"
  }
}

# 기존 prod DB의 전용 SG는 재사용한다. 이름·설명 변경으로 SG가 교체되지 않게 유지한다.
# 기존 data-sg-v1과 app-sg-v1은 dev와 공유하므로 삭제하지 않는다.
resource "aws_security_group" "prod_data_migration" {
  name        = "prod-data-migration-sg-v1"
  description = "V2 prod primary dumps and replicates prod MySQL"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name    = "prod-data-migration-sg-v1"
    Service = "meety"
  }
}

# dev ProxySQL에서 리허설 대상 DB로 접속할 수 있도록 정확한 사설 IP만 허용한다.
resource "aws_vpc_security_group_ingress_rule" "rehearsal_mysql_from_dev_proxysql" {
  security_group_id = aws_security_group.prod_data_migration.id
  description       = "MySQL from Ohio dev ProxySQL"
  ip_protocol       = "tcp"
  from_port         = 3306
  to_port           = 3306
  cidr_ipv4         = "${aws_instance.dev_app.private_ip}/32"

  tags = {
    Name    = "rehearsal-mysql-from-dev-proxysql"
    Service = "meety"
  }
}
