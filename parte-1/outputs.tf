output "lake_trusted_bucket" {
  description = "Nome do bucket S3 da camada trusted."
  value       = aws_s3_bucket.lake_trusted.bucket
}

output "athena_results_bucket" {
  description = "Nome do bucket S3 de resultados do Athena."
  value       = aws_s3_bucket.athena_results.bucket
}

output "athena_workgroup" {
  description = "Nome do workgroup Athena."
  value       = aws_athena_workgroup.main.name
}

output "glue_database" {
  description = "Nome do database no Glue Data Catalog."
  value       = aws_glue_catalog_database.catalog.name
}

output "glue_table" {
  description = "Nome da tabela trusted no Glue."
  value       = aws_glue_catalog_table.venda_varejo_trusted.name
}

output "trusted_data_s3_uri" {
  description = "URI S3 do dataset trusted."
  value       = "s3://${aws_s3_bucket.lake_trusted.bucket}/${var.trusted_data_key}"
}

output "athena_query_example" {
  description = "Comando AWS CLI de exemplo para executar a consulta analítica."
  value       = <<-EOT
    aws athena start-query-execution \
      --work-group ${aws_athena_workgroup.main.name} \
      --query-execution-context Database=${aws_glue_catalog_database.catalog.name} \
      --query-string file://../queries/consulta_analitica.sql
  EOT
}

output "mandatory_tags" {
  description = "Tags obrigatórias aplicadas via default_tags do provider."
  value       = var.mandatory_tags
}
