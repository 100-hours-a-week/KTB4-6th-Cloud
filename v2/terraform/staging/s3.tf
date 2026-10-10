# staging 파일 버킷: 녹음 파일을 저장한다.
# 브라우저가 BE가 발급한 presigned URL로 직접 올리고 받으므로 CORS에 FE 주소가 있어야 한다.

resource "aws_s3_bucket" "files" {
  bucket = "${local.name_prefix}-files"

  tags = {
    Name = "${local.name_prefix}-files"
  }
}

# 버킷과 객체를 공개할 수 없게 막는다. 접근은 IAM 권한과 presigned URL로만 한다
resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACL을 쓰지 않고 버킷 소유자가 모든 객체를 소유한다 (V1 버킷과 같은 설정)
resource "aws_s3_bucket_ownership_controls" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 저장 시 암호화 (V1 버킷과 같은 SSE-S3)
resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "DELETE", "HEAD"]
    allowed_origins = var.fe_allowed_origins
    expose_headers  = ["ETag"]
  }
}
