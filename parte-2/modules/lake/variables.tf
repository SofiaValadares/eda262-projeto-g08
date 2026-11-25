variable "project_prefix" {
  type = string
}

variable "name_suffix" {
  description = "Sufixo de workspace (vazio no workspace default)."
  type        = string
}

variable "scenario_slug" {
  type = string
}

variable "particao_inicio" {
  type = string
}

variable "athena_bytes_cutoff" {
  type = number
}
