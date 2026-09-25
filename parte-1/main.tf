locals {
  lake_trusted_bucket_name   = "${var.project_prefix}lake-trusted"
  athena_results_bucket_name = "${var.project_prefix}athena-results"
  athena_workgroup_name      = "${var.project_prefix}workgroup"
  glue_database_name         = "${var.project_prefix}catalog"
  trusted_s3_location        = "s3://${local.lake_trusted_bucket_name}/${var.scenario_slug}/"
}

# -----------------------------------------------------------------------------
# S3 — camada trusted (lake)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "lake_trusted" {
  bucket        = local.lake_trusted_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "lake_trusted" {
  bucket = aws_s3_bucket.lake_trusted.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake_trusted" {
  bucket = aws_s3_bucket.lake_trusted.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "lake_trusted" {
  bucket = aws_s3_bucket.lake_trusted.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "trusted_dataset" {
  bucket       = aws_s3_bucket.lake_trusted.id
  key          = var.trusted_data_key
  source       = "${path.module}/files/venda_varejo_trusted.csv"
  etag         = filemd5("${path.module}/files/venda_varejo_trusted.csv")
  content_type = "text/csv"
}

# -----------------------------------------------------------------------------
# S3 — resultados do Athena (necessário ao workgroup; destroy limpo)
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "athena_results" {
  bucket        = local.athena_results_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

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
    id     = "expire-athena-results"
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
# Athena Workgroup
# -----------------------------------------------------------------------------
resource "aws_athena_workgroup" "main" {
  name          = local.athena_workgroup_name
  description   = "Workgroup dedicado do grupo g08 — cenário ${var.scenario_slug}"
  state         = "ENABLED"
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Glue Data Catalog — database + tabela trusted com schema explícito (SEM crawler)
# Grão: 1 registro = 1 item vendido (linha de item da transação)
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "catalog" {
  name        = local.glue_database_name
  description = "Catálogo Glue do grupo g08 — camada trusted (${var.scenario_slug})"

  # Tags explícitas além do default_tags (evidência clara no Tag Editor / get-tags)
  tags = var.mandatory_tags
}

resource "aws_glue_catalog_table" "venda_varejo_trusted" {
  name          = var.trusted_table_name
  database_name = aws_glue_catalog_database.catalog.name
  description   = "Tabela trusted de vendas varejo/e-commerce. Grão: um registro por item vendido na transação."
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"         = "csv"
    "delimiter"              = ","
    "skip.header.line.count" = "1"
    "areColumnsQuoted"       = "false"
  }

  storage_descriptor {
    location      = local.trusted_s3_location
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      name                  = "venda_varejo_trusted_serde"
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"

      parameters = {
        "separatorChar"          = ","
        "quoteChar"              = "\""
        "escapeChar"             = "\\"
        "skip.header.line.count" = "1"
      }
    }

    # OpenCSVSerDe lê todas as colunas como string; tipagem semântica documentada
    # e aplicada na consulta analítica (CAST) — padrão confiável para CSV no Athena.
    columns {
      name    = "id_venda"
      type    = "string"
      comment = "Identificador da venda/item (semantic: bigint)"
    }

    columns {
      name    = "id_cliente"
      type    = "string"
      comment = "Identificador do cliente (semantic: bigint)"
    }

    columns {
      name    = "data_venda"
      type    = "string"
      comment = "Data da venda normalizada YYYY-MM-DD (semantic: date)"
    }

    columns {
      name    = "categoria_produto"
      type    = "string"
      comment = "Categoria do produto normalizada (Title Case)"
    }

    columns {
      name    = "quantidade"
      type    = "string"
      comment = "Quantidade de itens na linha (semantic: int)"
    }

    columns {
      name    = "preco_unitario"
      type    = "string"
      comment = "Preço unitário em BRL (semantic: decimal(10,2))"
    }
  }

  depends_on = [aws_s3_object.trusted_dataset]
}
