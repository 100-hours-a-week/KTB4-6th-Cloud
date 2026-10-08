# V2 ECS 클러스터: dev와 prod 서비스가 같이 쓴다.
# 클러스터 자체는 요금이 없고, 태스크(Fargate)를 실행한 시간만큼 과금된다.

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  # Container Insights(태스크별 CPU, 메모리 지표)는 CloudWatch 요금이 따로 나온다.
  # 모니터링 구성(10/13) 때 켠다.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = local.name_prefix
  }
}

# 클러스터에서 쓸 수 있는 실행 방식: Fargate(On-Demand)와 Fargate Spot
# 기본값은 On-Demand 1개를 먼저 채우는 방식이다. 서비스마다 따로 정할 수 있다.
# Spot 혼합(설계: base On-Demand 1~2개, 이후 On-Demand:Spot = 1:3~1:4)은 BE 실시간 기능 수정 후 오토스케일링과 함께 적용한다.
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}
