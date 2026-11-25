variable "project_prefix" { type = string }
variable "name_suffix" { type = string }
variable "artefatos_bucket" { type = string }
variable "raw_bucket" { type = string }
variable "trusted_bucket" { type = string }
variable "refined_bucket" { type = string }
variable "raw_path" { type = string }
variable "trusted_path" { type = string }
variable "refined_path" { type = string }
variable "script_file" { type = string }

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  job_name  = "${var.project_prefix}etl-vendas${var.name_suffix}"
  role_name = "${var.project_prefix}glue-etl${var.name_suffix}"
  log_group = "/${trimsuffix(var.project_prefix, "-")}/glue/etl-vendas${var.name_suffix}"
  s3        = "arn:${data.aws_partition.current.partition}:s3:::"
}

# -----------------------------------------------------------------------------
# Script do job (versionado no repo, publicado pelo Terraform)
# -----------------------------------------------------------------------------
resource "aws_s3_object" "script" {
  bucket = var.artefatos_bucket
  key    = "scripts/etl_vendas.py"
  source = var.script_file
  etag   = filemd5(var.script_file)
}

# -----------------------------------------------------------------------------
# Logs do job num log group próprio (some no destroy; retenção curta)
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "glue" {
  name              = local.log_group
  retention_in_days = 7
}

# -----------------------------------------------------------------------------
# Role do job — menor privilégio POR CAMADA:
#   raw      : só leitura (o pipeline nunca altera o que chegou)
#   trusted  : leitura + escrita + delete (overwrite de partição)
#   refined  : leitura + escrita + delete
# -----------------------------------------------------------------------------
resource "aws_iam_role" "glue" {
  name = local.role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "glue" {
  name = "etl-vendas-camadas"
  role = aws_iam_role.glue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListarCamadas"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [for b in [var.raw_bucket, var.trusted_bucket, var.refined_bucket, var.artefatos_bucket] : "${local.s3}${b}"]
      },
      {
        Sid      = "RawSomenteLeitura"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${local.s3}${var.raw_bucket}/*"]
      },
      {
        Sid      = "TrustedRefinedEscrita"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.s3}${var.trusted_bucket}/*", "${local.s3}${var.refined_bucket}/*"]
      },
      {
        Sid      = "Artefatos"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${local.s3}${var.artefatos_bucket}/*"]
      },
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = [
          aws_cloudwatch_log_group.glue.arn,
          "${aws_cloudwatch_log_group.glue.arn}:*",
        ]
      },
      {
        Sid       = "Metricas"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "Glue" } }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Job Glue (Spark) — idempotente; backfill via --PARTICOES
# -----------------------------------------------------------------------------
resource "aws_glue_job" "etl" {
  name              = local.job_name
  description       = "raw -> trusted -> refined (varejo-ecommerce). Idempotente: overwrite dinâmico de partição + dedup por id_venda."
  role_arn          = aws_iam_role.glue.arn
  glue_version      = "5.0"
  worker_type       = "G.1X"
  number_of_workers = 2
  timeout           = 15
  max_retries       = 0

  # Uma execução por vez: duas execuções simultâneas poderiam sobrescrever a
  # mesma partição em ordem imprevisível.
  execution_property {
    max_concurrent_runs = 1
  }

  command {
    name            = "glueetl"
    script_location = "s3://${var.artefatos_bucket}/${aws_s3_object.script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--RAW_PATH"                         = var.raw_path
    "--TRUSTED_PATH"                     = var.trusted_path
    "--REFINED_PATH"                     = var.refined_path
    "--RELATORIO_PATH"                   = "s3://${var.artefatos_bucket}/execucoes/"
    "--PARTICOES"                        = "todas"
    "--TempDir"                          = "s3://${var.artefatos_bucket}/tmp/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--continuous-log-logGroup"          = aws_cloudwatch_log_group.glue.name
    "--enable-metrics"                   = "false"
    "--enable-spark-ui"                  = "false"
    "--enable-job-insights"              = "false"
  }

  depends_on = [aws_iam_role_policy.glue]
}

output "job_name" {
  value = aws_glue_job.etl.name
}

output "role_arn" {
  value = aws_iam_role.glue.arn
}

output "log_group" {
  value = aws_cloudwatch_log_group.glue.name
}
