output "buckets" {
  description = "Bucket de cada camada."
  value       = { for k, b in aws_s3_bucket.camada : k => b.bucket }
}

output "bucket_arns" {
  value = { for k, b in aws_s3_bucket.camada : k => b.arn }
}

output "s3_paths" {
  value = local.s3_paths
}

output "athena_results_bucket" {
  value = aws_s3_bucket.athena_results.bucket
}

output "artefatos_bucket" {
  value = aws_s3_bucket.artefatos.bucket
}

output "athena_workgroup" {
  value = aws_athena_workgroup.main.name
}

output "athena_workgroup_arn" {
  value = aws_athena_workgroup.main.arn
}

output "databases" {
  value = { for k, d in aws_glue_catalog_database.camada : k => d.name }
}

output "tabelas" {
  description = "Tabela de cada camada (database => tabela)."
  value = {
    raw     = aws_glue_catalog_table.raw.name
    trusted = aws_glue_catalog_table.trusted.name
    refined = aws_glue_catalog_table.refined.name
  }
}
