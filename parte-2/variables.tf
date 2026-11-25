variable "aws_region" {
  description = "Região AWS dos recursos."
  type        = string
  default     = "us-east-1"
}

variable "project_prefix" {
  description = "Prefixo obrigatório dos recursos AWS do grupo."
  type        = string
  default     = "eda262-g08-"
}

variable "scenario_slug" {
  description = "Slug do cenário de negócio (prefixo S3 dentro de cada camada)."
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

variable "particao_inicio" {
  description = "Primeiro ano_mes da projeção de partição (yyyy-MM)."
  type        = string
  default     = "2024-01"
}

variable "athena_bytes_cutoff" {
  description = "Guarda de custo do workgroup: consulta que passar disso é cancelada (bytes)."
  type        = number
  default     = 1073741824 # 1 GiB
}
