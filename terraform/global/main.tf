################################################
# S3
################################################
resource "aws_s3_bucket" "state" {
  bucket        = "devops-demo-tf-remote-state-001"
  acl           = "private"
  force_destroy = false

  versioning {
    enabled = true
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  depends_on = [aws_s3_bucket.state]
  bucket     = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_force_ssl" {
  statement {
    sid     = "AllowSSLRequestsOnly"
    actions = ["s3:*"]
    effect  = "Deny"
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*"
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "state_force_ssl" {
  depends_on = [aws_s3_bucket.state, aws_s3_bucket_public_access_block.state]
  bucket     = aws_s3_bucket.state.id
  policy     = data.aws_iam_policy_document.state_force_ssl.json
}


################################################
# DynamoDB
################################################
resource "aws_dynamodb_table" "lock" {
  name         = "tf-remote-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
