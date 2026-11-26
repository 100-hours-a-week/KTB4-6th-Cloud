# 0단계에서는 조회 결과가 기대한 V2 리소스인지 plan에서 확인하는 용도다.

output "account_id" {
  description = "Terraform을 실행한 AWS 계정"
  value       = data.aws_caller_identity.current.account_id
}

output "vpc_id" {
  description = "V3가 함께 쓰는 V2 VPC"
  value       = data.aws_vpc.v2.id
}

output "vpc_cidr" {
  description = "V2 VPC 대역. 10.1.0.0/16이어야 한다"
  value       = data.aws_vpc.v2.cidr_block
}

output "public_subnets" {
  description = "AZ별 V2 퍼블릭 서브넷 (NAT 인스턴스, 접속용 EC2가 쓴다)"
  value       = { for az, s in data.aws_subnet.v2_public : az => { id = s.id, cidr = s.cidr_block } }
}

output "cluster_name" {
  description = "EKS 클러스터 이름. 접속용 EC2에서 aws eks update-kubeconfig에 쓴다"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "클러스터 API 주소 (비공개)"
  value       = module.eks.cluster_endpoint
}

output "eks_subnets" {
  description = "AZ별 EKS 전용 프라이빗 서브넷"
  value       = { for az, s in aws_subnet.eks : az => { id = s.id, cidr = s.cidr_block } }
}

output "node_security_group_id" {
  description = "노드 보안 그룹. Karpenter EC2NodeClass가 karpenter.sh/discovery 태그로 찾는다"
  value       = module.eks.node_security_group_id
}

output "karpenter" {
  description = "2단계 Karpenter Helm 값에 넣을 항목"
  value = {
    node_role_name     = module.karpenter.node_iam_role_name
    interruption_queue = module.karpenter.queue_name
  }
}

output "bastion_connect" {
  description = "접속용 EC2에 들어가는 명령. ASG가 교체하면 인스턴스 ID가 바뀌어 태그로 찾는다"
  value       = "aws ssm start-session --region ${var.region} --target $(aws ec2 describe-instances --region ${var.region} --filters Name=tag:Name,Values=${local.name_prefix}-bastion Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text)"
}
