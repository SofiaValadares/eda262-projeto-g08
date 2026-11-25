terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # As 3 tags obrigatórias chegam em todo recurso que aceita tag.
  default_tags {
    tags = var.mandatory_tags
  }
}
