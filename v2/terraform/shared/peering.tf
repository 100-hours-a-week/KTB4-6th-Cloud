# V1(오하이오) VPC와 V2(서울) VPC 피어링
# - V1 MySQL을 V2 MySQL로 덤프, 복제하기 위해 사설 IP로 연결한다.
# - 요청은 서울에서, 수락은 오하이오 provider로 같은 apply에서 처리한다.
# - 경로는 양쪽에서 따로 추가한다. 서울은 staging/의 private 라우트 테이블, 오하이오는 V1 코드의 public 라우트 테이블.
#   V1 라우트 테이블은 route 블록을 안에 적는 방식이라, 오하이오 경로를 여기서 aws_route로 만들면 V1 plan과 충돌한다.
resource "aws_vpc_peering_connection" "v1" {
  vpc_id      = aws_vpc.main.id
  peer_vpc_id = var.v1_vpc_id
  peer_region = var.v1_region

  # 리전 간 피어링은 요청 쪽에서 자동 수락할 수 없다. 아래 accepter가 수락한다.
  auto_accept = false

  tags = {
    Name = "${local.name_prefix}-to-v1"
  }
}

resource "aws_vpc_peering_connection_accepter" "v1" {
  provider = aws.v1

  vpc_peering_connection_id = aws_vpc_peering_connection.v1.id
  auto_accept               = true

  tags = {
    Name = "${local.name_prefix}-to-v1"
  }
}
