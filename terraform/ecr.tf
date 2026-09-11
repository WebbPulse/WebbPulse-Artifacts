module "ecr" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository"
  version = "~> 2.0"

  name_prefix = "webbpulse"

  repositories = {
    "python-lambda-base" = {}
  }

  image_tag_mutability = "IMMUTABLE"

  repository_policy_principals = [for id in local.consumer_account_ids : "arn:aws:iam::${id}:root"]

  keep_last_tagged_images    = 30
  expire_untagged_after_days = 7
  tag_prefix_list            = ["sha-", "py"]

  force_delete = false
}
