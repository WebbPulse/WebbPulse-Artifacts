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
| **Publisher roles** | The two IAM roles the package repositories assume through GitHub OIDC to publish, and this account's GitHub OIDC provider |
| **Account housekeeping** | A tag based resource group, Cost Explorer anomaly detection, and two small budgets |

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

## The registry

One CodeArtifact domain, `webbpulse`, holding five repositories in three tiers. Storage is
deduplicated and billed once per domain, so an asset cached from PyPI is paid for once no matter
how many repositories it is visible through.

```
pypi-store   external connection -> public:pypi     the proxy, no first-party packages
npm-store    external connection -> public:npmjs    the proxy, no first-party packages
python       upstream -> pypi-store                 where webbpulse publishes
npm          upstream -> npm-store                  where @webbpulse publishes
shared       upstream -> python, npm                the single endpoint CI points at
```

A `pip install` against `shared` walks `shared` to `python` to `pypi-store` and out to PyPI,
caching every asset it fetches on the way back. The store repositories exist because CodeArtifact
refuses to combine an external connection with upstreams on one repository, and because a
first-party package published into the repository that proxies PyPI would shadow the public package
of the same name for everything downstream of it. Nothing publishes into a store repository, and
the publish grant is scoped so that nothing can.

Read access is granted to the four application accounts at the domain and on every repository.
Publish access is granted only to the two publisher roles below, and only on the repository each
one owns: `python` and `npm` and nothing else. Nothing publishes into `shared` either, because a
package written into the fan-in would be found ahead of the same package in `python` or `npm`,
which is the shadowing problem the store split exists to prevent one tier further up. Both the
repository policies here and each role's own identity policy say so, so a publish needs both halves
to agree.

## Publishing

Two repositories publish into this account. Each assumes a role through GitHub's OIDC provider, so
no AWS keys live in GitHub.

| Repository | Package | Publishes to | Role |
| --- | --- | --- | --- |
| `WebbPulse/webbpulse-python` | `webbpulse` | `python` | `artifacts-shared-python-publisher` |
| `WebbPulse/webbpulse-typescript` | `@webbpulse/*` | `npm` | `artifacts-shared-npm-publisher` |

Trust is scoped to the repository **and** its `publish` GitHub Environment, not to the repository
alone. The subject GitHub puts in the token for an environment-bound job is
`repo:WebbPulse/<repo>:environment:publish`, so a workflow that is not bound to that environment
cannot assume the role however the repository's other workflows are written. That is what makes the
environment's protection rules a real gate on a release rather than a convention.

Each publisher repository sets two secrets on its `publish` environment. Both are read from this
root's outputs after an apply:

| Secret | Value |
| --- | --- |
| `CODEARTIFACT_PUBLISH_ROLE_ARN` | `python_publisher_role_arn` or `npm_publisher_role_arn` |
| `CODEARTIFACT_DOMAIN_OWNER` | `codeartifact_domain_owner`, which is `432410731887` |

Neither is a credential. The role ARN is a name and the domain owner is an account id; they are
secrets only because the reusable workflow declares them as such, which keeps them out of forked
pull request runs. The publish workflows are the shared
`WebbPulse/.github` reusable workflows and already carry `permissions: id-token: write`, the domain
and region, and the repository to publish into, so nothing beyond those two values is set per
repository.

## Consuming

An application account reads from the registry at build time. A cross-account grant needs both
halves: the domain, repository and ECR policies in this account allow the consumer in, and the
consumer's own deploy role has to allow it out. This root hands the second half back rendered, so
nothing is reconstructed by hand.

Take `consumer_policy_json` from the outputs, or take
`codeartifact_consumer_policy_statements` and feed it straight into the `github-actions-role`
module's `policy_statements` in the consumer's own root:

```hcl
data "terraform_remote_state" "artifacts" {
  backend = "remote"

  config = {
    organization = "WebbPulse"
    workspaces   = { name = "WebbPulse-Artifacts" }
  }
}

module "github_actions_role" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/github-actions-role"
  version = "~> 2.0"

  role_name = "${local.prefix}-github-actions-deploy"
  subjects  = ["repo:WebbPulse/CarModPicker:*"]

  policy_statements = concat(
    local.existing_deploy_statements,
    [for s in data.terraform_remote_state.artifacts.outputs.codeartifact_consumer_policy_statements : {
      sid       = s.Sid
      actions   = s.Action
      resources = s.Resource
      condition = try(s.Condition, null)
    }],
  )
}
```

The piece most often forgotten is not a CodeArtifact action at all. `sts:GetServiceBearerToken`
lives in the consumer's own identity policy, and without it `get-authorization-token` fails no
matter what the resource policies here say. It is in the statements above, pinned with an
`sts:AWSServiceName` condition so the grant cannot mint a bearer token for another service.

Order matters across the two applies. This account applies first, and the consumer picks the ARNs
up on its next plan. A consumer that applies first reads an empty remote state and drops the
statements from its role, which fails closed: its builds keep working against the public registries
until the role is reapplied.

In a workflow, the job exchanges its GitHub OIDC token for its own account's role and that role
fetches a CodeArtifact token that lives only in the job:

```bash
aws codeartifact login --tool pip --domain webbpulse \
  --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" --repository shared
```

`--duration-seconds 0` on a raw `get-authorization-token` ties the token to the remaining time in
the assumed-role session, so it cannot outlive the job's own credentials. Without it a token
defaults to twelve hours regardless of the role's maximum session duration.

## Base images

`webbpulse/python-lambda-base` is the base layer the per-domain FastAPI Lambdas are built on. Tags
are immutable, which is the point: a tag that cannot move is what makes a build reproducible and
what makes a recorded digest mean something later. There is no floating `latest`, so a consumer
pins an explicit tag or a digest.

The four application accounts may pull. The repository policy also lets `lambda.amazonaws.com`
retrieve the image on behalf of a function in one of those accounts, which is what keeps a
container image Lambda alive when Lambda re-fetches the image after an optimisation pass. Lambda
cannot pull an image across regions, so a consumer function has to run in `us-west-2`.

A `docker build` that installs from CodeArtifact needs the token inside the build. Use a BuildKit
secret mount, never a build arg or an `ENV`: both of those are recorded in image history and ship
with the image.

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
    ├── versions.tf        required_version, providers, and the cloud block
    ├── providers.tf       the aws provider and its default tags
    ├── variables.tf       aws_region and environment
    ├── locals.tf          the prefix, the common tags, and the publisher policy statements
    ├── data.tf            caller identity and region
    ├── codeartifact.tf    the domain and its five repositories
    ├── iam_publishers.tf  the two publisher roles and the GitHub OIDC provider
    ├── ecr.tf             the shared base image repositories
    ├── management.tf      resource group, cost anomaly detection, budgets
    └── outputs.tf         everything a publisher or a consumer needs to wire in
```

Terraform reads only the `.tf` files sitting directly in the root module, so
every file here stays flat in `terraform/`; a subdirectory would drop out of the
configuration silently. Files are named `<provider>_<thing>.tf` once there is
more than one, matching the convention in the other Terraform roots in this
organization.

Requirements: Terraform `>= 1.10`, provider `hashicorp/aws >= 5.100 < 7.0`. The
lock file is committed once the first provider is initialised.
