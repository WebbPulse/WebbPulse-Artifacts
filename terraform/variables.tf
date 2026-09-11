variable "aws_region" {
  description = "Region every resource in this root is created in."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be an AWS region name such as us-west-2."
  }
}

variable "environment" {
  description = "Which environment this workspace deploys. There is exactly one, and it is shared."
  type        = string
  default     = "shared"

  validation {
    condition     = var.environment == "shared"
    error_message = "environment must be \"shared\". The artifacts account holds one registry estate consumed by production and staging alike, so there is no second environment to name."
  }
}
