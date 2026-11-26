variable "project" {
  description = "리소스 이름과 태그에 쓰는 프로젝트 이름"
  type        = string
  default     = "meety"
}

variable "region" {
  description = "V3 리전. V2와 같은 서울 리전의 VPC를 함께 쓴다"
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "클러스터가 쓰는 가용 영역. V2 VPC의 퍼블릭 서브넷이 있는 2개와 같아야 한다 (5단계 4번 네트워크 설계 4장)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "kubernetes_version" {
  description = "EKS 버전. 표준 지원 중인 버전만 쓴다(연장 지원은 시간당 $0.50로 5배). 1.36은 2027-08-02까지 표준 지원이다"
  type        = string
  default     = "1.36"
}

variable "eks_subnet_cidrs" {
  description = "AZ별 EKS 전용 프라이빗 서브넷 (5단계 4번 네트워크 설계 3장). 만든 뒤 크기를 바꿀 수 없다"
  type        = map(string)
  default = {
    "ap-northeast-2a" = "10.1.64.0/20"
    "ap-northeast-2c" = "10.1.80.0/20"
  }
}

variable "al2023_arm64_ami_id" {
  description = "NAT 인스턴스와 접속용 EC2의 AMI(Amazon Linux 2023 arm64, 2026-11-21 게시). 바꾸면 다음에 뜨는 인스턴스부터 적용된다"
  type        = string
  default     = "ami-0c752e0d8198a3081"
}

variable "nat_instance_type" {
  description = "AZ별 NAT 인스턴스 타입. 설계값은 c6gn.medium이며, 경로 검증 기간에는 t4g.small로 줄인다(회의 음성 피크 대역폭은 감당하지 못한다)"
  type        = string
  default     = "t4g.small"
}

variable "bastion_instance_type" {
  description = "클러스터 접속용 EC2 타입. kubectl, helm만 실행한다"
  type        = string
  default     = "t4g.micro"
}

variable "platform_instance_type" {
  description = "platform 관리형 노드 그룹 타입. 설계값은 m7g.xlarge이며, 경로 검증 기간에는 m7g.large로 줄인다(1대가 멈추면 남은 1대에 운영 도구가 다 들어가지 않는다)"
  type        = string
  default     = "m7g.large"
}

variable "public_access_cidrs" {
  description = "클러스터 API 공개 접근을 허용할 담당자 IP(/32). 비워 두면 비공개만 둔다 (5단계 4번 6.3절: 구축 초기와 비상 시에만 잠시 켠다)"
  type        = list(string)
  default     = []
}
