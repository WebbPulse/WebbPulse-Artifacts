# HCP Terraform injects AWS credentials through dynamic provider credentials:
# the workspace federates into the run role WebbPulse-Platform vends for it in
# the WebbPulse Artifacts account. No static keys exist here or anywhere else.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }

  ignore_tags {
    keys = ["awsApplication"]
  }
}
