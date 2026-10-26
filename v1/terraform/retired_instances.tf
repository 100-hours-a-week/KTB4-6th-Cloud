# 오하이오 전체 디스크 삭제 후 루트 디스크의 자동 재생성을 막는다.
# EC2 객체는 중지 상태로 남기며 여기서 삭제하지 않는다.
removed {
  from = aws_instance.dev_app
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_instance.dev_ai
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_instance.dev_data
  lifecycle {
    destroy = false
  }
}
