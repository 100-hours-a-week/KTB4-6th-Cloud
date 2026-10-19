variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "v1_vpc_cidr" {
  description = "V1(오하이오) VPC 대역. 피어링 경로의 목적지로 쓴다 (오하이오 prod DB를 서울로 옮길 때 덤프, 복제)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "env" {
  description = "환경 이름"
  type        = string
  default     = "prod"
}

variable "region" {
  description = "V2 리전 (V1은 us-east-2)"
  type        = string
  default     = "ap-northeast-2"
}

variable "private_subnet_netnum_base" {
  description = "prod private 서브넷 번호의 시작값. VPC(10.1.0.0/16)를 /24로 나눈 번호이며, 20이면 10.1.20.0/24(2a), 10.1.21.0/24(2c)가 된다 (staging은 10번대)"
  type        = number
  default     = 20
}

variable "be_domain" {
  description = "prod BE 도메인. ALB에서 이 도메인으로 온 요청을 BE 서비스로 보낸다. DNS는 아직 오하이오 V1을 가리킨다"
  type        = string
  default     = "api.meety.io.kr"
}

variable "be_image" {
  description = "BE 컨테이너 이미지. 첫 태스크 정의에만 쓰고, 이후 버전은 CI/CD가 이미지만 바꿔 배포한다. staging에서 검증한 이미지(오늘 기준)를 digest로 고정한다"
  type        = string
  default     = "devkyulim/meety-be@sha256:a24a7a0a64dd69e9064ed46a3769fe593f0dd72764d4f747269cee437773d1ea"
}

variable "be_ddl_auto" {
  description = "BE의 ddl-auto 값. prod profile 기본값(update) 대신 validate로 두어, 엔티티와 스키마 차이를 기동 실패로 드러낸다. 스키마 변경은 Flyway로 한다"
  type        = string
  default     = "validate"

  validation {
    condition     = contains(["validate"], var.be_ddl_auto)
    error_message = "prod의 be_ddl_auto는 validate만 허용한다."
  }
}

variable "be_container_port" {
  description = "BE 컨테이너가 요청을 받는 포트 (Spring Boot 기본값)"
  type        = number
  default     = 8080
}

variable "be_cpu" {
  description = "태스크 CPU 단위 (1024 = 1 vCPU). ECS 설계 초기값이며 부하 실측 전이다"
  type        = number
  default     = 1024
}

variable "be_memory" {
  description = "태스크 메모리 MiB. ECS 설계 초기값이며 부하 실측 전이다"
  type        = number
  default     = 2048
}

variable "be_health_check_path" {
  description = "ALB가 태스크 상태를 확인하는 경로. DB 연결 상태도 함께 반영된다"
  type        = string
  default     = "/actuator/health"
}

variable "be_bake_time_minutes" {
  description = "블루/그린 배포에서 트래픽을 넘긴 뒤 이전 버전 태스크를 유지하는 시간(분). staging과 같은 값으로 시작한다 (회의 기준 배포 방식은 보류 중)"
  type        = number
  default     = 2
}

variable "be_realtime_paths" {
  description = "be-realtime으로 보낼 경로. 녹음 WebSocket, 회의 SSE, 알림 SSE (BE 코드 기준)"
  type        = list(string)
  default = [
    "/ws/*",
    "/api/v1/meetings/*/events",
    "/api/v1/notifications/events",
  ]
}

variable "be_services_enabled" {
  description = <<-EOT
    BE 서비스(be-api, be-realtime)의 태스크를 띄울지 여부.
    staging과 같이 기본 활성화한다. apply 시 각 서비스가 최소 태스크 수까지 기동한다.
    기동 전에 prod 파라미터와 DB 스키마를 준비해야 한다. 임시로 중지할 때만 false로 두어 스케일링 범위를 0으로 만든다
  EOT
  type        = bool
  default     = true
}

variable "be_api_min_count" {
  description = "be-api 최소 태스크 수. 현재 staging과 같은 1로 시작하고, 부하 실측 후 조정한다"
  type        = number
  default     = 1
}

variable "be_api_max_count" {
  description = "be-api 최대 태스크 수. 현재 staging과 같은 3으로 시작하고, 부하 실측 후 조정한다"
  type        = number
  default     = 3
}

variable "be_api_cpu_target" {
  description = "be-api 오토스케일링 목표 평균 CPU 사용률(%) (설계 추정값)"
  type        = number
  default     = 50
}

variable "be_realtime_min_count" {
  description = "be-realtime 최소 태스크 수 (부하 테스트 후 조정)"
  type        = number
  default     = 1
}

variable "be_realtime_max_count" {
  description = "be-realtime 최대 태스크 수 (부하 테스트 후 조정)"
  type        = number
  default     = 3
}

variable "be_realtime_cpu_target" {
  description = "be-realtime 오토스케일링 목표 평균 CPU 사용률(%). be-api와 같은 값으로 시작하고, 연결 수와 CPU 관계를 실측한 뒤 기준을 다시 정한다"
  type        = number
  default     = 50
}

variable "be_kakao_redirect_uri" {
  description = "카카오 로그인 redirect URI. 카카오 콘솔에 등록한 값과 같아야 한다 (staging과 같은 형식)"
  type        = string
  default     = "https://meety.io.kr/api/auth/kakao/callback"
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보존 기간(일)"
  type        = number
  default     = 30
}

variable "fe_ami_id" {
  description = "FE 인스턴스 AMI. Ubuntu 26.04 amd64 (Canonical, 20261003). 새 AMI로 바꾸면 인스턴스가 교체된다"
  type        = string
  default     = "ami-0e677ebf2c8434c2a"
}

variable "fe_instance_type" {
  description = "FE 인스턴스 타입. NAT를 겸하며, 처리 용량은 검증 전 초기값이다"
  type        = string
  default     = "t3.micro"
}

variable "fe_root_volume_size" {
  description = "FE 인스턴스 루트 볼륨 크기(GB). FE 앱(Docker, nginx)을 올릴 여유를 둔다"
  type        = number
  default     = 20
}

variable "db_ami_id" {
  description = "DB 인스턴스 AMI. Ubuntu 26.04 arm64 (Canonical, 20261003). 새 AMI로 바꾸면 인스턴스가 교체된다"
  type        = string
  default     = "ami-01e3230cee0cae555"
}

variable "db_instance_type" {
  description = "DB 인스턴스 타입. DB 사이징 설계의 초기값(t4g.small)이며, 처리 용량은 실측 전이다"
  type        = string
  default     = "t4g.small"
}

variable "db_root_volume_size" {
  description = "DB 인스턴스 루트 볼륨 크기(GB). DB 사이징 설계의 비용 산정 기준(노드당 30GB)"
  type        = number
  default     = 30
}

variable "db_primary_private_ip" {
  description = "Primary DB 사설 IP (private 서브넷 2a). 오하이오 prod DB 보안 그룹과 복제 설정이 이 주소를 쓰므로, 인스턴스를 교체해도 바뀌지 않게 고정한다"
  type        = string
  default     = "10.1.20.132"
}

variable "db_replica_private_ip" {
  description = "Read Replica DB 사설 IP (private 서브넷 2c). Primary에서 복제받는다"
  type        = string
  default     = "10.1.21.132"
}

variable "db_primary_server_id" {
  description = "Primary MySQL server_id. 복제하는 서버끼리 겹치면 안 된다 (V1 dev·prod 1, staging 2, 리허설용 3)"
  type        = number
  default     = 4
}

variable "db_replica_server_id" {
  description = "Read Replica MySQL server_id"
  type        = number
  default     = 5
}

variable "db_mysql_image" {
  description = "MySQL 컨테이너 이미지. V1과 같은 8.4 계열을 패치 버전까지 고정한다"
  type        = string
  default     = "mysql:8.4.11"
}

variable "db_redis_image" {
  description = "Redis 컨테이너 이미지. BE의 SSE Pub/Sub 용도. Primary DB 인스턴스에서 같이 실행한다"
  type        = string
  default     = "redis:8.10.2"
}

variable "fe_allowed_origins" {
  description = "prod FE 주소(origin) 목록. 파일 버킷 CORS와 BE CORS에 쓴다"
  type        = list(string)
  default     = ["https://meety.io.kr"]
}

variable "fe_domain" {
  description = "prod FE 도메인. ALB에서 이 도메인으로 온 요청을 FE 인스턴스로 보낸다. DNS는 아직 오하이오 V1을 가리킨다"
  type        = string
  default     = "meety.io.kr"
}

variable "fe_container_port" {
  description = "FE 컨테이너(Next.js)가 요청을 받는 포트"
  type        = number
  default     = 3000
}

variable "fe_standby_port" {
  description = "FE 무중단 배포 때 새 컨테이너를 띄우는 두 번째 포트. fe_container_port와 번갈아 쓴다"
  type        = number
  default     = 3001
}

variable "fe_health_check_path" {
  description = "ALB가 FE 상태를 확인하는 경로 (V1 컨테이너 헬스 체크와 같은 경로)"
  type        = string
  default     = "/api/health"
}

variable "ai_ami_id" {
  description = "AI 인스턴스 AMI. FE와 같은 Ubuntu 26.04 amd64 (AI 이미지가 amd64 전용). 새 AMI로 바꾸면 인스턴스가 교체된다"
  type        = string
  default     = "ami-0e677ebf2c8434c2a"
}

variable "ai_instance_type" {
  description = "AI live 인스턴스 타입. staging과 같은 t3.small(2GB)로 시작한다 (실측 전)"
  type        = string
  default     = "t3.small"
}

variable "ai_analysis_instance_type" {
  description = "AI 분석 인스턴스 타입. staging과 같은 t3.small(2GB)로 시작한다 (실측 전)"
  type        = string
  default     = "t3.small"
}

variable "ai_root_volume_size" {
  description = "AI 인스턴스 루트 볼륨 크기(GB)"
  type        = number
  default     = 20
}

variable "gha_deploy_subjects" {
  description = "prod BE 배포 역할을 쓸 수 있는 GitHub Actions 실행 위치 (저장소와 GitHub Environment). 이름이 바뀌어도 유지되는 ID 형식을 쓴다"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:production",
    "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:production-migration-approval",
  ]
}

variable "gha_deploy_fe_subjects" {
  description = "prod FE 배포 역할을 쓸 수 있는 GitHub Actions 실행 위치 (저장소와 GitHub Environment)"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-6th-FE@1344634298:environment:production",
  ]
}

variable "gha_deploy_ai_subjects" {
  description = "prod AI 배포 역할을 쓸 수 있는 GitHub Actions 실행 위치 (저장소와 GitHub Environment)"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-6th-AI@1344635474:environment:production",
  ]
}
