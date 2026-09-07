# The organization's package registry. One domain, because CodeArtifact deduplicates storage per
# domain: an asset is stored and billed once no matter how many repositories in the domain it is
# visible through. A second domain would be a second copy of every cached wheel and a second set of
# cross-account policies to keep in step.
#
# Five repositories in three tiers:
#
#   pypi-store  external connection -> public:pypi     the proxy, holds no first-party packages
#   npm-store   external connection -> public:npmjs    the proxy, holds no first-party packages
#   python      upstream -> pypi-store                 where webbpulse publishes
#   npm         upstream -> npm-store                  where @webbpulse publishes
#   shared      upstream -> python, npm                the single endpoint CI points at
#
# The store repositories exist because CodeArtifact refuses to combine an external connection with
# upstreams on one repository, and because a first-party package published into the repository that
# proxies PyPI would shadow the public package of the same name for everything downstream of it.
module "codeartifact" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/codeartifact"
  version = "~> 2.0"

  domain = local.codeartifact_domain

  repositories = {
    "pypi-store" = {
      description          = "Proxy of the public PyPI registry. Holds no first-party packages."
      external_connections = ["public:pypi"]
    }

    "npm-store" = {
      description          = "Proxy of the public npm registry. Holds no first-party packages."
      external_connections = ["public:npmjs"]
    }

    "python" = {
      description = "WebbPulse Python packages, falling through to PyPI"
      upstreams   = ["pypi-store"]
    }

    "npm" = {
      description = "WebbPulse TypeScript packages, falling through to npm"
      upstreams   = ["npm-store"]
    }

    "shared" = {
      description = "The single endpoint CI points at, for both package managers"
      upstreams   = ["python", "npm"]
    }
  }

  # The four application accounts read the whole domain. This is half of the grant: each account's
  # own deploy role still needs the matching identity-based policy, which the
  # codeartifact_consumer_policy_statements output hands back ready to attach.
  reader_account_ids = local.consumer_account_ids

  # Publishing is scoped to the two publisher roles created in this root, never to an account root.
  publisher_principal_arns = [
    module.python_publisher_role.role_arn,
    module.npm_publisher_role.role_arn,
  ]

  # The module would default this to every repository without an external connection, which would
  # include shared. Nothing should ever publish into the fan-in: a package written there would be
  # found ahead of the same package in python or npm, which is the shadowing problem the store split
  # exists to prevent, one tier further up. Naming the two repositories explicitly leaves shared
  # readable and not writable.
  #
  # Each role's own identity policy already narrows it to the single repository it owns, so a
  # publish needs both halves to agree. This is the resource half, and it is the half that still
  # holds if an identity policy is ever widened by accident.
  publisher_repository_keys = ["python", "npm"]
}
