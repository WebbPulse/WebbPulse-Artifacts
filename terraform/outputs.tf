output "aws_account_id" {
  description = "AWS account ID Terraform is deploying into"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  # .region rather than the .name the application roots use: those pin the AWS provider at ~> 5.0
  # and this root resolves to 6.x, where .name is deprecated.
  description = "AWS region being deployed to"
  value       = data.aws_region.current.region
}

# ---------------------------------------------------------------------------
# CodeArtifact
# ---------------------------------------------------------------------------

output "codeartifact_domain" {
  description = "CodeArtifact domain name, passed to every aws codeartifact call as --domain"
  value       = module.codeartifact.domain
}

output "codeartifact_domain_owner" {
  description = "Account id owning the CodeArtifact domain. Every call from another account must pass this as --domain-owner, because a domain name is only unique within its owning account. This is the value each publisher repository sets as the CODEARTIFACT_DOMAIN_OWNER secret"
  value       = module.codeartifact.domain_owner
}

output "codeartifact_domain_arn" {
  description = "ARN of the CodeArtifact domain, the resource a consumer policy names for codeartifact:GetAuthorizationToken"
  value       = module.codeartifact.domain_arn
}

output "codeartifact_repository_endpoints" {
  description = "Repository endpoint URL keyed \"<repository>:<format>\", for example \"shared:pypi\". These are the URLs pip's index-url and npm's registry point at, with the authorization token as the password"
  value       = module.codeartifact.endpoints
}

output "codeartifact_repository_arns" {
  description = "ARN of each CodeArtifact repository, keyed by repository name"
  value       = module.codeartifact.repository_arns
}

output "pip_index_url" {
  description = "Repository endpoint for pip, against the shared fan-in repository. The token goes in as the password: https://aws:TOKEN@<host>/simple/"
  value       = "${module.codeartifact.endpoints["shared:pypi"]}simple/"
}

output "npm_registry_url" {
  description = "Repository endpoint for npm, against the shared fan-in repository, for the registry line of an .npmrc"
  value       = module.codeartifact.endpoints["shared:npm"]
}

# ---------------------------------------------------------------------------
# Publisher roles
# ---------------------------------------------------------------------------

output "python_publisher_role_arn" {
  description = "Role WebbPulse/webbpulse-python assumes to publish. Set it as the CODEARTIFACT_PUBLISH_ROLE_ARN secret on that repository's publish environment"
  value       = module.python_publisher_role.role_arn
}

output "npm_publisher_role_arn" {
  description = "Role WebbPulse/webbpulse-typescript assumes to publish. Set it as the CODEARTIFACT_PUBLISH_ROLE_ARN secret on that repository's publish environment"
  value       = module.npm_publisher_role.role_arn
}

output "github_oidc_provider_arn" {
  description = "ARN of this account's token.actions.githubusercontent.com OIDC provider, created by this root. A future stack in this account passes it as oidc_provider_arn with create_oidc_provider set to false"
  value       = module.python_publisher_role.oidc_provider_arn
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

output "ecr_repository_urls" {
  description = "ECR repository URL keyed by short image name, the value a docker build tags and a Lambda ImageUri references"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "ARN of each ECR repository, keyed by short image name. These are the resources a consumer's own pull policy names"
  value       = module.ecr.repository_arns
}

# ---------------------------------------------------------------------------
# What consumers attach on their side
# ---------------------------------------------------------------------------

# A cross-account grant needs both halves. The domain, repository and ECR policies in this account
# allow the consumer in; these statements are the other half, and they go on the consumer's own
# deploy role in its own account. Handed back rendered rather than described in prose so a consumer
# copies a value instead of reconstructing an ARN list by hand.

output "codeartifact_consumer_policy_statements" {
  description = "IAM statements a consumer account attaches to its own deploy role to read from CodeArtifact, ready for the github-actions-role module's policy_statements input"
  value       = module.codeartifact.consumer_policy_statements
}

output "consumer_policy_json" {
  description = "The complete IAM policy a consumer account attaches to its deploy role, as JSON: CodeArtifact read across the domain and every repository, the sts:GetServiceBearerToken that get-authorization-token needs, and pull on the shared ECR base images. Paste it into an aws_iam_role_policy in the consumer's own root"
  value = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      module.codeartifact.consumer_policy_statements,
      [
        {
          Sid    = "SharedBaseImagePull"
          Effect = "Allow"
          Action = [
            "ecr:BatchGetImage",
            "ecr:DescribeImages",
            "ecr:GetDownloadUrlForLayer",
          ]
          Resource = module.ecr.repository_arns_list
        },
        {
          # GetAuthorizationToken is a registry level action with no resource of its own, which is
          # why it is a separate statement on "*" rather than folded into the one above.
          Sid      = "SharedBaseImageAuth"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = ["*"]
        },
      ],
    )
  })
}

output "base_image_publisher_role_arn" {
  description = "Role WebbPulse/WebbPulse-Artifacts assumes to push the shared Python Lambda base image. Set it as the BASE_IMAGE_PUBLISHER_ROLE_ARN repository variable on that repository; it is a name rather than a credential, so it is a variable and not a secret"
  value       = module.base_image_publisher_role.role_arn
}
