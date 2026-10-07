# 1단계(2026-10-07) V1 기존 리소스 import 기록. 이미 state에 등록되어 plan에서는 무시된다.

# ---------- network ----------
import {
  to = aws_vpc.main
  id = "vpc-0cd787f082879815e"
}

import {
  to = aws_subnet.public_a
  id = "subnet-0eb391e5688b1e282"
}

import {
  to = aws_internet_gateway.main
  id = "igw-01d5e5e30cfac97f2"
}

import {
  to = aws_route_table.public
  id = "rtb-006dcab3f189780a2"
}

import {
  to = aws_route_table_association.public_a
  id = "subnet-0eb391e5688b1e282/rtb-006dcab3f189780a2"
}

# ---------- security groups ----------
import {
  to = aws_security_group.app
  id = "sg-09ac11928cda5a281"
}

import {
  to = aws_security_group.ai
  id = "sg-0cb07d86ec124f4bc"
}

import {
  to = aws_security_group.data
  id = "sg-016d5ef2c40006305"
}

import {
  to = aws_security_group.ssh
  id = "sg-0769decbce98ab96b"
}

import {
  to = aws_vpc_security_group_ingress_rule.app_http
  id = "sgr-00516715c7ae4f795"
}

import {
  to = aws_vpc_security_group_ingress_rule.app_https
  id = "sgr-0320d6e23a9b5f0d0"
}

import {
  to = aws_vpc_security_group_ingress_rule.ai_8000_from_app
  id = "sgr-04cb7ee3dd1ec674b"
}

import {
  to = aws_vpc_security_group_ingress_rule.ai_8001_from_app
  id = "sgr-0bc0b2fd37e6de7a1"
}

import {
  to = aws_vpc_security_group_ingress_rule.data_mysql_from_app
  id = "sgr-03f001f3d60223d46"
}

import {
  to = aws_vpc_security_group_ingress_rule.data_redis_from_app
  id = "sgr-05e7a404cea3a5791"
}

import {
  to = aws_vpc_security_group_ingress_rule.ssh
  id = "sgr-02d189e1880b378c9"
}

import {
  to = aws_vpc_security_group_egress_rule.app_all
  id = "sgr-09b6827b175a8473b"
}

import {
  to = aws_vpc_security_group_egress_rule.ai_all
  id = "sgr-00a2249b81dc60783"
}

import {
  to = aws_vpc_security_group_egress_rule.data_all
  id = "sgr-0cf4c9ca8de5a1690"
}

import {
  to = aws_vpc_security_group_egress_rule.ssh_all
  id = "sgr-02da7072108d73241"
}

# ---------- ec2 ----------
import {
  to = aws_instance.prod_app
  id = "i-0daa54e17d85e1f8e"
}

import {
  to = aws_instance.prod_ai
  id = "i-0a4dae43d15c30b60"
}

import {
  to = aws_instance.prod_data
  id = "i-0ebad3417d7a43bda"
}

import {
  to = aws_instance.dev_app
  id = "i-076b39ef84ef3ddf9"
}

import {
  to = aws_instance.dev_ai
  id = "i-0007c84fb4f41d24c"
}

import {
  to = aws_instance.dev_data
  id = "i-00b1191f61901d977"
}

# ---------- s3 ----------
import {
  to = aws_s3_bucket.prod
  id = "meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_public_access_block.prod
  id = "meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.prod
  id = "meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_cors_configuration.prod
  id = "meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_policy.prod
  id = "meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_ownership_controls.prod
  id = "meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket.dev
  id = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_public_access_block.dev
  id = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.dev
  id = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_cors_configuration.dev
  id = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_policy.dev
  id = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
}

import {
  to = aws_s3_bucket_ownership_controls.dev
  id = "dev-meety-file-bucket-${local.account_id}-us-east-2-an"
}

# ---------- iam ----------
import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

import {
  to = aws_iam_role.github_actions_ssm
  id = "SSM"
}

import {
  to = aws_iam_role_policy.github_actions_ssm
  id = "SSM:SSMPolicy"
}

import {
  to = aws_iam_role.ec2_prod
  id = "meety-ec2-prod"
}

import {
  to = aws_iam_role.ec2_dev
  id = "meety-ec2-v1-dev"
}

import {
  to = aws_iam_role.ec2_cloudwatch
  id = "meety-ec2-cloudwatch-role"
}

import {
  to = aws_iam_instance_profile.ec2_prod
  id = "meety-ec2-prod"
}

import {
  to = aws_iam_instance_profile.ec2_dev
  id = "meety-ec2-v1-dev"
}

import {
  to = aws_iam_instance_profile.ec2_cloudwatch
  id = "meety-ec2-cloudwatch-role"
}

import {
  to = aws_iam_policy.github_actions_ssm_deploy
  id = "arn:aws:iam::${local.account_id}:policy/meety-GitHubActions-SSM-Deploy"
}

import {
  to = aws_iam_policy.s3_rw_prod
  id = "arn:aws:iam::${local.account_id}:policy/meety-s3-access-rw-prod"
}

import {
  to = aws_iam_policy.s3_rw_dev
  id = "arn:aws:iam::${local.account_id}:policy/meety-s3-access-rw-dev"
}

import {
  to = aws_iam_policy.params_editor
  id = "arn:aws:iam::${local.account_id}:policy/meety-params-editor"
}

import {
  to = aws_iam_policy.params_read_server
  id = "arn:aws:iam::${local.account_id}:policy/meety-params-read-server"
}

import {
  to = aws_iam_role_policy_attachment.ec2_prod_ssm_deploy
  id = "meety-ec2-prod/arn:aws:iam::${local.account_id}:policy/meety-GitHubActions-SSM-Deploy"
}

import {
  to = aws_iam_role_policy_attachment.ec2_prod_s3_rw
  id = "meety-ec2-prod/arn:aws:iam::${local.account_id}:policy/meety-s3-access-rw-prod"
}

import {
  to = aws_iam_role_policy_attachment.ec2_prod_params_editor
  id = "meety-ec2-prod/arn:aws:iam::${local.account_id}:policy/meety-params-editor"
}

import {
  to = aws_iam_role_policy_attachment.ec2_prod_cw_agent
  id = "meety-ec2-prod/arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

import {
  to = aws_iam_role_policy_attachment.ec2_prod_ssm_core
  id = "meety-ec2-prod/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_role_policy_attachment.ec2_dev_ssm_deploy
  id = "meety-ec2-v1-dev/arn:aws:iam::${local.account_id}:policy/meety-GitHubActions-SSM-Deploy"
}

import {
  to = aws_iam_role_policy_attachment.ec2_dev_s3_rw
  id = "meety-ec2-v1-dev/arn:aws:iam::${local.account_id}:policy/meety-s3-access-rw-dev"
}

import {
  to = aws_iam_role_policy_attachment.ec2_dev_params_read
  id = "meety-ec2-v1-dev/arn:aws:iam::${local.account_id}:policy/meety-params-read-server"
}

import {
  to = aws_iam_role_policy_attachment.ec2_dev_cw_agent
  id = "meety-ec2-v1-dev/arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

import {
  to = aws_iam_role_policy_attachment.ec2_dev_ssm_core
  id = "meety-ec2-v1-dev/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

import {
  to = aws_iam_role_policy_attachment.ec2_cloudwatch_ssm_deploy
  id = "meety-ec2-cloudwatch-role/arn:aws:iam::${local.account_id}:policy/meety-GitHubActions-SSM-Deploy"
}

import {
  to = aws_iam_role_policy_attachment.ec2_cloudwatch_params_read
  id = "meety-ec2-cloudwatch-role/arn:aws:iam::${local.account_id}:policy/meety-params-read-server"
}

import {
  to = aws_iam_role_policy_attachment.ec2_cloudwatch_cw_agent
  id = "meety-ec2-cloudwatch-role/arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

import {
  to = aws_iam_role_policy_attachment.ec2_cloudwatch_ssm_core
  id = "meety-ec2-cloudwatch-role/arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---------- cloudwatch ----------
import {
  to = aws_cloudwatch_log_group.dev_ai_docker
  id = "/dev-meety/ai/docker"
}

import {
  to = aws_cloudwatch_log_group.dev_app_docker
  id = "/dev-meety/app/docker"
}

import {
  to = aws_cloudwatch_log_group.dev_app_nginx_access
  id = "/dev-meety/app/nginx-access"
}

import {
  to = aws_cloudwatch_log_group.dev_app_nginx_error
  id = "/dev-meety/app/nginx-error"
}

import {
  to = aws_cloudwatch_log_group.prod_app_docker
  id = "/meety/app/docker"
}

import {
  to = aws_cloudwatch_log_group.prod_app_nginx_access
  id = "/meety/app/nginx-access"
}

import {
  to = aws_cloudwatch_log_group.prod_app_nginx_error
  id = "/meety/app/nginx-error"
}

import {
  to = aws_cloudwatch_log_group.prod_ai_docker
  id = "/meety/ec2-ai/docker"
}

import {
  to = aws_cloudwatch_dashboard.meety_v1
  id = "meety-v1"
}

