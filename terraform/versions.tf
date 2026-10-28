terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.0, < 7.0" }
    archive = { source = "hashicorp/archive", version = ">= 2.4" }
    random  = { source = "hashicorp/random", version = ">= 3.5" }
    null    = { source = "hashicorp/null", version = ">= 3.0" }
  }
}
provider "aws" { region = var.aws_region }
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
