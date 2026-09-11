module "python_publisher_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name        = "${local.prefix}-python-publisher"
  role_description = "Publishes the webbpulse Python package to the CodeArtifact python repository from WebbPulse/webbpulse-python."

  create_oidc_provider = true

  subjects = ["repo:WebbPulse@185014056/webbpulse-python@1359998772:environment:publish"]

  policy_statements = local.python_publisher_policy_statements
}

module "npm_publisher_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name        = "${local.prefix}-npm-publisher"
  role_description = "Publishes the @webbpulse npm packages to the CodeArtifact npm repository from WebbPulse/webbpulse-typescript."

  create_oidc_provider = false
  oidc_provider_arn    = module.python_publisher_role.oidc_provider_arn

  subjects = ["repo:WebbPulse@185014056/webbpulse-typescript@1359998728:environment:publish"]

  policy_statements = local.npm_publisher_policy_statements
}

module "base_image_publisher_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name        = "${local.prefix}-base-image-publisher"
  role_description = "Pushes the shared webbpulse/python-lambda-base image to ECR from the main branch of WebbPulse/WebbPulse-Artifacts."

  create_oidc_provider = false
  oidc_provider_arn    = module.python_publisher_role.oidc_provider_arn

  subjects = ["repo:WebbPulse@185014056/WebbPulse-Artifacts@1359997352:ref:refs/heads/main"]

  policy_statements = local.base_image_publisher_policy_statements
}
