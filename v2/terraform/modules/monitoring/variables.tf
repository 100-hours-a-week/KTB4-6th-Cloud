variable "name_prefix" {
  description = "환경별 리소스 이름 접두사"
  type        = string
}

variable "env" {
  description = "환경 이름. Prometheus 메트릭의 env 라벨로도 쓴다"
  type        = string
}

variable "region" {
  description = "Parameter Store와 CloudWatch를 조회할 AWS 리전"
  type        = string
}

variable "vpc_id" {
  description = "보안 그룹과 대상 그룹을 만들 VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "공인 IP 없이 사용할 환경 전용 private 서브넷 ID"
  type        = string
}

variable "private_ip" {
  description = "로그 수집기가 Loki로 보낼 고정 사설 IP"
  type        = string
}

variable "ami_id" {
  description = "모니터링 서버 AMI. 이미지 아키텍처(amd64)와 맞아야 한다"
  type        = string
}

variable "instance_type" {
  description = "모니터링 서버 EC2 인스턴스 타입"
  type        = string
}

variable "root_volume_size" {
  description = "메트릭(15일), 로그(7일)와 Docker를 저장할 암호화 루트 볼륨 크기(GB)"
  type        = number
}

variable "config_dir" {
  description = "Prometheus, Loki, Grafana, compose 설정 파일이 있는 폴더 (v2/monitoring)"
  type        = string
}

variable "prometheus_image" {
  description = "Prometheus 이미지 (태그 고정)"
  type        = string
}

variable "loki_image" {
  description = "Loki 이미지 (태그 고정)"
  type        = string
}

variable "grafana_image" {
  description = "Grafana 이미지 (태그 고정)"
  type        = string
}

variable "grafana_domain" {
  description = "Grafana 접속 도메인. ALB 규칙의 Host 조건과 Grafana root URL에 쓴다"
  type        = string
}

variable "grafana_admin_password_parameter_arn" {
  description = "Grafana 관리자 비밀번호 파라미터 ARN. 값은 Terraform이 읽지 않는다"
  type        = string
}

variable "ssm_kms_key_arn" {
  description = "Parameter Store SecureString 복호화용 KMS 키 ARN"
  type        = string
}

variable "alb_security_group_id" {
  description = "Grafana 접근을 허용할 공용 ALB 보안 그룹 ID"
  type        = string
}

variable "https_listener_arn" {
  description = "Grafana 규칙을 추가할 공용 ALB HTTPS 리스너 ARN"
  type        = string
}

variable "listener_rule_priority" {
  description = "Grafana 리스너 규칙 우선순위. staging은 100번대, prod는 200번대를 쓴다"
  type        = number
}

variable "volume_tags" {
  description = "provider 기본 태그가 자동 적용되지 않는 루트 볼륨용 태그"
  type        = map(string)
}

variable "ecs_cluster_arn" {
  description = "ECS 조회 권한을 이 클러스터로 제한할 때 쓰는 ARN"
  type        = string
}

variable "ecs_scrape_services" {
  description = "Prometheus가 수집할 ECS 서비스 이름 목록 (예: meety-v2-staging-be-api)"
  type        = list(string)
}

variable "ecs_scrape_port" {
  description = "BE 태스크에서 /actuator/prometheus를 여는 포트"
  type        = number
}
