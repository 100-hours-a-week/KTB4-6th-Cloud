# prod 모니터링 서버 전용 설정. 기존 애플리케이션 변수는 변경하지 않는다.
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
  default     = "10.1.20.134"
}

variable "monitoring_root_volume_size" {
  description = "메트릭 15일, 로그 7일 보관 기준 루트 볼륨 크기(GB)"
  type        = number
  default     = 30
}

variable "monitoring_grafana_domain" {
  description = "prod Grafana 접속 도메인. 인증서와 DNS는 shared/에서 만든다"
  type        = string
  default     = "grafana.meety.io.kr"
}

variable "monitoring_images" {
  description = "모니터링 구성 요소 이미지 (태그 고정). 올릴 때는 staging에서 먼저 확인한다"
  type = object({
    prometheus = string
    loki       = string
    grafana    = string
  })
  default = {
    prometheus = "prom/prometheus:v3.15.0"
    loki       = "grafana/loki:3.4.2"
    grafana    = "grafana/grafana:11.5.2"
  }
}
