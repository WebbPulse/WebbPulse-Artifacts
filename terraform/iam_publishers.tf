# The roles the two package repositories assume to publish, trusted through GitHub's OIDC provider
# so no long-lived AWS keys live in GitHub.
#
# The Platform vend created only the HCP Terraform OIDC provider in this account
# (https://app.terraform.io, for the run role's dynamic credentials). The GitHub provider
# (https://token.actions.githubusercontent.com) is a different provider for a different issuer, and
# an account holds at most one per URL, so this root owns it: the Python role creates it and the npm
# role trusts the same one by ARN.
#
# Trust is scoped to the repository AND the publish environment, not to the repository alone. The
# subject GitHub puts in the token for an environment-bound job is
# repo:WebbPulse/<repo>:environment:publish, so a workflow on a branch that is not bound to that
# environment cannot assume the role however the repository's other workflows are written. That is
# what makes the GitHub environment's protection rules a real gate on publishing rather than a
# convention.

module "python_publisher_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name        = "${local.prefix}-python-publisher"
  role_description = "Publishes the webbpulse Python package to the CodeArtifact python repository from WebbPulse/webbpulse-python."

  # This root owns the account's GitHub OIDC provider.
  create_oidc_provider = true

  subjects = ["repo:WebbPulse/webbpulse-python:environment:publish"]

  policy_statements = local.python_publisher_policy_statements
}

module "npm_publisher_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name        = "${local.prefix}-npm-publisher"
  role_description = "Publishes the @webbpulse npm packages to the CodeArtifact npm repository from WebbPulse/webbpulse-typescript."

  # The provider already exists by the time this role is created; an account holds at most one per
  # URL, so this call trusts the one above rather than creating a second.
  create_oidc_provider = false
  oidc_provider_arn    = module.python_publisher_role.oidc_provider_arn

  subjects = ["repo:WebbPulse/webbpulse-typescript:environment:publish"]

  policy_statements = local.npm_publisher_policy_statements
}
