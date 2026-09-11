locals {
  project = "Artifacts"

  prefix = "${lower(local.project)}-${var.environment}"

  common_tags = {
    Project     = local.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  codeartifact_domain = "webbpulse"

  consumer_account_ids = [
    "036807648992",
    "621554169154",
    "734702670403",
    "748861776298",
  ]

  python_publish_repository_arn = module.codeartifact.repository_arns["python"]
  npm_publish_repository_arn    = module.codeartifact.repository_arns["npm"]

  publisher_token_statements = [
    {
      sid       = "CodeArtifactToken"
      actions   = ["codeartifact:GetAuthorizationToken"]
      resources = [module.codeartifact.domain_arn]
    },
    {
      sid       = "CodeArtifactBearerToken"
      actions   = ["sts:GetServiceBearerToken"]
      resources = ["*"]
      condition = {
        StringEquals = {
          "sts:AWSServiceName" = ["codeartifact.amazonaws.com"]
        }
      }
    },
  ]

  publisher_package_actions = [
    "codeartifact:DescribePackageVersion",
    "codeartifact:ListPackageVersions",
    "codeartifact:PublishPackageVersion",
    "codeartifact:PutPackageMetadata",
  ]

  publisher_repository_actions = [
    "codeartifact:DescribeRepository",
    "codeartifact:GetRepositoryEndpoint",
    "codeartifact:ListPackages",
    "codeartifact:ReadFromRepository",
  ]

  python_publish_package_arn = "${replace(local.python_publish_repository_arn, ":repository/", ":package/")}/*"
  npm_publish_package_arn    = "${replace(local.npm_publish_repository_arn, ":repository/", ":package/")}/*"

  python_publisher_policy_statements = concat(
    local.publisher_token_statements,
    [
      {
        sid       = "CodeArtifactPublishPythonPackages"
        actions   = local.publisher_package_actions
        resources = [local.python_publish_package_arn]
      },
      {
        sid       = "CodeArtifactPublishPythonRepository"
        actions   = local.publisher_repository_actions
        resources = [local.python_publish_repository_arn]
      },
    ],
  )

  npm_publisher_policy_statements = concat(
    local.publisher_token_statements,
    [
      {
        sid       = "CodeArtifactPublishNpmPackages"
        actions   = local.publisher_package_actions
        resources = [local.npm_publish_package_arn]
      },
      {
        sid       = "CodeArtifactPublishNpmRepository"
        actions   = local.publisher_repository_actions
        resources = [local.npm_publish_repository_arn]
      },
    ],
  )

  base_image_repository_arn = module.ecr.repository_arns["python-lambda-base"]

  base_image_publisher_policy_statements = [
    {
      sid       = "EcrAuth"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]
    },
    {
      sid = "EcrPushBaseImage"
      actions = [
        "ecr:BatchCheckLayerAvailability",
        "ecr:BatchGetImage",
        "ecr:CompleteLayerUpload",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:GetDownloadUrlForLayer",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
      ]
      resources = [local.base_image_repository_arn]
    },
  ]
}
