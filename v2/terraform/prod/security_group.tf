# prod BE 보안 그룹: ALB 보안 그룹에서 오는 요청만 받는다.
# 태스크에 public IP가 있지만, 이 규칙 때문에 인터넷에서 태스크로 직접 접근할 수 없다.

resource "aws_security_group" "be" {
  name        = "${local.name_prefix}-be-sg"
  description = "V2 prod BE: from ALB only"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-be-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "be_from_alb" {
  security_group_id            = aws_security_group.be.id
  description                  = "From ALB"
  referenced_security_group_id = local.shared.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.be_container_port
  to_port                      = var.be_container_port
}

# 이미지 받기, Parameter Store, 외부 API(카카오 등) 호출에 인터넷 출구가 필요하다
resource "aws_vpc_security_group_egress_rule" "be_all" {
  security_group_id = aws_security_group.be.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# prod FE 보안 그룹: FE 인스턴스가 NAT 인스턴스를 겸한다.
# 이름과 설명은 바꾸면 보안 그룹이 교체되므로 FE 기준으로 두고, NAT 용도는 아래 규칙으로 표현한다.
# SSH는 열지 않고 SSM으로 접속한다.
resource "aws_security_group" "fe" {
  name        = "${local.name_prefix}-fe-sg"
  description = "V2 prod FE instance"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-fe-sg"
  }
}

# NAT: prod private 서브넷에서 외부로 나가는 트래픽만 받는다
resource "aws_vpc_security_group_ingress_rule" "fe_nat_from_private" {
  count = length(aws_subnet.private)

  security_group_id = aws_security_group.fe.id
  description       = "NAT from prod private subnet"
  cidr_ipv4         = aws_subnet.private[count.index].cidr_block
  ip_protocol       = "-1"
}

# FE 앱: ALB에서 오는 요청만 받는다
resource "aws_vpc_security_group_ingress_rule" "fe_from_alb" {
  security_group_id            = aws_security_group.fe.id
  description                  = "FE app from ALB"
  referenced_security_group_id = local.shared.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.fe_container_port
  to_port                      = var.fe_container_port
}

# FE 무중단 배포: 새 컨테이너를 다른 포트로 띄워 확인한 뒤 트래픽을 넘긴다. 두 포트를 번갈아 쓴다
resource "aws_vpc_security_group_ingress_rule" "fe_standby_from_alb" {
  security_group_id            = aws_security_group.fe.id
  description                  = "FE app (deploy standby port) from ALB"
  referenced_security_group_id = local.shared.alb_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = var.fe_standby_port
  to_port                      = var.fe_standby_port
}

# 패키지 설치, SSM 연결, NAT로 전달하는 트래픽이 인터넷으로 나간다
resource "aws_vpc_security_group_egress_rule" "fe_all" {
  security_group_id = aws_security_group.fe.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# prod DB 보안 그룹: Primary(MySQL + Redis)와 Read Replica(MySQL)가 같이 쓴다.
# 이름과 설명은 바꾸면 보안 그룹이 교체되므로 인스턴스 기준으로 두고, 포트는 아래 규칙으로 표현한다.
# prod BE에서 오는 연결만 받는다. SSH는 열지 않고 SSM으로 접속한다.
resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "V2 prod DB instance"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_mysql_from_be" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from prod BE"
  referenced_security_group_id = aws_security_group.be.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "db_redis_from_be" {
  security_group_id            = aws_security_group.db.id
  description                  = "Redis from prod BE"
  referenced_security_group_id = aws_security_group.be.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

# Read Replica가 Primary에서 복제받는다. 같은 보안 그룹끼리 MySQL 접속을 허용한다
resource "aws_vpc_security_group_ingress_rule" "db_mysql_from_db" {
  security_group_id            = aws_security_group.db.id
  description                  = "MySQL replication between prod DB instances"
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# 패키지와 이미지 받기, SSM 연결은 FE/NAT 인스턴스를 거쳐 인터넷으로 나간다
resource "aws_vpc_security_group_egress_rule" "db_all" {
  security_group_id = aws_security_group.db.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# prod AI 보안 그룹: 실시간 STT(ai-live) 인스턴스에 붙인다. 분석(ai-analysis)은 ai_analysis 보안 그룹을 쓴다.
# BE만 AI를 호출하므로 BE 보안 그룹에서 오는 요청만 받는다. SSH는 열지 않고 SSM으로 접속한다.
resource "aws_security_group" "ai" {
  name        = "${local.name_prefix}-ai-sg"
  description = "V2 prod AI instance"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-ai-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ai_live_from_be" {
  security_group_id            = aws_security_group.ai.id
  description                  = "AI live WebSocket from prod BE"
  referenced_security_group_id = aws_security_group.be.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

# 패키지와 이미지 받기, SSM 연결, BE 호출(ALB)은 FE/NAT 인스턴스를 거쳐 인터넷으로 나간다
resource "aws_vpc_security_group_egress_rule" "ai_all" {
  security_group_id = aws_security_group.ai.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# prod AI 분석 인스턴스 보안 그룹: BE 보안 그룹에서 오는 분석 요청만 받는다. SSH는 열지 않고 SSM으로 접속한다.
resource "aws_security_group" "ai_analysis" {
  name        = "${local.name_prefix}-ai-analysis-sg"
  description = "V2 prod AI analysis instance"
  vpc_id      = local.shared.vpc_id

  tags = {
    Name = "${local.name_prefix}-ai-analysis-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ai_analysis_instance_from_be" {
  security_group_id            = aws_security_group.ai_analysis.id
  description                  = "AI analysis HTTP from prod BE"
  referenced_security_group_id = aws_security_group.be.id
  ip_protocol                  = "tcp"
  from_port                    = 8001
  to_port                      = 8001
}

# 패키지와 이미지 받기, SSM 연결, 외부 공급자(OpenRouter, Modal)와 BE 호출(ALB)은 FE/NAT 인스턴스를 거쳐 인터넷으로 나간다
resource "aws_vpc_security_group_egress_rule" "ai_analysis_all" {
  security_group_id = aws_security_group.ai_analysis.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
