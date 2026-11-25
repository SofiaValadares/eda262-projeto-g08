# -----------------------------------------------------------------------------
# Governança por camada com AWS Lake Formation
#
#   persona       raw      trusted   refined
#   engenheiro    SELECT   SELECT    SELECT
#   analista      —        —         SELECT
#
# As duas personas recebem EXATAMENTE a mesma política IAM (Athena + leitura do
# catálogo + lakeformation:GetDataAccess) e NENHUMA permissão S3 nos buckets do
# lake. Quem decide qual camada cada uma lê é só o Lake Formation: as 3
# localizações S3 são registradas e o LF entrega credencial temporária ao Athena
# apenas para as tabelas com GRANT.
#
# NÃO gerenciamos aws_lakeformation_data_lake_settings: é configuração da conta
# inteira (admins, defaults) e o destroy dela apagaria a configuração de terceiros.
# -----------------------------------------------------------------------------

variable "project_prefix" { type = string }
variable "name_suffix" { type = string }
variable "buckets" { type = map(string) }
variable "athena_results_bucket" { type = string }
variable "athena_workgroup_arn" { type = string }
variable "databases" { type = map(string) }
variable "tabelas" { type = map(string) }

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  account = data.aws_caller_identity.current.account_id
  region  = data.aws_region.current.name
  part    = data.aws_partition.current.partition
  s3      = "arn:${local.part}:s3:::"

  acesso = {
    engenheiro = ["raw", "trusted", "refined"]
    analista   = ["refined"]
  }
  grants = merge([
    for persona, camadas in local.acesso : {
      for c in camadas : "${persona}-${c}" => { persona = persona, camada = c }
    }
  ]...)
}

# -----------------------------------------------------------------------------
# Personas (roles assumíveis por principals da própria conta)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "persona" {
  for_each = local.acesso
  name     = "${var.project_prefix}${each.key}${var.name_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${local.part}:iam::${local.account}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { persona = each.key }
}

resource "aws_iam_role_policy" "persona" {
  for_each = aws_iam_role.persona
  name     = "consulta-athena-via-lake-formation"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Athena"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution", "athena:GetQueryResults",
          "athena:StopQueryExecution", "athena:GetWorkGroup",
        ]
        Resource = var.athena_workgroup_arn
      },
      {
        # Igual para as duas personas e para as 3 camadas: o IAM não diferencia
        # camada; quem diferencia é o Lake Formation.
        Sid    = "CatalogoLeitura"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables",
          "glue:GetPartition", "glue:GetPartitions", "glue:BatchGetPartition",
        ]
        Resource = concat(
          ["arn:${local.part}:glue:${local.region}:${local.account}:catalog"],
          [for db in values(var.databases) : "arn:${local.part}:glue:${local.region}:${local.account}:database/${db}"],
          [for db in values(var.databases) : "arn:${local.part}:glue:${local.region}:${local.account}:table/${db}/*"],
        )
      },
      {
        Sid      = "CredencialViaLakeFormation"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Sid    = "ResultadosAthena"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation",
          "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
        ]
        Resource = ["${local.s3}${var.athena_results_bucket}", "${local.s3}${var.athena_results_bucket}/*"]
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# Role que o Lake Formation assume para ler as camadas registradas
# (role própria em vez do service-linked role, que ficaria órfão no destroy)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "lf_registro" {
  name = "${var.project_prefix}lf-registro${var.name_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lakeformation.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:SetContext", "sts:SetSourceIdentity"]
    }]
  })
}

resource "aws_iam_role_policy" "lf_registro" {
  name = "acesso-camadas"
  role = aws_iam_role.lf_registro.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [for b in values(var.buckets) : "${local.s3}${b}"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for b in values(var.buckets) : "${local.s3}${b}/*"]
      },
    ]
  })
}

# As tabelas são criadas ANTES do registro das localizações (quem roda o
# Terraform não precisa de DATA_LOCATION_ACCESS para criá-las).
resource "terraform_data" "tabelas_criadas" {
  input = var.tabelas
}

# -----------------------------------------------------------------------------
# Tira IAM_ALLOWED_PRINCIPALS das 3 tabelas.
#
# Por padrão a conta concede IAM_ALLOWED_PRINCIPALS:ALL a toda tabela nova
# (modo de compatibilidade "só IAM"). Enquanto esse grant existir, o Lake
# Formation não decide nada. A Glue só aceita IAM_ALLOWED_PRINCIPALS no campo
# CreateTableDefaultPermissions do database e o provider não envia lista vazia,
# então revogamos logo após criar as tabelas. Mexe só nas NOSSAS tabelas, nunca
# na configuração da conta.
#
# Chama o aws CLI direto (interpreter = argv, sem shell): funciona igual em
# Linux, macOS e Windows. BatchRevoke é idempotente (grant inexistente => Failure
# no corpo da resposta, exit 0). Recriar uma tabela dispara a revogação de novo.
# -----------------------------------------------------------------------------
resource "terraform_data" "revoga_iam_allowed_principals" {
  triggers_replace = [for c in sort(keys(var.tabelas)) : "${var.databases[c]}.${var.tabelas[c]}"]

  provisioner "local-exec" {
    interpreter = ["aws", "lakeformation", "batch-revoke-permissions", "--region", local.region, "--output", "json", "--cli-input-json"]
    command = jsonencode({
      Entries = [for c in sort(keys(var.tabelas)) : {
        Id          = c
        Principal   = { DataLakePrincipalIdentifier = "IAM_ALLOWED_PRINCIPALS" }
        Resource    = { Table = { DatabaseName = var.databases[c], Name = var.tabelas[c] } }
        Permissions = ["ALL"]
      }]
    })
  }

  depends_on = [terraform_data.tabelas_criadas]
}

resource "aws_lakeformation_resource" "camada" {
  for_each = var.buckets
  arn      = "${local.s3}${each.value}"
  role_arn = aws_iam_role.lf_registro.arn

  depends_on = [aws_iam_role_policy.lf_registro, terraform_data.tabelas_criadas]
}

# -----------------------------------------------------------------------------
# GRANTs por camada
# -----------------------------------------------------------------------------
# O controle é na TABELA. O database mantém o default da conta
# (IAM_ALLOWED_PRINCIPALS: ALL no nível de database = ver o database e criar
# tabela), que não dá leitura de dado nenhum: SELECT em tabela é outro grant.
resource "aws_lakeformation_permissions" "tabelas" {
  for_each    = local.grants
  principal   = aws_iam_role.persona[each.value.persona].arn
  permissions = ["SELECT", "DESCRIBE"]

  # GRANT por tabela nomeada (não wildcard): quem cria a tabela pode conceder
  # nela sem ser Data Lake Admin; o wildcard "todas as tabelas" exigiria admin.
  table {
    database_name = var.databases[each.value.camada]
    name          = var.tabelas[each.value.camada]
  }

  depends_on = [terraform_data.revoga_iam_allowed_principals]
}

output "engenheiro_role_arn" {
  value = aws_iam_role.persona["engenheiro"].arn
}

output "analista_role_arn" {
  value = aws_iam_role.persona["analista"].arn
}

output "lf_registro_role_arn" {
  value = aws_iam_role.lf_registro.arn
}
