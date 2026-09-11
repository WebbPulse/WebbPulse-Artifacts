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
| **Publisher roles** | The three IAM roles assumed through GitHub OIDC to publish: two for the package repositories, one for this repository's own base image build, plus this account's GitHub OIDC provider |
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

Three repositories publish into this account: the two package repositories, and this one, which
builds its own base image. Each assumes a role through GitHub's OIDC provider, so no AWS keys live
in GitHub.

| Repository | Package | Publishes to | Role |
| --- | --- | --- | --- |
| `WebbPulse/webbpulse-python` | `webbpulse` | `python` | `artifacts-shared-python-publisher` |
| `WebbPulse/webbpulse-typescript` | `@webbpulse/*` | `npm` | `artifacts-shared-npm-publisher` |
| `WebbPulse/WebbPulse-Artifacts` | `webbpulse/python-lambda-base` | ECR | `artifacts-shared-base-image-publisher` |

The two package roles are described below. The third publishes this repository's own base image and
is scoped to `main` rather than to an environment; see [Base images](#base-images).

Trust is scoped to the repository **and** its `publish` GitHub Environment, not to the repository
alone. The subject GitHub puts in the token for an environment-bound job is
`repo:WebbPulse/<repo>:environment:publish`, so a workflow that is not bound to that environment
cannot assume the role however the repository's other workflows are written. That is what makes the
environment's protection rules a real gate on a release rather than a convention.

Neither repository has a `publish` environment yet. Create one in each repository's settings before
the first release: without it the job's token carries no `environment:publish` subject, the role
refuses the assume, and the publish fails. The environment is also where a required reviewer goes if
a release should need a human to approve it.

Each publisher repository then sets two secrets on that environment. Both are read from this root's
outputs after an apply:

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

`webbpulse/python-lambda-base` is the base layer the per-domain FastAPI Lambdas are built on. The
Dockerfile is [`images/python-lambda-base/Dockerfile`](images/python-lambda-base/Dockerfile).

### What is in it, and what is deliberately not

The image holds two things and nothing else:

- The Python 3.13 runtime, `public.ecr.aws/docker/library/python:3.13-slim`, pinned by digest.
  Public ECR mirrors Docker Hub's official images, so this is the same content without Docker Hub's
  anonymous pull rate limit.
- The AWS Lambda Web Adapter, copied from `public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1` to
  `/opt/extensions/lambda-adapter`, also pinned by digest.

To bump either pin, read the current digest of the tag and replace the one in the Dockerfile:

```bash
token=$(curl -s "https://public.ecr.aws/token/?scope=repository:docker/library/python:pull&service=public.ecr.aws" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -sI -H "Authorization: Bearer $token" \
  -H "Accept: application/vnd.oci.image.index.v1+json" \
  https://public.ecr.aws/v2/docker/library/python/manifests/3.13-slim \
  | grep -i docker-content-digest
```

The adapter bumps the same way against
`https://public.ecr.aws/v2/awsguru/aws-lambda-adapter/manifests/1.0.1`. Take the digest on the
index, never on a per-platform manifest, or the build stops being multi-architecture.

Plus the conventions every WebbPulse Lambda image shares: a non-root `app` user, `/app` as the
working directory, and `AWS_LWA_PORT` and `PORT` both set to `8080`. Both port names are set because
the adapter reads `AWS_LWA_PORT` while most frameworks read `PORT`, and an application binding one
while the adapter polls the other hangs on every invoke instead of failing loudly.
`AWS_LWA_READINESS_CHECK_PATH` is left unset on purpose: the adapter blocks the first invoke until
that path answers, so it has to be a path the application actually serves and one that does no I/O.
Each entrypoint sets it.

**It does not contain the `webbpulse` package or any application dependencies.** That is the
decision, and it is what makes the base worth having. Dependencies install in each application's own
build, so bumping the shared package or an application requirement never requires a base rebuild,
and this image only changes when the runtime or the adapter does. The cost is that application
builds do not share a prebuilt dependency layer through the base; they share it through the build
cache and through their own image layers instead, which is where a per-project dependency set
belongs anyway.

There is no `ENTRYPOINT` and no `CMD`. This image never runs on its own; every application image
sets its own `CMD` to the entrypoint module for the domain it serves.

### Multi-architecture, and why that is safe

The image is pushed as a multi-architecture manifest holding `linux/amd64` and `linux/arm64`,
because CarModPicker builds x86_64 Lambdas and Portfolio builds arm64 and both build against this
one base.

Lambda does not support multi-architecture container images, but that constraint is on the image
Lambda pulls for a function, not on the parent an application image is built `FROM`. An application
build resolves the one manifest matching its own `--platform` and produces a single-platform image
of its own, which is what Lambda sees. This is why the shared `container-image.yml` reusable
workflow cannot build this image: it takes one platform and then asserts the pushed manifest is not
an index, which is right for an application image and wrong for a base. The workflow here asserts
the opposite, that the manifest *is* an index and that it holds both platforms, so a base that
quietly went single platform fails here rather than in the other project's build weeks later.

### Tags

Tags are immutable, which is the point: a tag that cannot move is what makes a build reproducible
and what makes a recorded digest mean something later. The build pushes exactly one tag,
`sha-<full commit sha>`. **There is no moving `py3.13` or `latest` tag**, and there cannot be one in
this repository, because `image_tag_mutability` is a repository-level setting and `IMMUTABLE` would
refuse the second push of any moving tag. Consumers pin `sha-<commit>` or the digest, which the
workflow's job summary prints ready to paste into a `FROM` line.

### Pulling it

The four application accounts may pull, granted by the repository policy `ecr.tf` builds from
`local.consumer_account_ids`. The policy also lets `lambda.amazonaws.com` retrieve the image on
behalf of a function in one of those accounts. Lambda never actually pulls *this* image, since it is
only ever a build-time parent, so that statement is inert here; it is the module's fixed pairing and
it is the correct pairing to keep, because for an image Lambda genuinely does pull cross-account the
service-principal statement is not optional and omitting it fails weeks later rather than at create
time. Lambda cannot pull an image across regions, so a consumer function has to run in `us-west-2`.

A `docker build` that installs from CodeArtifact needs the token inside the build. Use a BuildKit
secret mount, never a build arg or an `ENV`: both of those are recorded in image history and ship
with the image.

### Building and pushing it

`.github/workflows/python-lambda-base.yml` runs on a push to `main` touching
`images/python-lambda-base/**`, and on `workflow_dispatch`. It assumes
`artifacts-shared-base-image-publisher` through GitHub OIDC, so no AWS keys live in GitHub.

Trust is scoped to `ref:refs/heads/main` rather than to a GitHub environment, unlike the two package
publishers. A package version can never be republished under the same version, so a release wants a
protection rule in front of it; a base image push is a different shape, since the tag is the commit
sha, the repository refuses to move it, and a bad image is superseded by the next commit rather than
burning a version number. A pull request or a branch build cannot assume the role at all.

The role ARN is read from the repository variable `BASE_IMAGE_PUBLISHER_ROLE_ARN`, set from this
root's `base_image_publisher_role_arn` output after an apply. It is a variable rather than a secret
because a role ARN is a name, not a credential.

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
├── .github/workflows/
│   └── python-lambda-base.yml   builds and pushes the shared base image
├── images/
│   └── python-lambda-base/
│       └── Dockerfile           the Python 3.13 runtime plus the Lambda Web Adapter
└── terraform/
    ├── versions.tf        required_version, providers, and the cloud block
    ├── providers.tf       the aws provider and its default tags
    ├── variables.tf       aws_region and environment
    ├── locals.tf          the prefix, the common tags, and the publisher policy statements
    ├── data.tf            caller identity and region
    ├── codeartifact.tf    the domain and its five repositories
    ├── iam_publishers.tf  the three publisher roles and the GitHub OIDC provider
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
