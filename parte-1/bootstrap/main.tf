terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State local apenas para o bootstrap (evita chicken-and-egg com o backend S3).
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      turma   = "eda262"
      grupo   = "g08"
      projeto = "engenharia-de-dados"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

locals {
  tfstate_bucket = "eda262-g08-tfstate"
  lock_table     = "eda262-g08-tfstate-lock"
}

resource "aws_s3_bucket" "tfstate" {
  bucket        = local.tfstate_bucket
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "tfstate_lock_table" {
  value = aws_dynamodb_table.tfstate_lock.name
}

output "backend_init_hint" {
  value = <<-EOT
    terraform init \
      -backend-config="bucket=${aws_s3_bucket.tfstate.bucket}" \
      -backend-config="key=parte-1/terraform.tfstate" \
      -backend-config="region=${var.aws_region}" \
      -backend-config="dynamodb_table=${aws_dynamodb_table.tfstate_lock.name}" \
      -backend-config="encrypt=true"
  EOT
}
