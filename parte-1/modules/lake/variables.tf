variable "project_prefix" {
  description = "Prefixo obrigatório dos recursos AWS do grupo."
  type        = string
}

variable "scenario_slug" {
  description = "Slug do cenário de negócio."
  type        = string
}

variable "mandatory_tags" {
  description = "Tags obrigatórias (também aplicadas via default_tags do provider do root)."
  type        = map(string)
}

variable "trusted_table_name" {
  description = "Nome da tabela trusted no Glue Data Catalog."
  type        = string
}

variable "trusted_data_key" {
  description = "Chave S3 do arquivo CSV trusted."
  type        = string
}

variable "trusted_data_file" {
  description = "Caminho local do CSV trusted a ser enviado ao lake."
  type        = string
}
