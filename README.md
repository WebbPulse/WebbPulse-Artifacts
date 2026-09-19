# WebbPulse-Artifacts

Terraform for the shared build services every WebbPulse project consumes and no
single project owns. It deploys into the AWS account `WebbPulse Artifacts`
(`432410731887`), in the `Infrastructure` OU of organization `o-dagzjjexew`.

## What this root owns

| | |
| --- | --- |
| **CodeArtifact** | The `webbpulse` domain and its five repositories: the first-party Python and npm packages, plus the upstream connections that proxy PyPI and npm |
| **ECR** | `webbpulse/python-lambda-base`, the base layer the per-domain FastAPI Lambdas are built on |
| **Publisher roles** | Three IAM roles assumed through GitHub OIDC, plus this account's GitHub OIDC provider |
| **Account housekeeping** | A tag-based resource group, Cost Explorer anomaly detection, two budgets |

No workloads run in this account: no Lambdas serving traffic, no databases, no
CloudFront. Those live in the application accounts, which read from this one
at build time.

There is one environment, `shared`, and one branch, `main`. A package registry
and a base image registry are consumed by production and staging alike; an
artifact is immutable and carries its own version, so what separates production
from staging is which version each deploys, not which registry it reads.

Naming: **Platform** is the control plane (the `WebbPulse-Platform` repository,
its workspace, and the HCP project holding the two Terraform roots). **Artifacts**
is this, the shared build services account. The words are not interchangeable.

### The registry layout

```
pypi-store   external connection -> public:pypi     the proxy, no first-party packages
npm-store    external connection -> public:npmjs    the proxy, no first-party packages
python       upstream -> pypi-store                 where webbpulse publishes
npm          upstream -> npm-store                  where @webbpulse publishes
shared       upstream -> python, npm                the single endpoint CI points at
```

A `pip install` against `shared` walks `shared` to `python` to `pypi-store` and
out to PyPI, caching every asset on the way back. Storage is deduplicated and
billed once per domain.

Read access is granted to the application accounts at the domain and on
every repository. Publish access is granted only to the two publisher roles, and
only on the repository each one owns, in both the repository policy and the
role's own identity policy.

## How to run it

### A Terraform change

1. Branch from `main` and open a pull request. There is no `staging` branch.
2. Read the plan action by action, not off the summary line. Zero destroys and
   zero replacements is the acceptance bar. A registry that is destroyed and
   recreated loses every artifact in it, and a published package version can
   never be republished under the same version.
3. Merge. The `WebbPulse-Artifacts` workspace queues a plan on `main`.
4. Approve the apply by hand in HCP Terraform.

Credentials are never static. The workspace federates into an IAM run role in
this account through HCP Terraform's AWS dynamic provider credentials, and both
the role and the workspace are vended by the factory in `WebbPulse-Platform`.

### Publishing or refreshing the base image

`.github/workflows/python-lambda-base.yml` runs on a push to `main` touching
`images/python-lambda-base/**`, and on `workflow_dispatch`.

1. Edit `images/python-lambda-base/Dockerfile`. To bump the runtime or adapter
   pin, read the current digest of the tag from the public ECR registry and
   replace the one in the Dockerfile. Take the digest on the **index**, never on
   a per-platform manifest, or the build stops being multi-architecture.
2. Open a pull request, merge to `main`. The workflow assumes
   `artifacts-shared-base-image-publisher` through GitHub OIDC and pushes.
3. The build pushes exactly one tag, `sha-<full commit sha>`, as a
   multi-architecture manifest holding `linux/amd64` and `linux/arm64`. The
   workflow asserts the pushed manifest **is** an index and holds both platforms.
4. Take the digest from the workflow's job summary and paste it into the
   consuming `FROM` line.

To publish a version of a shared package, tag the package repository
(`WebbPulse/webbpulse-python` or `WebbPulse/webbpulse-typescript`). The release
job binds to that repository's `publish` GitHub Environment, which is what the
publisher role's trust is scoped to.

### Granting a consumer account access

1. Apply this root first. A consumer that applies first reads an empty remote
   state and drops the statements from its role, which fails closed: its builds
   keep working against the public registries until the role is reapplied.
2. In the consumer's own root, read this workspace's remote state and feed
   `codeartifact_consumer_policy_statements` into the `github-actions-role`
   module's `policy_statements`. Do not reconstruct the statements by hand.
3. Confirm `sts:GetServiceBearerToken` is in the consumer's identity policy. It
   is in the rendered statements, pinned with an `sts:AWSServiceName` condition.
4. In a workflow, the job exchanges its GitHub OIDC token for its own account's
   role, and that role fetches a CodeArtifact token scoped to the job:
   `aws codeartifact login --tool pip --domain webbpulse --domain-owner "$CODEARTIFACT_DOMAIN_OWNER" --repository shared`.

## Identifiers

| Thing | Value |
| --- | --- |
| AWS account | `432410731887`, `WebbPulse Artifacts` |
| Region | `us-west-2`. Lambda cannot pull an image across regions, so a consumer function has to run here |
| HCP Terraform org / workspace | `WebbPulse` / `WebbPulse-Artifacts`, bound to `main`, working directory `terraform/` |
| CodeArtifact domain | `webbpulse` |
| CodeArtifact repositories | `pypi-store`, `npm-store`, `python`, `npm`, `shared` |
| ECR repository | `webbpulse/python-lambda-base`, `IMMUTABLE` tags |
| Consumer accounts | `036807648992`, `621554169154`, `734702670403`, `748861776298`, `870550636948`, `897427573432`, `212598081999`, `147741822161` |
| Role name prefix | `artifacts-shared-` |
| Publisher roles | `artifacts-shared-python-publisher`, `artifacts-shared-npm-publisher`, `artifacts-shared-base-image-publisher`, each `arn:aws:iam::432410731887:role/<name>` |
| Shared modules | `app.terraform.io/WebbPulse/platform-modules/aws//modules/<name>`, `~> 2.0` |

GitHub Actions variables and secrets read by the workflows:

| Name | Where | Value from output |
| --- | --- | --- |
| `BASE_IMAGE_PUBLISHER_ROLE_ARN` | repository variable, this repo | `base_image_publisher_role_arn` |
| `CODEARTIFACT_PUBLISH_ROLE_ARN` | `publish` environment secret, each package repo | `python_publisher_role_arn` or `npm_publisher_role_arn` |
| `CODEARTIFACT_DOMAIN_OWNER` | `publish` environment secret, each package repo | `codeartifact_domain_owner`, which is `432410731887` |

Neither publish secret is a credential; a role ARN is a name and the domain owner
is an account id. They are secrets because the reusable workflow declares them
so, which keeps them out of forked pull request runs.

## Gotchas

- **CodeArtifact package-level IAM actions need the PACKAGE ARN, not the
  repository ARN.** `codeartifact:DescribePackage`, `PublishPackageVersion` and
  `PutPackageMetadata` are scoped at the package. `locals.tf` derives the package
  ARN by rewriting `:repository/` to `:package/` and appending `/*`. Scoping them
  to the repository ARN fails at publish time, not at apply time.
- **A GitHub Actions rerun reuses the old reusable-workflow ref.** Rerunning a
  failed job after the org workflow in `WebbPulse/.github` has moved replays the
  ref the original run resolved. Dispatch a fresh run instead.
- **Newer GitHub repositories get immutable OIDC subjects**, of the form
  `repo:WebbPulse@185014056/<repo>@<id>:...`, not the legacy
  `repo:WebbPulse/<repo>:...`. All three publisher roles here use the immutable
  form. Read the repository's `sub_claim_prefix` before writing any trust policy
  against it.
- **The two package roles are scoped to the `publish` GitHub Environment**, so a
  workflow not bound to that environment cannot assume the role however its other
  workflows are written. The environment must exist in the package repository
  before the first release, or the token carries no `environment:publish` subject
  and the assume is refused. The base image role is scoped to
  `ref:refs/heads/main` instead: its tag is the commit sha, cannot move, and a
  bad image is superseded by the next commit rather than burning a version.
- **Nothing publishes into a store repository or into `shared`.** A first-party
  package in a repository that proxies a public registry, or in the fan-in, would
  shadow the public package of the same name for everything downstream. The store
  split exists for that reason, and the grants enforce it.
- **CodeArtifact refuses to combine an external connection with upstreams** on
  one repository. That is why `pypi-store` and `npm-store` exist separately.
- **ECR tags here are immutable, and that is repository-level.** There is no
  moving `py3.13` or `latest` tag and there cannot be one, because a second push
  of a moving tag would be refused. Consumers pin `sha-<commit>` or the digest.
- **Lambda does not support multi-architecture container images**, but that
  constraint is on the image Lambda pulls for a function, not on the parent an
  application image is built `FROM`. An application build resolves the one
  manifest matching its own `--platform`. This is why the shared
  `container-image.yml` reusable workflow cannot build this image: it asserts the
  pushed manifest is not an index, which is right for an application image and
  wrong for a base.
- **The base image contains no `webbpulse` package and no application
  dependencies**, on purpose. Dependencies install in each application's own
  build, so bumping a shared package never requires a base rebuild. It has no
  `ENTRYPOINT` and no `CMD`; every application image sets its own.
- **There is no builder image and no builder stage**, although the product builder
  stages are byte identical. A second pinned image defeats `base-image-cache`,
  which resolves one `ARG BASE_IMAGE=` only; `ONBUILD` runs before the child copies
  its lockfile in; and `ARG DEPENDENCY_RESOLUTION` has to stay next to the
  CodeArtifact `RUN` in the product, because the stamp is per build and per
  environment. `images/python-lambda-base/README.md` has the full reasoning.
- **`AWS_LWA_PORT` and `PORT` are both set to `8080`.** The adapter reads the
  first and most frameworks read the second; an application binding one while the
  adapter polls the other hangs on every invoke instead of failing loudly.
  `AWS_LWA_READINESS_CHECK_PATH` is deliberately unset, because the adapter blocks
  the first invoke until that path answers, so each entrypoint sets its own.
- **Pass the CodeArtifact token into `docker build` as a BuildKit secret mount**,
  never a build arg or an `ENV`. Both of those are recorded in image history and
  ship with the image.
- **`--duration-seconds 0` on a raw `get-authorization-token`** ties the token to
  the remaining time in the assumed-role session. Without it the token defaults to
  twelve hours regardless of the role's maximum session duration.

## Layout

```
.
├── .github/workflows/
│   └── python-lambda-base.yml   builds and pushes the shared base image
├── images/
│   └── python-lambda-base/
│       ├── Dockerfile           Python 3.13 plus the Lambda Web Adapter, both pinned by digest
│       └── README.md            what the image carries, and why there is no builder image
└── terraform/
    ├── versions.tf        required_version, providers, and the cloud block
    ├── providers.tf       the aws provider and its default tags
    ├── variables.tf       aws_region and environment
    ├── locals.tf          the prefix, common tags, and the publisher policy statements
    ├── data.tf            caller identity and region
    ├── codeartifact.tf    the domain and its five repositories
    ├── ecr.tf             the base image repository and its policy
    ├── iam_publishers.tf  the three GitHub OIDC publisher roles
    ├── management.tf      the resource group, anomaly detection and budgets
    └── outputs.tf         ARNs, ids, and the rendered consumer policy
```
