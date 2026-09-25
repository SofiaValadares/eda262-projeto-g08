variable "aws_region" {
  description = "Região AWS onde os recursos serão provisionados."
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefixo obrigatório dos recursos AWS do grupo."
  type        = string
  default     = "eda262-g08-"
}

variable "scenario_slug" {
  description = "Slug do cenário de negócio."
  type        = string
  default     = "varejo-ecommerce"
}

variable "mandatory_tags" {
  description = "Tags obrigatórias aplicadas a todos os recursos via default_tags."
  type        = map(string)
  default = {
    turma   = "eda262"
    grupo   = "g08"
    projeto = "engenharia-de-dados"
  }
}

variable "trusted_table_name" {
  description = "Nome da tabela trusted no Glue Data Catalog."
  type        = string
  default     = "venda_varejo_trusted"
}

variable "trusted_data_key" {
  description = "Chave S3 do arquivo CSV trusted."
  type        = string
  default     = "varejo-ecommerce/venda_varejo_trusted.csv"
}
