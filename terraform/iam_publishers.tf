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

  # GitHub issues the rename-proof immutable subject (repo:ORG@ORG_ID/REPO@REPO_ID:...) for this
  # repository, so the trust policy must name that form. Read it back with
  # gh api repos/WebbPulse/webbpulse-python/actions/oidc/customization/sub (sub_claim_prefix).
  subjects = ["repo:WebbPulse@185014056/webbpulse-python@1359998772:environment:publish"]

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

  # Same immutable subject form as above; prefix from the repository's OIDC customization endpoint.
  subjects = ["repo:WebbPulse@185014056/webbpulse-typescript@1359998728:environment:publish"]

  policy_statements = local.npm_publisher_policy_statements
}

# The role the WebbPulse-Artifacts repository itself assumes to push the shared Python Lambda base
# image to ECR. It is a publisher like the two above, so it lives in this file, but what it
# publishes is an image rather than a package and the trust is scoped differently.
#
# No GitHub environment. The two package publishers gate on environment:publish because a package
# version can never be republished under the same version, so a release wants a protection rule in
# front of it. A base image push is a different shape: the tag is the commit sha, an immutable
# repository refuses to move it, and a bad image is superseded by the next commit rather than
# burning a version number. Trust is scoped to pushes on main instead, which is where the workflow
# runs, and a pull request or a branch build therefore cannot assume this role at all.
module "base_image_publisher_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name        = "${local.prefix}-base-image-publisher"
  role_description = "Pushes the shared webbpulse/python-lambda-base image to ECR from the main branch of WebbPulse/WebbPulse-Artifacts."

  # The provider already exists by the time this role is created; an account holds at most one per
  # URL, so this call trusts the one the Python role creates rather than creating a second.
  create_oidc_provider = false
  oidc_provider_arn    = module.python_publisher_role.oidc_provider_arn

  # GitHub issues the rename-proof immutable subject (repo:ORG@ORG_ID/REPO@REPO_ID:...) for this
  # repository too, so the trust policy must name that form. Read it back with
  # gh api repos/WebbPulse/WebbPulse-Artifacts/actions/oidc/customization/sub (sub_claim_prefix).
  # The ref suffix rather than an environment suffix is the deliberate choice described above.
  subjects = ["repo:WebbPulse@185014056/WebbPulse-Artifacts@1359997352:ref:refs/heads/main"]

  policy_statements = local.base_image_publisher_policy_statements
}
