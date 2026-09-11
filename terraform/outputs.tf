output "aws_account_id" {
  description = "AWS account ID Terraform is deploying into"
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  description = "AWS region being deployed to"
  value       = data.aws_region.current.region
}

output "codeartifact_domain" {
  description = "CodeArtifact domain name, passed to every aws codeartifact call as --domain"
  value       = module.codeartifact.domain
}

output "codeartifact_domain_owner" {
  description = "Account id owning the CodeArtifact domain. Callers from another account pass it as --domain-owner, and publisher repositories set it as CODEARTIFACT_DOMAIN_OWNER"
  value       = module.codeartifact.domain_owner
}

output "codeartifact_domain_arn" {
  description = "ARN of the CodeArtifact domain, the resource a consumer policy names for codeartifact:GetAuthorizationToken"
  value       = module.codeartifact.domain_arn
}

output "codeartifact_repository_endpoints" {
  description = "Repository endpoint URL keyed \"<repository>:<format>\", the URL pip's index-url and npm's registry point at"
  value       = module.codeartifact.endpoints
}

output "codeartifact_repository_arns" {
  description = "ARN of each CodeArtifact repository, keyed by repository name"
  value       = module.codeartifact.repository_arns
}

output "pip_index_url" {
  description = "Repository endpoint for pip against the shared fan-in repository, with the token supplied as the password"
  value       = "${module.codeartifact.endpoints["shared:pypi"]}simple/"
}

output "npm_registry_url" {
  description = "Repository endpoint for npm against the shared fan-in repository, for the registry line of an .npmrc"
  value       = module.codeartifact.endpoints["shared:npm"]
}

output "python_publisher_role_arn" {
  description = "Role WebbPulse/webbpulse-python assumes to publish, set as CODEARTIFACT_PUBLISH_ROLE_ARN on that repository's publish environment"
  value       = module.python_publisher_role.role_arn
}

output "npm_publisher_role_arn" {
  description = "Role WebbPulse/webbpulse-typescript assumes to publish, set as CODEARTIFACT_PUBLISH_ROLE_ARN on that repository's publish environment"
  value       = module.npm_publisher_role.role_arn
}

output "github_oidc_provider_arn" {
  description = "ARN of this account's token.actions.githubusercontent.com OIDC provider, for a later stack passing oidc_provider_arn with create_oidc_provider false"
  value       = module.python_publisher_role.oidc_provider_arn
}

output "ecr_repository_urls" {
  description = "ECR repository URL keyed by short image name, the value a docker build tags and a Lambda ImageUri references"
  value       = module.ecr.repository_urls
}

output "ecr_repository_arns" {
  description = "ARN of each ECR repository, keyed by short image name, the resources a consumer's own pull policy names"
  value       = module.ecr.repository_arns
}

output "codeartifact_consumer_policy_statements" {
  description = "IAM statements a consumer account attaches to its own deploy role to read from CodeArtifact, shaped for the github-actions-role module's policy_statements input"
  value       = module.codeartifact.consumer_policy_statements
}

output "consumer_policy_json" {
  description = "Complete IAM policy JSON a consumer account attaches to its deploy role: CodeArtifact read, sts:GetServiceBearerToken, and pull on the shared ECR base images"
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
  description = "Role WebbPulse/WebbPulse-Artifacts assumes to push the shared Python Lambda base image, set as the BASE_IMAGE_PUBLISHER_ROLE_ARN repository variable"
  value       = module.base_image_publisher_role.role_arn
}
