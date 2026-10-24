resource "aws_iam_role" "dependabot_reader" {
  name                 = "${local.prefix}-dependabot-reader"
  description          = "Read-only CodeArtifact access for Dependabot update jobs in the product repositories, assumed through GitHub OIDC with no stored credential."
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DependabotUpdateJobs"
        Effect = "Allow"
        Principal = {
          Federated = module.python_publisher_role.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud"                 = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:repository_owner_id" = local.github_org_id
            "token.actions.githubusercontent.com:repository_id"       = sort([for repo in values(local.dependabot_reader_repositories) : repo.id])
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = sort([for repo in values(local.dependabot_reader_repositories) : "${repo.sub_prefix}:*"])
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "dependabot_reader" {
  name = "codeartifact-read"
  role = aws_iam_role.dependabot_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CodeArtifactToken"
        Effect   = "Allow"
        Action   = "codeartifact:GetAuthorizationToken"
        Resource = module.codeartifact.domain_arn
      },
      {
        Sid      = "CodeArtifactBearerToken"
        Effect   = "Allow"
        Action   = "sts:GetServiceBearerToken"
        Resource = "*"
        Condition = {
          StringEquals = {
            "sts:AWSServiceName" = "codeartifact.amazonaws.com"
          }
        }
      },
      {
        Sid    = "CodeArtifactReadRepositories"
        Effect = "Allow"
        Action = local.dependabot_reader_repository_actions
        Resource = [
          local.python_publish_repository_arn,
          local.npm_publish_repository_arn,
        ]
      },
      {
        Sid    = "CodeArtifactReadPackages"
        Effect = "Allow"
        Action = local.dependabot_reader_package_actions
        Resource = [
          local.python_publish_package_arn,
          local.npm_publish_package_arn,
        ]
      },
    ]
  })
}
