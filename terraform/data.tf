# Useful for constructing ARNs and avoiding hardcoded account IDs.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
