output "lake_trusted_bucket" {
  description = "Nome do bucket S3 da camada trusted."
  value       = module.lake.lake_trusted_bucket
}

output "athena_results_bucket" {
  description = "Nome do bucket S3 de resultados do Athena."
  value       = module.lake.athena_results_bucket
}

output "athena_workgroup" {
  description = "Nome do workgroup Athena."
  value       = module.lake.athena_workgroup
}

output "glue_database" {
  description = "Nome do database no Glue Data Catalog."
  value       = module.lake.glue_database
}

output "glue_table" {
  description = "Nome da tabela trusted no Glue."
  value       = module.lake.glue_table
}

output "trusted_data_s3_uri" {
  description = "URI S3 do dataset trusted."
  value       = "s3://${module.lake.lake_trusted_bucket}/${var.trusted_data_key}"
}

output "athena_query_example" {
  description = "Comando AWS CLI de exemplo para executar a consulta analítica."
  value       = <<-EOT
    aws athena start-query-execution \
      --work-group ${module.lake.athena_workgroup} \
      --query-execution-context Database=${module.lake.glue_database} \
      --query-string file://../queries/consulta_analitica.sql
  EOT
}

output "mandatory_tags" {
  description = "Tags obrigatórias aplicadas via default_tags do provider."
  value       = var.mandatory_tags
}
