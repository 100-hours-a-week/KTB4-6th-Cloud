# V2 staging ECS 클러스터
# 클러스터는 환경별로 나눈다. 배포 권한을 클러스터 단위로 분리하고, 환경마다 설정을 따로 두기 위해서다.
# 클러스터 자체는 요금이 없고, 태스크(Fargate)를 실행한 시간만큼 과금된다.

resource "aws_ecs_cluster" "main" {
  name = local.name_prefix

  # Container Insights(태스크별 CPU, 메모리 지표)는 CloudWatch 요금이 따로 나온다.
  # 모니터링 구성(10/13) 때 환경별로 켤지 정한다.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = {
    Name = local.name_prefix
  }
}

# 클러스터에서 쓸 수 있는 실행 방식: Fargate(On-Demand)와 Fargate Spot
# 기본값은 On-Demand. Spot은 서비스마다 따로 정한다.
# - REST 서버: 오토스케일링 적용 후 On-Demand base + Spot 혼합 (설계값)
# - 실시간 서버(WebSocket, SSE): Spot 회수 시 진행 중인 회의 연결이 끊기므로 On-Demand만
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}
