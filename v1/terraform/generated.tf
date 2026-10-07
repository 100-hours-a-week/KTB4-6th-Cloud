# Please review these resources and move them into your main configuration files.

resource "aws_iam_instance_profile" "ec2_prod" {
  name     = "meety-ec2-prod"
  path     = "/"
  role     = "meety-ec2-prod"
  tags     = {}
  tags_all = {}
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTP"
  from_port         = 80
  ip_protocol       = "tcp"
  region            = "us-east-2"
  security_group_id = "sg-09ac11928cda5a281"
  to_port           = 80
}

resource "aws_security_group" "ai" {
  description = "ai-tier-SG"
  name        = "ai-sg-v1"
  region      = "us-east-2"
  tags = {
    Name = "ai-sg-v1"
  }
  tags_all = {
    Name = "ai-sg-v1"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_security_group" "data" {
  description = "data-tier-SG"
  name        = "data-sg-v1"
  region      = "us-east-2"
  tags = {
    Name    = "data-sg-v1"
    Service = "meety"
  }
  tags_all = {
    Name    = "data-sg-v1"
    Service = "meety"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_iam_role" "ec2_dev" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "Allows EC2 instances to call AWS services on your behalf.\nmeety-ec2-v1-dev"
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "meety-ec2-v1-dev"
  path                  = "/"
  tags = {
    Service = "dev"
  }
  tags_all = {
    Service = "dev"
  }
}

resource "aws_security_group" "ssh" {
  description = "SSH"
  name        = "SSH"
  region      = "us-east-2"
  tags = {
    Name = "SSH"
  }
  tags_all = {
    Name = "SSH"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_iam_policy" "params_read_server" {
  description = "meety-params-read-server"
  name        = "meety-params-read-server"
  path        = "/"
  policy = jsonencode({
    Statement = [{
      Action   = ["ssm:GetParametersByPath", "ssm:GetParameters", "ssm:GetParameter"]
      Effect   = "Allow"
      Resource = "arn:aws:ssm:us-east-2:${local.account_id}:parameter/meety/*"
      Sid      = "ReadParams"
    }]
    Version = "2012-10-17"
  })
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_iam_role" "github_actions_ssm" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [
            "repo:100-hours-a-week@167328634/KTB4-6th-FE@1344634298:environment:production",
            "repo:100-hours-a-week@167328634/KTB4-6th-FE@1344634298:environment:staging",
            "repo:100-hours-a-week@167328634/KTB4-6th-FE@1344634298:environment:production-migration-approval",
            "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:production",
            "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:staging",
            "repo:100-hours-a-week@167328634/KTB4-6th-BE@1344634945:environment:production-migration-approval",
            "repo:100-hours-a-week@167328634/KTB4-6th-AI@1344635474:environment:production",
            "repo:100-hours-a-week@167328634/KTB4-6th-AI@1344635474:environment:staging",
            "repo:100-hours-a-week@167328634/KTB4-6th-AI@1344635474:environment:production-migration-approval",
          ]
        }
      }
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
    }]
    Version = "2012-10-17"
  })
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "SSM"
  path                  = "/"
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  cidr_ipv4         = var.ssh_allowed_cidr
  from_port         = 22
  ip_protocol       = "tcp"
  region            = "us-east-2"
  security_group_id = "sg-0769decbce98ab96b"
  to_port           = 22
}

resource "aws_s3_bucket_ownership_controls" "dev" {
  bucket = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
  region = "us-east-2"
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_vpc_security_group_egress_rule" "data_all" {
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  region            = "us-east-2"
  security_group_id = "sg-016d5ef2c40006305"
}

resource "aws_iam_openid_connect_provider" "github" {
  client_id_list = ["sts.amazonaws.com"]
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
  thumbprint_list = ["ab9d0263244dd0326eb67015705a667e79cfe998"]
  url             = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_ssm_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = "meety-ec2-cloudwatch-role"
}

resource "aws_iam_policy" "github_actions_ssm_deploy" {
  description = "meety-GitHubActions-SSM-Deploy"
  name        = "meety-GitHubActions-SSM-Deploy"
  path        = "/"
  policy = jsonencode({
    Statement = [{
      Action = "ssm:SendCommand"
      Condition = {
        StringEquals = {
          "ssm:resourceTag/Service" = "meety"
        }
      }
      Effect   = "Allow"
      Resource = "arn:aws:ec2:us-east-2:${local.account_id}:instance/*"
      Sid      = "SendCommandToMeetyInstances"
      }, {
      Action   = "ssm:SendCommand"
      Effect   = "Allow"
      Resource = "arn:aws:ssm:us-east-2::document/AWS-RunShellScript"
      Sid      = "AllowRunShellScriptDocument"
      }, {
      Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"]
      Effect   = "Allow"
      Resource = "*"
      Sid      = "ReadCommandResult"
    }]
    Version = "2012-10-17"
  })
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_cloudwatch_log_group" "dev_app_docker" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/dev-meety/app/docker"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_s3_bucket_server_side_encryption_configuration" "prod" {
  bucket = "meety-file-bucket-${local.account_id}-us-east-2-an"
  region = "us-east-2"
  rule {
    blocked_encryption_types = ["SSE-C"]
    bucket_key_enabled       = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_internet_gateway" "main" {
  region = "us-east-2"
  tags = {
    Name    = "meety-internet-gateway"
    Service = "meety"
  }
  tags_all = {
    Name    = "meety-internet-gateway"
    Service = "meety"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_cloudwatch_log_group" "prod_ai_docker" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/meety/ec2-ai/docker"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_cloudwatch_log_group" "prod_app_docker" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/meety/app/docker"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_route_table" "public" {
  propagating_vgws = []
  region           = "us-east-2"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "igw-01d5e5e30cfac97f2"
  }
  tags = {
    Name    = "meety-route-table-public"
    Service = "meety"
  }
  tags_all = {
    Name    = "meety-route-table-public"
    Service = "meety"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_s3_bucket_public_access_block" "prod" {
  block_public_acls       = true
  block_public_policy     = true
  bucket                  = "meety-file-bucket-${local.account_id}-us-east-2-an"
  ignore_public_acls      = true
  region                  = "us-east-2"
  restrict_public_buckets = true
}

resource "aws_cloudwatch_log_group" "prod_app_nginx_access" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/meety/app/nginx-access"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_iam_instance_profile" "ec2_cloudwatch" {
  name     = "meety-ec2-cloudwatch-role"
  path     = "/"
  role     = "meety-ec2-cloudwatch-role"
  tags     = {}
  tags_all = {}
}

resource "aws_vpc_security_group_ingress_rule" "ai_8000_from_app" {
  description                  = "Features-of-Real-time-transcription"
  from_port                    = 8000
  ip_protocol                  = "tcp"
  referenced_security_group_id = "sg-09ac11928cda5a281"
  region                       = "us-east-2"
  security_group_id            = "sg-0cb07d86ec124f4bc"
  to_port                      = 8000
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_params_read" {
  policy_arn = "arn:aws:iam::${local.account_id}:policy/meety-params-read-server"
  role       = "meety-ec2-cloudwatch-role"
}

resource "aws_s3_bucket_policy" "prod" {
  bucket = "meety-file-bucket-${local.account_id}-us-east-2-an"
  policy = jsonencode({
    Statement = [{
      Action = "s3:*"
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
      Effect    = "Deny"
      Principal = "*"
      Resource  = ["arn:aws:s3:::meety-file-bucket-${local.account_id}-us-east-2-an", "arn:aws:s3:::meety-file-bucket-${local.account_id}-us-east-2-an/*"]
      Sid       = "DenyInsecureTransport"
    }]
    Version = "2012-10-17"
  })
  region = "us-east-2"
}

resource "aws_s3_bucket_cors_configuration" "dev" {
  bucket = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
  region = "us-east-2"
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["DELETE", "GET", "HEAD", "POST", "PUT"]
    allowed_origins = ["http://127.0.0.1:3000", "http://localhost:3000", "http://localhost:5173", "https://dev.meety.io.kr"]
    expose_headers  = ["Access-Control-Allow-Origin", "ETag"]
    max_age_seconds = 0
  }
}

resource "aws_iam_role_policy_attachment" "ec2_prod_cw_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = "meety-ec2-prod"
}

resource "aws_iam_role_policy_attachment" "ec2_prod_s3_rw" {
  policy_arn = "arn:aws:iam::${local.account_id}:policy/meety-s3-access-rw-prod"
  role       = "meety-ec2-prod"
}

resource "aws_iam_role_policy_attachment" "ec2_dev_ssm_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = "meety-ec2-v1-dev"
}

resource "aws_vpc_security_group_ingress_rule" "ai_8001_from_app" {
  description                  = "Other-Features"
  from_port                    = 8001
  ip_protocol                  = "tcp"
  referenced_security_group_id = "sg-09ac11928cda5a281"
  region                       = "us-east-2"
  security_group_id            = "sg-0cb07d86ec124f4bc"
  to_port                      = 8001
}

resource "aws_cloudwatch_log_group" "dev_app_nginx_error" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/dev-meety/app/nginx-error"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_iam_role_policy_attachment" "ec2_cloudwatch_cw_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = "meety-ec2-cloudwatch-role"
}

resource "aws_vpc_security_group_ingress_rule" "data_redis_from_app" {
  from_port                    = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = "sg-09ac11928cda5a281"
  region                       = "us-east-2"
  security_group_id            = "sg-016d5ef2c40006305"
  to_port                      = 6379
}

resource "aws_vpc_security_group_egress_rule" "ai_all" {
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  region            = "us-east-2"
  security_group_id = "sg-0cb07d86ec124f4bc"
}

resource "aws_cloudwatch_log_group" "dev_app_nginx_access" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/dev-meety/app/nginx-access"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_subnet" "public_a" {
  assign_ipv6_address_on_creation                = false
  availability_zone                              = "us-east-2a"
  cidr_block                                     = "10.0.1.0/24"
  enable_dns64                                   = false
  enable_resource_name_dns_a_record_on_launch    = false
  enable_resource_name_dns_aaaa_record_on_launch = false
  ipv6_native                                    = false
  map_public_ip_on_launch                        = true
  private_dns_hostname_type_on_launch            = "ip-name"
  region                                         = "us-east-2"
  tags = {
    Name    = "meety-public-subnet"
    Service = "meety"
  }
  tags_all = {
    Name    = "meety-public-subnet"
    Service = "meety"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_iam_role_policy_attachment" "ec2_prod_params_editor" {
  policy_arn = "arn:aws:iam::${local.account_id}:policy/meety-params-editor"
  role       = "meety-ec2-prod"
}

resource "aws_instance" "dev_ai" {
  ami                                  = "ami-0e5497a77ef21b5ac"
  associate_public_ip_address          = true
  availability_zone                    = "us-east-2a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  iam_instance_profile                 = "meety-ec2-cloudwatch-role"
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.micro"
  ipv6_address_count                   = 0
  key_name                             = "meety-v1"
  monitoring                           = false
  placement_partition_number           = 0
  private_ip                           = "10.0.1.188"
  region                               = "us-east-2"
  secondary_private_ips                = []
  security_groups                      = []
  source_dest_check                    = true
  subnet_id                            = "subnet-0eb391e5688b1e282"
  tags = {
    Name    = "dev-ai-v1"
    Service = "meety-staging"
  }
  tags_all = {
    Name    = "dev-ai-v1"
    Service = "meety-staging"
  }
  tenancy                = "default"
  vpc_security_group_ids = ["sg-0769decbce98ab96b", "sg-0cb07d86ec124f4bc"]
  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }
  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }
  credit_specification {
    cpu_credits = "unlimited"
  }
  enclave_options {
    enabled = false
  }
  maintenance_options {
    auto_recovery = "default"
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }
  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    tags_all              = {}
    throughput            = 125
    volume_size           = 30
    volume_type           = "gp3"
  }
}

resource "aws_instance" "prod_ai" {
  ami                                  = "ami-0e5497a77ef21b5ac"
  associate_public_ip_address          = true
  availability_zone                    = "us-east-2a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  iam_instance_profile                 = "meety-ec2-cloudwatch-role"
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.micro"
  ipv6_address_count                   = 0
  key_name                             = "meety-v1"
  monitoring                           = false
  placement_partition_number           = 0
  private_ip                           = "10.0.1.216"
  region                               = "us-east-2"
  secondary_private_ips                = []
  security_groups                      = []
  source_dest_check                    = true
  subnet_id                            = "subnet-0eb391e5688b1e282"
  tags = {
    Name    = "ai-v1-meety"
    Service = "meety"
  }
  tags_all = {
    Name    = "ai-v1-meety"
    Service = "meety"
  }
  tenancy                = "default"
  vpc_security_group_ids = ["sg-0769decbce98ab96b", "sg-0cb07d86ec124f4bc"]
  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }
  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }
  credit_specification {
    cpu_credits = "unlimited"
  }
  enclave_options {
    enabled = false
  }
  maintenance_options {
    auto_recovery = "default"
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }
  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    tags_all              = {}
    throughput            = 125
    volume_size           = 30
    volume_type           = "gp3"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_https" {
  cidr_ipv4         = "0.0.0.0/0"
  description       = "HTTPS"
  from_port         = 443
  ip_protocol       = "tcp"
  region            = "us-east-2"
  security_group_id = "sg-09ac11928cda5a281"
  to_port           = 443
}

resource "aws_route_table_association" "public_a" {
  region         = "us-east-2"
  route_table_id = "rtb-006dcab3f189780a2"
  subnet_id      = "subnet-0eb391e5688b1e282"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dev" {
  bucket = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
  region = "us-east-2"
  rule {
    blocked_encryption_types = ["SSE-C"]
    bucket_key_enabled       = true
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudwatch_log_group" "dev_ai_docker" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/dev-meety/ai/docker"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_iam_role_policy" "github_actions_ssm" {
  name = "SSMPolicy"
  policy = jsonencode({
    Statement = [{
      # FE/BE는 app 서버, AI는 ai 서버에만 배포 명령을 보낸다. data 서버는 제외한다.
      Action = "ssm:SendCommand"
      Effect = "Allow"
      Resource = [
        aws_instance.prod_app.arn,
        aws_instance.prod_ai.arn,
        aws_instance.dev_app.arn,
        aws_instance.dev_ai.arn,
        "arn:aws:ssm:us-east-2::document/AWS-RunShellScript",
      ]
      Sid = "SendDeployCommand"
      }, {
      # GetCommandInvocation은 리소스 단위 권한을 지원하지 않는다.
      Action   = "ssm:GetCommandInvocation"
      Effect   = "Allow"
      Resource = "*"
      Sid      = "ReadCommandResult"
    }]
    Version = "2012-10-17"
  })
  role = "SSM"
}

resource "aws_iam_policy" "params_editor" {
  description = "meety-params-editor"
  name        = "meety-params-editor"
  path        = "/"
  policy = jsonencode({
    Statement = [{
      Action   = "ssm:DescribeParameters"
      Effect   = "Allow"
      Resource = "*"
      Sid      = "ConsoleList"
      }, {
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath", "ssm:GetParameterHistory", "ssm:PutParameter", "ssm:ListTagsForResource"]
      Effect   = "Allow"
      Resource = "arn:aws:ssm:us-east-2:${local.account_id}:parameter/meety/*"
      Sid      = "ParamsReadWrite"
    }]
    Version = "2012-10-17"
  })
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_s3_bucket_cors_configuration" "prod" {
  bucket = "meety-file-bucket-${local.account_id}-us-east-2-an"
  region = "us-east-2"
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["DELETE", "GET", "HEAD", "POST", "PUT"]
    allowed_origins = ["http://127.0.0.1:3000", "http://localhost:3000", "http://localhost:5173", "https://dev.meety.io.kr", "https://meety.io.kr"]
    expose_headers  = ["Access-Control-Allow-Origin", "ETag"]
    max_age_seconds = 0
  }
}

resource "aws_iam_policy" "s3_rw_prod" {
  description = "meety-s3-file-access-key-rw-prod"
  name        = "meety-s3-access-rw-prod"
  path        = "/"
  policy = jsonencode({
    Statement = [{
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Effect   = "Allow"
      Resource = "arn:aws:s3:::meety-file-bucket-${local.account_id}-us-east-2-an/*"
      Sid      = "ObjectAccess"
      }, {
      Action   = "s3:ListBucket"
      Effect   = "Allow"
      Resource = "arn:aws:s3:::meety-file-bucket-${local.account_id}-us-east-2-an"
      Sid      = "ListForNotFound"
    }]
    Version = "2012-10-17"
  })
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_dev_cw_agent" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = "meety-ec2-v1-dev"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  region            = "us-east-2"
  security_group_id = "sg-09ac11928cda5a281"
}

resource "aws_instance" "prod_data" {
  ami                                  = "ami-0e5497a77ef21b5ac"
  associate_public_ip_address          = true
  availability_zone                    = "us-east-2a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.micro"
  ipv6_address_count                   = 0
  key_name                             = "meety-v1"
  monitoring                           = false
  placement_partition_number           = 0
  private_ip                           = "10.0.1.143"
  region                               = "us-east-2"
  secondary_private_ips                = []
  security_groups                      = []
  source_dest_check                    = true
  subnet_id                            = "subnet-0eb391e5688b1e282"
  tags = {
    Name    = "data-v1-meety"
    Service = "meety"
  }
  tags_all = {
    Name    = "data-v1-meety"
    Service = "meety"
  }
  tenancy                = "default"
  vpc_security_group_ids = ["sg-016d5ef2c40006305", "sg-0769decbce98ab96b"]
  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }
  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }
  credit_specification {
    cpu_credits = "unlimited"
  }
  enclave_options {
    enabled = false
  }
  maintenance_options {
    auto_recovery = "default"
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }
  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    tags_all              = {}
    throughput            = 125
    volume_size           = 30
    volume_type           = "gp3"
  }
}

resource "aws_cloudwatch_log_group" "prod_app_nginx_error" {
  deletion_protection_enabled = false
  log_group_class             = "STANDARD"
  name                        = "/meety/app/nginx-error"
  region                      = "us-east-2"
  retention_in_days           = 0
  skip_destroy                = false
  tags                        = {}
  tags_all                    = {}
}

resource "aws_security_group" "app" {
  description = "app-tier-SG"
  name        = "app-sg-v1"
  region      = "us-east-2"
  tags = {
    Name    = "app-sg-v1"
    Service = "meety"
  }
  tags_all = {
    Name    = "app-sg-v1"
    Service = "meety"
  }
  vpc_id = "vpc-0cd787f082879815e"
}

resource "aws_vpc" "main" {
  assign_generated_ipv6_cidr_block     = false
  cidr_block                           = "10.0.0.0/16"
  enable_dns_hostnames                 = false
  enable_dns_support                   = true
  enable_network_address_usage_metrics = false
  instance_tenancy                     = "default"
  region                               = "us-east-2"
  tags = {
    Name    = "meety-vpc"
    Service = "meety"
  }
  tags_all = {
    Name    = "meety-vpc"
    Service = "meety"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_dev_params_read" {
  policy_arn = "arn:aws:iam::${local.account_id}:policy/meety-params-read-server"
  role       = "meety-ec2-v1-dev"
}

resource "aws_iam_role_policy_attachment" "ec2_dev_s3_rw" {
  policy_arn = "arn:aws:iam::${local.account_id}:policy/meety-s3-access-rw-dev"
  role       = "meety-ec2-v1-dev"
}

resource "aws_s3_bucket_public_access_block" "dev" {
  block_public_acls       = true
  block_public_policy     = true
  bucket                  = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
  ignore_public_acls      = true
  region                  = "us-east-2"
  restrict_public_buckets = true
}

resource "aws_iam_instance_profile" "ec2_dev" {
  name     = "meety-ec2-v1-dev"
  path     = "/"
  role     = "meety-ec2-v1-dev"
  tags     = {}
  tags_all = {}
}

resource "aws_iam_policy" "s3_rw_dev" {
  description = "meety-s3-file-access-key-rw-dev"
  name        = "meety-s3-access-rw-dev"
  path        = "/"
  policy = jsonencode({
    Statement = [{
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Effect   = "Allow"
      Resource = "arn:aws:s3:::dev-meety-file-bucket-${local.account_id}-us-east-2-an/*"
      Sid      = "ObjectAccess"
      }, {
      Action   = "s3:ListBucket"
      Effect   = "Allow"
      Resource = "arn:aws:s3:::dev-meety-file-bucket-${local.account_id}-us-east-2-an"
      Sid      = "ListForNotFound"
    }]
    Version = "2012-10-17"
  })
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_iam_role_policy_attachment" "ec2_prod_ssm_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = "meety-ec2-prod"
}

resource "aws_s3_bucket_ownership_controls" "prod" {
  bucket = "meety-file-bucket-${local.account_id}-us-east-2-an"
  region = "us-east-2"
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "dev" {
  bucket = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
  policy = jsonencode({
    Statement = [{
      Action = "s3:*"
      Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
      Effect    = "Deny"
      Principal = "*"
      Resource  = ["arn:aws:s3:::dev-meety-file-bucket-${local.account_id}-us-east-2-an", "arn:aws:s3:::dev-meety-file-bucket-${local.account_id}-us-east-2-an/*"]
      Sid       = "DenyInsecureTransport"
    }]
    Version = "2012-10-17"
  })
  region = "us-east-2"
}

resource "aws_instance" "dev_data" {
  ami                                  = "ami-0e5497a77ef21b5ac"
  associate_public_ip_address          = true
  availability_zone                    = "us-east-2a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  iam_instance_profile                 = "meety-ec2-cloudwatch-role"
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.micro"
  ipv6_address_count                   = 0
  key_name                             = "meety-v1"
  monitoring                           = false
  placement_partition_number           = 0
  private_ip                           = "10.0.1.147"
  region                               = "us-east-2"
  secondary_private_ips                = []
  security_groups                      = []
  source_dest_check                    = true
  subnet_id                            = "subnet-0eb391e5688b1e282"
  tags = {
    Name    = "dev-data-v1"
    Service = "meety-staging"
  }
  tags_all = {
    Name    = "dev-data-v1"
    Service = "meety-staging"
  }
  tenancy                = "default"
  vpc_security_group_ids = ["sg-016d5ef2c40006305", "sg-0769decbce98ab96b"]
  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }
  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }
  credit_specification {
    cpu_credits = "unlimited"
  }
  enclave_options {
    enabled = false
  }
  maintenance_options {
    auto_recovery = "default"
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }
  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    tags_all              = {}
    throughput            = 125
    volume_size           = 30
    volume_type           = "gp3"
  }
}

resource "aws_vpc_security_group_ingress_rule" "data_mysql_from_app" {
  from_port                    = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = "sg-09ac11928cda5a281"
  region                       = "us-east-2"
  security_group_id            = "sg-016d5ef2c40006305"
  to_port                      = 3306
}

resource "aws_vpc_security_group_egress_rule" "ssh_all" {
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  region            = "us-east-2"
  security_group_id = "sg-0769decbce98ab96b"
}

resource "aws_s3_bucket" "prod" {
  bucket              = "meety-file-bucket-${local.account_id}-us-east-2-an"
  bucket_namespace    = "account-regional"
  force_destroy       = false
  object_lock_enabled = false
  region              = "us-east-2"
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_iam_role" "ec2_cloudwatch" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "Allows EC2 instances to call AWS services on your behalf."
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "meety-ec2-cloudwatch-role"
  path                  = "/"
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_iam_role" "ec2_prod" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
  description           = "Allows EC2 instances to call AWS services on your behalf.\nmeety-ec2-prod"
  force_detach_policies = false
  max_session_duration  = 3600
  name                  = "meety-ec2-prod"
  path                  = "/"
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}

resource "aws_instance" "dev_app" {
  ami                                  = "ami-0e5497a77ef21b5ac"
  associate_public_ip_address          = true
  availability_zone                    = "us-east-2a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  iam_instance_profile                 = "meety-ec2-v1-dev"
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.small"
  ipv6_address_count                   = 0
  key_name                             = "meety-v1"
  monitoring                           = false
  placement_partition_number           = 0
  private_ip                           = "10.0.1.97"
  region                               = "us-east-2"
  secondary_private_ips                = []
  security_groups                      = []
  source_dest_check                    = true
  subnet_id                            = "subnet-0eb391e5688b1e282"
  tags = {
    Name    = "dev-app-v1"
    Service = "meety-staging"
  }
  tags_all = {
    Name    = "dev-app-v1"
    Service = "meety-staging"
  }
  tenancy                = "default"
  vpc_security_group_ids = ["sg-0769decbce98ab96b", "sg-09ac11928cda5a281"]
  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }
  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }
  credit_specification {
    cpu_credits = "unlimited"
  }
  enclave_options {
    enabled = false
  }
  maintenance_options {
    auto_recovery = "default"
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }
  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    tags_all              = {}
    throughput            = 125
    volume_size           = 30
    volume_type           = "gp3"
  }
}

resource "aws_cloudwatch_dashboard" "meety_v1" {
  dashboard_body = jsonencode({
    widgets = [{
      height = 6
      properties = {
        metrics = [[{
          expression = "SELECT SUM(VolumeWriteBytes)\nFROM SCHEMA(\"AWS/EBS\", VolumeId)\nGROUP BY VolumeId\nORDER BY SUM() DESC\nLIMIT 10"
          id         = "q1"
          label      = "$${LABEL} [sum: $${SUM}]"
        }]]
        period  = 300
        region  = "us-east-2"
        stacked = false
        stat    = "Average"
        title   = "기록된 바이트별 상위 10개 EBS 볼륨"
        view    = "timeSeries"
        yAxis = {
          left = {
            label     = "Bytes"
            showUnits = false
          }
        }
      }
      type  = "metric"
      width = 6
      x     = 0
      y     = 0
      }, {
      height = 6
      properties = {
        metrics = [[{
          expression = "SELECT AVG(CPUUtilization)\nFROM SCHEMA(\"AWS/EC2\", InstanceId)\nGROUP BY InstanceId\nORDER BY AVG() DESC"
          id         = "q1"
          label      = "$${LABEL} [avg: $${AVG}%]"
        }]]
        period  = 300
        region  = "us-east-2"
        stacked = false
        stat    = "Average"
        title   = "EC2 인스턴스의 CPU 사용률을 높은순으로 정렬"
        view    = "timeSeries"
        yAxis = {
          left = {
            label     = "Percent"
            showUnits = false
          }
        }
      }
      type  = "metric"
      width = 6
      x     = 6
      y     = 0
      }, {
      height = 6
      properties = {
        metrics = [[{
          expression = "SELECT SUM(IncomingLogEvents)\nFROM SCHEMA(\"AWS/Logs\", LogGroupName) \nGROUP BY LogGroupName\nORDER BY SUM() DESC\nLIMIT 10"
          id         = "q1"
          label      = "$${LABEL} [sum: $${SUM}]"
        }]]
        period  = 300
        region  = "us-east-2"
        stacked = false
        stat    = "Average"
        title   = "수신 이벤트별 상위 10개 로그 그룹"
        view    = "timeSeries"
        yAxis = {
          left = {
            label     = "Count"
            showUnits = false
          }
        }
      }
      type  = "metric"
      width = 6
      x     = 12
      y     = 0
    }]
  })
  dashboard_name = "meety-v1"
  region         = "us-east-2"
}

resource "aws_instance" "prod_app" {
  ami                                  = "ami-0e5497a77ef21b5ac"
  associate_public_ip_address          = true
  availability_zone                    = "us-east-2a"
  disable_api_stop                     = false
  disable_api_termination              = false
  ebs_optimized                        = true
  force_destroy                        = false
  get_password_data                    = false
  hibernation                          = false
  iam_instance_profile                 = "meety-ec2-prod"
  instance_initiated_shutdown_behavior = "stop"
  instance_type                        = "t3.small"
  ipv6_address_count                   = 0
  key_name                             = "meety-v1"
  monitoring                           = false
  placement_partition_number           = 0
  private_ip                           = "10.0.1.175"
  region                               = "us-east-2"
  secondary_private_ips                = []
  security_groups                      = []
  source_dest_check                    = true
  subnet_id                            = "subnet-0eb391e5688b1e282"
  tags = {
    Name    = "app-v1-meety"
    Service = "meety"
  }
  tags_all = {
    Name    = "app-v1-meety"
    Service = "meety"
  }
  tenancy                = "default"
  vpc_security_group_ids = ["sg-0769decbce98ab96b", "sg-09ac11928cda5a281"]
  capacity_reservation_specification {
    capacity_reservation_preference = "open"
  }
  cpu_options {
    core_count       = 1
    threads_per_core = 2
  }
  credit_specification {
    cpu_credits = "unlimited"
  }
  enclave_options {
    enabled = false
  }
  maintenance_options {
    auto_recovery = "default"
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_protocol_ipv6          = "disabled"
    http_put_response_hop_limit = 2
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }
  private_dns_name_options {
    enable_resource_name_dns_a_record    = false
    enable_resource_name_dns_aaaa_record = false
    hostname_type                        = "ip-name"
  }
  root_block_device {
    delete_on_termination = true
    encrypted             = false
    iops                  = 3000
    tags                  = {}
    tags_all              = {}
    throughput            = 125
    volume_size           = 30
    volume_type           = "gp3"
  }
}

resource "aws_s3_bucket" "dev" {
  bucket              = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
  bucket_namespace    = "account-regional"
  force_destroy       = false
  object_lock_enabled = false
  region              = "us-east-2"
  tags = {
    Service = "meety"
  }
  tags_all = {
    Service = "meety"
  }
}
