module "codeartifact" {
  source  = "terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/codeartifact"
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

  reader_account_ids = local.consumer_account_ids

  publisher_principal_arns = [
    module.python_publisher_role.role_arn,
    module.npm_publisher_role.role_arn,
  ]

  publisher_repository_keys = ["python", "npm"]
}

locals {
  first_party_package_groups = {
    python = {
      pattern     = "/pypi//webbpulse~"
      description = "First-party webbpulse Python packages. Published to python only, never ingested from PyPI."
      repository  = "python"
    }

    npm = {
      pattern     = "/npm/webbpulse/*"
      description = "The first-party @webbpulse npm scope. Published to npm only, never ingested from the public registry."
      repository  = "npm"
    }
  }
}

resource "awscc_codeartifact_package_group" "first_party" {
  for_each = local.first_party_package_groups

  domain_name  = module.codeartifact.domain
  domain_owner = module.codeartifact.domain_owner
  pattern      = each.value.pattern
  description  = each.value.description

  origin_configuration = {
    restrictions = {
      publish = {
        restriction_mode = "ALLOW_SPECIFIC_REPOSITORIES"
        repositories     = [module.codeartifact.repository_names[each.value.repository]]
      }
      external_upstream = {
        restriction_mode = "BLOCK"
        repositories     = []
      }
      internal_upstream = {
        restriction_mode = "ALLOW"
        repositories     = []
      }
    }
  }

  tags = [for key, value in local.common_tags : { key = key, value = value }]
}
