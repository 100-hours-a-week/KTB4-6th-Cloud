terraform {
  required_version = ">= 1.16"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region              = "us-east-2"
  allowed_account_ids = ["062270568040"]
}

# 디스크 삭제 후 임시 작업 리소스가 다시 생성되지 않도록 관리에서 제외한다.
# 중지된 EC2와 보안 그룹은 유지하며 실제 리소스를 삭제하지 않는다.
removed {
  from = aws_volume_attachment.scratch
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ebs_volume.scratch
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_instance.helper
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_security_group.helper
  lifecycle {
    destroy = false
  }
}
