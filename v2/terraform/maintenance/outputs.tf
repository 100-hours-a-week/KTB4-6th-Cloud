output "maintenance_url" {
  description = "점검 페이지 확인 주소"
  value       = "https://${var.maintenance_domain}/"
}

output "maintenance_enabled" {
  description = "true면 운영 전체 점검, false면 헤더 기반 미리보기"
  value       = var.maintenance_enabled
}

output "maintenance_allowed_cidrs" {
  description = "점검 시작 시 prod의 기존 라우팅 규칙에 적용할 공인 IP"
  value       = var.maintenance_allowed_cidrs
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.page.id
}

output "maintenance_bucket" {
  value = aws_s3_bucket.page.id
}

output "listener_rules" {
  value = {
    fe  = aws_lb_listener_rule.fallback_fe.arn
    api = aws_lb_listener_rule.fallback_api.arn
  }
}
