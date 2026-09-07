locals {
  project = "Artifacts"

  # Use as a prefix for all resource names: "${local.prefix}-python-publisher", etc. Lowercased,
  # because IAM role names and ECR repository names in this estate are lowercase throughout while
  # the Project tag is title cased.
  prefix = "${lower(local.project)}-${var.environment}"

  # Applied to every resource via provider default_tags.
  # Add resource-specific tags inline where needed.
  common_tags = {
    Project     = local.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  codeartifact_domain = "webbpulse"

  # The four application accounts that read from the registry at build time. Nothing in this account
  # reads from itself, so the artifacts account is deliberately absent.
  consumer_account_ids = [
    "036807648992", # Portfolio production
    "621554169154", # Portfolio staging
    "734702670403", # CarModPicker production
    "748861776298", # CarModPicker staging
  ]

  # The one repository each publisher may write to. Publishing is scoped per package manager rather
  # than granted across the domain: the Python workflow has no reason to reach the npm repository,
  # and a token that could write to both is a wider blast radius than a release job needs.
  python_publish_repository_arn = module.codeartifact.repository_arns["python"]
  npm_publish_repository_arn    = module.codeartifact.repository_arns["npm"]

  # Every publisher needs three things, and the piece most often forgotten is not a CodeArtifact
  # action at all: sts:GetServiceBearerToken lives in the caller's own identity policy, and without
  # it get-authorization-token fails no matter what the resource policies allow. It is pinned with
  # an sts:AWSServiceName condition so the grant cannot mint a bearer token for another service.
  #
  # GetAuthorizationToken is a domain level action, so it is granted on the domain ARN rather than
  # on a repository: a principal holding every repository permission there is still cannot fetch a
  # token without it.
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

  # The publish actions themselves, split by the resource each one is evaluated against, because
  # CodeArtifact does not scope them all the same way. DescribePackageVersion, ListPackageVersions,
  # PublishPackageVersion and PutPackageMetadata are package-level actions: IAM evaluates them
  # against arn:...:package/<domain>/<repository>/<format>/<namespace>/<name>, so a statement that
  # names the repository ARN silently denies them. The first webbpulse-typescript release proved it:
  # the version lookup step got AccessDeniedException on DescribePackageVersion even though the
  # action was listed, and the publish itself only went through because the repository resource
  # policy (rendered by the codeartifact module on the package ARN) allowed it. The remaining
  # actions are repository-level and stay on the repository ARN.
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

  # A repository ARN is arn:aws:codeartifact:<region>:<account>:repository/<domain>/<repository>;
  # swapping the one ":repository/" segment gives the package ARN prefix for every package of every
  # format in that repository. Derived rather than assembled so it cannot drift from the module.
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

  # The base image repository this account's own CI pushes to. Scoped to the one repository rather
  # than to every repository the ECR module makes, so a second base image added later is an explicit
  # grant rather than something this role silently acquires.
  base_image_repository_arn = module.ecr.repository_arns["python-lambda-base"]

  # What a push needs, and nothing more. GetAuthorizationToken is a registry level action with no
  # resource of its own, which is why it sits on "*" in its own statement; every other action is
  # scoped to the one repository. The read actions are here because buildx pulls the previous
  # manifest to reuse layers and because the run reads back the manifest it just pushed to assert
  # that it is a two-platform index. There is no ecr:DeleteRepository, no policy write, and no
  # ecr:BatchDeleteImage: the lifecycle policy is what removes images, not CI.
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
