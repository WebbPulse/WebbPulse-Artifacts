terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.100, < 7.0"
    }
  }

  cloud {
    organization = "WebbPulse"

    workspaces {
      name = "WebbPulse-Artifacts"
    }
  }
}
