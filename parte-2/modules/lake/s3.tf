locals {
  camadas = ["raw", "trusted", "refined"]

  bucket_names = { for c in local.camadas : c => "${var.project_prefix}lake-${c}${var.name_suffix}" }

  # raw guarda o que chegou (auditoria) => versionado.
  # trusted/refined são 100% reconstruíveis a partir do raw pelo job idempotente
  # => sem versionamento (overwrite de partição não acumula versões mortas).
  versionado = { raw = true, trusted = false, refined = false }
}

# -----------------------------------------------------------------------------
# Camadas do lake: eda262-g08-lake-{raw,trusted,refined}
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "camada" {
  for_each      = local.bucket_names
  bucket        = each.value
  force_destroy = true
  tags          = { camada = each.key }
}

resource "aws_s3_bucket_public_access_block" "camada" {
  for_each                = aws_s3_bucket.camada
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "camada" {
  for_each = aws_s3_bucket.camada
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "camada" {
  for_each = aws_s3_bucket.camada
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.camada["raw"].id
  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# Resultados do Athena (efêmeros, 7 dias)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "athena_results" {
  bucket        = "${var.project_prefix}athena-results${var.name_suffix}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    id     = "expira-resultados"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = 7
    }
  }
}

# -----------------------------------------------------------------------------
# Artefatos do pipeline: script do Glue, TempDir e relatórios de execução
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artefatos" {
  bucket        = "${var.project_prefix}artefatos${var.name_suffix}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artefatos" {
  bucket                  = aws_s3_bucket.artefatos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artefatos" {
  bucket = aws_s3_bucket.artefatos.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
