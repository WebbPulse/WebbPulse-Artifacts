# WebbPulse-Artifacts

Terraform for the shared build services every WebbPulse project consumes and no
single project owns. It deploys into the AWS account **WebbPulse Artifacts**
(`432410731887`), which sits in the `Infrastructure` OU of organization
`o-dagzjjexew` and holds nothing else.

## What lives here

| | |
| --- | --- |
| **CodeArtifact** | The organization's package domain and its repositories: the shared Python and npm packages the application repositories build against, plus the upstream connections that proxy PyPI and npm |
| **ECR** | Base image repositories. The per-domain FastAPI Lambdas ship as OCI images, and the base layer they are built on belongs here rather than in any one application's account |

Nothing else. **No workloads run in this account** - no Lambdas serving traffic,
no databases, no CloudFront distributions. Those live in the four application
accounts, and they read from this one at build time.

## One environment, deliberately

There is a single environment, `shared`. A package registry and a base image
registry are consumed by production and staging alike, so splitting them in two
would mean either promoting artifacts between registries or building each twice.
Neither buys anything: an artifact is immutable and already carries its own
version, and the thing that separates production from staging is which version
each deploys, not which registry it reads.

That is why this repository has one branch, `main`, one workspace, and no
`staging` branch. It is also why the ledger entry in `WebbPulse-Platform` reads
`environment = "shared"` rather than the `prod` / `staging` pair every
application project carries.

## Naming

**Platform** is the control plane: the `WebbPulse-Platform` repository, the
workspace of the same name, and the HCP Terraform project that holds the two
Terraform roots. **Artifacts** is this - the shared build services account. The
two are separate things and the words are not interchangeable.

## How it deploys

| | |
| --- | --- |
| HCP Terraform organization | `WebbPulse` |
| Workspace | `WebbPulse-Artifacts`, bound to `main`, working directory `terraform/` |
| AWS account | `432410731887` (`WebbPulse Artifacts`) |
| Region | `us-west-2` |
| Apply | Manual. A merge to `main` queues a plan; only an approved apply moves infrastructure |

Credentials are never static. The workspace federates into an IAM run role in
the artifacts account through HCP Terraform's AWS dynamic provider credentials,
and both the role and the workspace are vended by the factory in
[`WebbPulse-Platform`](https://github.com/WebbPulse/WebbPulse-Platform). Nothing
about this repository's wiring is configured by hand; it is a data edit in that
repository's ledger.

## Making a change

1. Branch from `main` and open a pull request. There is no `staging` branch.
2. Read the plan action by action, not off the summary line. **Zero destroys and
   zero replacements is the acceptance bar.** A registry that is destroyed and
   recreated loses every artifact in it, and a published package version can
   never be republished under the same version.
3. Merge. The workspace queues a plan on `main`.
4. Approve the apply by hand in HCP Terraform.

## Layout

```
.
├── README.md
└── terraform/
    ├── versions.tf     required_version, providers, and the cloud block
    └── providers.tf    the aws provider and its default tags
```

Terraform reads only the `.tf` files sitting directly in the root module, so
every file here stays flat in `terraform/`; a subdirectory would drop out of the
configuration silently. Files are named `<provider>_<thing>.tf` once there is
more than one, matching the convention in the other Terraform roots in this
organization.

Requirements: Terraform `>= 1.10`, provider `hashicorp/aws >= 5.100 < 7.0`. The
lock file is committed once the first provider is initialised.
