# 기존 AI 인스턴스와 배포 방식은 유지하고, 호스트 Agent로 로그 전송만 추가한다.
module "ai_logging" {
  source = "../modules/ai_logging"

  name_prefix        = local.name_prefix
  region             = var.region
  instance_role_name = aws_iam_role.ai.name
  retention_in_days  = var.log_retention_days
  instance_ids = {
    live     = aws_instance.ai.id
    analysis = aws_instance.ai_analysis.id
  }

  depends_on = [aws_iam_role_policy_attachment.ai_ssm]
}
