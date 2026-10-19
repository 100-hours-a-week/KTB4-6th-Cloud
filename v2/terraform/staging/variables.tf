variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "v1_vpc_cidr" {
  description = "V1(오하이오) VPC 대역. 피어링 경로의 목적지로 쓴다"
  type        = string
  default     = "10.0.0.0/16"
}

variable "env" {
  description = "환경 이름. prod 폴더에서는 prod로 바꾼다"
  type        = string
  default     = "staging"
}

variable "region" {
  description = "V2 리전 (V1은 us-east-2)"
  type        = string
  default     = "ap-northeast-2"
}

variable "be_domain" {
  description = "staging BE 도메인. ALB에서 이 도메인으로 온 요청을 BE 서비스로 보낸다"
  type        = string
  default     = "api-staging.meety.io.kr"
}

variable "be_extra_domains" {
  description = "be_domain 외에 BE로 보낼 도메인. V1 dev 이전 리허설 때는 api-dev.meety.io.kr을 넣어 같은 BE 서비스로 받았다"
  type        = list(string)
  default     = []
}

variable "be_image" {
  description = "BE 컨테이너 이미지. BE dev 77eaf84 커밋의 amd64 이미지를 digest로 고정한다. 이후 버전은 CI/CD가 이미지만 바꿔 배포한다"
  type        = string
  default     = "devkyulim/meety-be@sha256:7b57433e4455bb317ccd9c7628d0663fee35a1989d4a8bf3f34626955d7ede8d"
}

variable "be_ddl_auto" {
  description = "BE의 ddl-auto 값. 평소에는 validate로 두고, 빈 staging DB에 스키마를 새로 만들 때만 apply 시 -var로 create를 준다"
  type        = string
  default     = "validate"

  validation {
    condition     = contains(["validate", "create"], var.be_ddl_auto)
    error_message = "be_ddl_auto는 validate 또는 create만 허용한다."
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
  description = <<-EOT
    블루/그린 배포에서 트래픽을 넘긴 뒤 이전 버전 태스크를 유지하는 시간(분).
    평소에는 회의 최대 시간(90분)보다 길게 95로 둔다.
    V1 dev 이전 리허설 동안에는 지킬 회의가 없어 2로 줄인다. 리허설이 끝나면 95로 되돌린다.
  EOT
  type        = number
  default     = 2
}

variable "be_realtime_paths" {
  description = <<-EOT
    be-realtime으로 보낼 경로. 녹음 WebSocket, 회의 SSE, 알림 SSE (BE 코드 기준).
    V1 dev 이전 리허설 때는 V1 BE가 SSE 연결과 로그아웃 토큰을 서버 메모리에 두어 모든 경로(/*)를 태스크 1개로 보냈다.
  EOT
  type        = list(string)
  default = [
    "/ws/*",
    "/api/v1/meetings/*/events",
    "/api/v1/notifications/events",
  ]
}

variable "be_migration_write_gate_enabled" {
  description = <<-EOT
    BE DB 쓰기 게이트 사용 여부.
    V1 dev 이전 리허설 동안에는 true로 두어 복제 중 서울 DB 쓰기를 막는다.
    켜진 태스크는 재시작할 때마다 닫힌 채로 뜨므로, 전환이 끝나면 false로 바꿔 배포한다.
    리허설을 마치고 dev를 오하이오로 되돌려 false로 둔다 (2026-10-15).
  EOT
  type        = bool
  default     = false
}

variable "be_api_min_count" {
  description = "be-api 최소 태스크 수. 설계값은 2지만 staging은 사용량이 적어 1로 둔다 (부하 테스트 후 조정)"
  type        = number
  default     = 1
}

variable "be_api_max_count" {
  description = "be-api 최대 태스크 수. 설계값은 5지만 staging은 3으로 둔다. 확장 실측 때는 5로 올린다"
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
  description = "카카오 로그인 redirect URI. 카카오 콘솔에 등록한 값과 같아야 한다"
  type        = string
  default     = "https://staging.meety.io.kr/api/auth/kakao/callback"
}

variable "log_retention_days" {
  description = "CloudWatch 로그 보존 기간(일)"
  type        = number
  default     = 14
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

variable "db_private_ip" {
  description = "DB 인스턴스 사설 IP. V1 dev DB의 보안 그룹이 이 주소의 3306 접근만 허용하므로, 인스턴스를 교체해도 바뀌지 않게 고정한다"
  type        = string
  default     = "10.1.10.132"
}

variable "db_server_id" {
  description = "MySQL server_id. 복제하는 서버끼리 겹치면 안 된다 (V1 dev, prod는 1)"
  type        = number
  default     = 2
}

variable "db_replica_private_ip" {
  description = "Read Replica DB 사설 IP (private 서브넷 2c). 복제 설정이 이 주소를 쓰므로 인스턴스를 교체해도 바뀌지 않게 고정한다"
  type        = string
  default     = "10.1.11.132"
}

variable "db_replica_server_id" {
  description = "Read Replica MySQL server_id. 복제하는 서버끼리 겹치면 안 된다 (V1 dev·prod 1, staging Primary 2, 리허설용 3, prod 4·5)"
  type        = number
  default     = 6
}

variable "db_mysql_image" {
  description = "MySQL 컨테이너 이미지. V1과 같은 8.4 계열을 패치 버전까지 고정한다"
  type        = string
  default     = "mysql:8.4.11"
}

variable "db_redis_image" {
  description = "Redis 컨테이너 이미지. BE의 SSE Pub/Sub 용도"
  type        = string
  default     = "redis:8.10.2"
}

variable "fe_allowed_origins" {
  description = "staging FE 주소(origin) 목록. 파일 버킷 CORS와 BE CORS에 쓴다. 로컬 FE에서 staging BE를 붙여 시험할 수 있게 localhost도 둔다"
  type        = list(string)
  default     = ["https://staging.meety.io.kr", "http://localhost:3000", "http://localhost:5173", "http://127.0.0.1:3000"]
}

variable "fe_domain" {
  description = "staging FE 도메인. ALB에서 이 도메인으로 온 요청을 FE 인스턴스로 보낸다"
  type        = string
  default     = "staging.meety.io.kr"
}

variable "fe_extra_domains" {
  description = "fe_domain 외에 FE로 보낼 도메인. V1 dev 이전 리허설 때는 dev.meety.io.kr을 넣어 같은 FE 인스턴스로 받았다"
  type        = list(string)
  default     = []
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
  description = "AI 인스턴스 타입. 무중단 배포 때 신구 컨테이너 4개가 함께 떠야 해서 t3.small(2GB)로 둔다 (t3.micro는 목업 2개만으로 650MB 사용)"
  type        = string
  default     = "t3.small"
}

variable "ai_analysis_instance_type" {
  description = "AI 분석 인스턴스 타입. 무중단 배포 때 신구 analysis 컨테이너 2개가 함께 뜬다. 실측 전이라 ai 인스턴스와 같은 t3.small(2GB)로 둔다"
  type        = string
  default     = "t3.small"
}

variable "ai_root_volume_size" {
  description = "AI 인스턴스 루트 볼륨 크기(GB)"
  type        = number
  default     = 20
}

variable "ai_image" {
  description = "AI 컨테이너 이미지. V1 dev와 같은 AI 7856b5b 커밋의 amd64 이미지를 digest로 고정한다"
  type        = string
  default     = "devkyulim/meety-ai@sha256:93f5ee4d83376fcb3add2df48503e33ea3c8cc67e5923bb94cd0ffb1fc2acf09"
}

variable "gha_deploy_subjects" {
  description = "staging BE 배포 역할을 쓸 수 있는 GitHub Actions 실행 위치 (저장소와 GitHub Environment). 이름이 바뀌어도 유지되는 ID 형식을 쓴다"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:v2-staging",
    "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:v2-staging-migration-approval",
  ]
}

variable "gha_deploy_fe_subjects" {
  description = "staging FE 배포 역할을 쓸 수 있는 GitHub Actions 실행 위치 (저장소와 GitHub Environment)"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-6th-FE@1344634298:environment:v2-staging",
  ]
}

variable "gha_deploy_ai_subjects" {
  description = "staging AI 배포 역할을 쓸 수 있는 GitHub Actions 실행 위치 (저장소와 GitHub Environment)"
  type        = list(string)
  default = [
    "repo:100-hours-a-week@167328634/KTB4-6th-AI@1344635474:environment:v2-staging",
  ]
}


# Redis 분리는 서버 생성과 BE 접속 전환을 나눠 진행한다.
variable "redis_ami_id" {
  description = "Redis 전용 AMI. 기존 DB와 같은 Ubuntu 26.04 arm64이며 변경 시 Redis 인스턴스가 교체된다"
  type        = string
  default     = "ami-01e3230cee0cae555"
}

variable "redis_instance_type" {
  description = "현재 저부하 사용량을 기준으로 시작하는 Redis 전용 타입. 피크 처리 용량은 실측 전이다"
  type        = string
  default     = "t4g.small"
}

variable "redis_root_volume_size" {
  description = "Redis 설정·AOF와 Docker를 저장할 암호화 루트 볼륨 크기(GB)"
  type        = number
  default     = 10
}

variable "redis_private_ip" {
  description = "전용 Redis의 고정 사설 IP. 환경별 private 서브넷 2a에서 사용한다"
  type        = string
  default     = "10.1.10.133"
}

variable "redis_maxmemory_mb" {
  description = "Redis 데이터 메모리 상한(MB). 키를 임의로 지우지 않도록 noeviction을 쓴다"
  type        = number
  default     = 512
}

variable "redis_use_dedicated_instance" {
  description = "데이터 복제와 전환 준비가 끝나면 true로 바꾸어 BE 태스크 템플릿에 전용 Redis 주소를 반영한다"
  type        = bool
  default     = true
}

variable "redis_migration_access_enabled" {
  description = "기존 DB 서버 Redis에서 전용 Redis로 복제할 임시 접속 허용. 이전 검증 후 false로 닫는다"
  type        = bool
  default     = true
}

variable "monitoring_ami_id" {
  description = "모니터링 서버 AMI. FE, AI와 같은 Ubuntu 26.04 amd64이며 변경 시 모니터링 서버가 교체된다"
  type        = string
  default     = "ami-0e677ebf2c8434c2a"
}

variable "monitoring_instance_type" {
  description = "모니터링 서버 타입. Prometheus, Loki, Grafana를 한 대에서 실행한다. 수집 대상이 늘면 실측 후 조정한다"
  type        = string
  default     = "t3.small"
}

variable "monitoring_private_ip" {
  description = "모니터링 서버의 고정 사설 IP. 로그 수집기가 Loki로 보낼 주소이며 private 서브넷 2a에서 사용한다"
  type        = string
  default     = "10.1.10.134"
}

variable "monitoring_root_volume_size" {
  description = "메트릭 15일, 로그 7일 보관 기준 루트 볼륨 크기(GB)"
  type        = number
  default     = 30
}

variable "monitoring_grafana_domain" {
  description = "staging Grafana 접속 도메인. 인증서와 DNS는 shared/에서 만든다"
  type        = string
  default     = "grafana-staging.meety.io.kr"
}

variable "monitoring_images" {
  description = "모니터링 구성 요소 이미지 (태그 고정). 올릴 때는 staging에서 먼저 확인한다"
  type = object({
    prometheus = string
    loki       = string
    grafana    = string
  })
  default = {
    prometheus = "prom/prometheus:v3.2.1"
    loki       = "grafana/loki:3.4.2"
    grafana    = "grafana/grafana:11.5.2"
  }
}
