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
| **Dependabot reader role** | One read-only IAM role Dependabot update jobs in the product repositories assume through GitHub OIDC |
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

Two package groups make the first-party names internal-only. `/pypi//webbpulse~`
(`webbpulse` and any `webbpulse-*` name) and `/npm/webbpulse/*` (the whole
`@webbpulse` scope) block ingestion from the public registries in every repository
and allow publishing only into `python` and `npm` respectively. A public package
squatting one of those names can never enter the domain, so the store upstreams
are not a dependency-confusion path.

A `pip install` against `shared` walks `shared` to `python` to `pypi-store` and
out to PyPI, caching every asset on the way back. Storage is deduplicated and
billed once per domain.

Read access is granted to the application accounts at the domain and on
every repository. Publish access is granted only to the two publisher roles, and
only on the repository each one owns, in both the repository policy and the
role's own identity policy.

## How to run it

### A Terraform change

1. Branch from `main` and open a pull request. There is no `staging` branch. The
   control plane runs a plan-only run on it.
2. Read the plan action by action, not off the summary line. Zero destroys and
   zero replacements is the acceptance bar. A registry that is destroyed and
   recreated loses every artifact in it, and a published package version can
   never be republished under the same version.
3. Merge. The `WebbPulse-Artifacts` workspace queues a plan on `main`.
4. Confirm the held apply by hand on the WebbPulse control plane (`terraform.webbpulse.com`).

Credentials are never static. The workspace federates into an IAM run role in
this account through the control plane's run role credentials, and both
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

### Letting Dependabot read CodeArtifact

Dependabot jobs run behind a proxy that only reaches hosts named in a
`registries` entry, so without one every `uv` update that has to resolve
`webbpulse`, and every `npm` update whose lockfile holds CodeArtifact `resolved`
URLs, fails with a 403. The `registries` entries authenticate through OIDC: the
proxy mints a GitHub Actions token with audience `sts.amazonaws.com`, calls
`AssumeRoleWithWebIdentity` on `artifacts-shared-dependabot-reader` in this
account with session name `dependabot-update`, then calls
`codeartifact:GetAuthorizationToken`. No secret or long-lived key is stored, and
the role lives in the domain owner's account, so no consumer account is involved.

To add a repository, add it to `dependabot_reader_repositories` in `locals.tf`
with its repository id and its `sub_claim_prefix`
(`gh api repos/WebbPulse/<repo>/actions/oidc/customization/sub`), apply this
root, then add the entries below to the repository's `.github/dependabot.yml`:

```yaml
registries:
  codeartifact-python:
    type: python-index
    url: https://webbpulse-432410731887.d.codeartifact.us-west-2.amazonaws.com/pypi/python/simple/
    aws-region: us-west-2
    account-id: "432410731887"
    role-name: artifacts-shared-dependabot-reader
    domain: webbpulse
    domain-owner: "432410731887"
  codeartifact-npm:
    type: npm-registry
    url: https://webbpulse-432410731887.d.codeartifact.us-west-2.amazonaws.com/npm/npm/
    aws-region: us-west-2
    account-id: "432410731887"
    role-name: artifacts-shared-dependabot-reader
    domain: webbpulse
    domain-owner: "432410731887"
```

Each `updates` entry then names the registry it needs: `registries:
[codeartifact-python]` on the `uv` entry and `registries: [codeartifact-npm]` on
each `npm` entry. Leave `replaces-base` unset on both. The uv index is
`explicit`, so only `webbpulse` resolves from it, and `.npmrc` routes only the
`@webbpulse` scope to the npm repository; everything else keeps the public
registries. `audience` is left unset, which the proxy defaults to
`sts.amazonaws.com`.

For npm, give each directory its own `updates` entry and attach
`codeartifact-npm` only to the directories that depend on `@webbpulse/*`. Each of
those directories needs a committed, token-free `.npmrc` with the scope line
below. A directory with the registry attached but no such `.npmrc` fails the
whole job with `private_registry_config_not_found`, so leave `registries` off the
directories that use only public packages.

```ini
@webbpulse:registry=https://webbpulse-432410731887.d.codeartifact.us-west-2.amazonaws.com/npm/npm/
```

CI is unaffected: the reusable workflows add the CodeArtifact token over OIDC,
and public lockfile entries keep their `registry.npmjs.org` `resolved` URLs.

## Identifiers

| Thing | Value |
| --- | --- |
| AWS account | `432410731887`, `WebbPulse Artifacts` |
| Region | `us-west-2`. Lambda cannot pull an image across regions, so a consumer function has to run here |
| Control plane workspace | `WebbPulse-Artifacts` on `terraform.webbpulse.com`, bound to `main`, working directory `terraform/` |
| CodeArtifact domain | `webbpulse` |
| CodeArtifact repositories | `pypi-store`, `npm-store`, `python`, `npm`, `shared` |
| ECR repository | `webbpulse/python-lambda-base`, `IMMUTABLE` tags |
| Consumer accounts | `036807648992`, `621554169154`, `734702670403`, `748861776298`, `870550636948`, `897427573432`, `212598081999`, `147741822161`, `167557610890`, `832896310536` |
| Role name prefix | `artifacts-shared-` |
| Publisher roles | `artifacts-shared-python-publisher`, `artifacts-shared-npm-publisher`, `artifacts-shared-base-image-publisher`, each `arn:aws:iam::432410731887:role/<name>` |
| Dependabot reader role | `artifacts-shared-dependabot-reader`, trusted by Standupless (`1375434030`), CarModPicker (`1034793334`) and WebbPulse-Portfolio (`1029410045`) |
| GitHub organization id | `185014056` |
| Shared modules | `terraform.webbpulse.com/WebbPulse/platform-modules/aws//modules/<name>`, `~> 2.0` |

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
- **The Dependabot role pins `repository_id` and `repository_owner_id`, and
  wildcards only the end of `sub`.** GitHub does not document the subject a
  Dependabot update job carries; the job runs as the dynamic workflow
  `dynamic/dependabot/dependabot-updates` on the `target-branch`, with actor
  `dependabot[bot]`. IAM refuses a GitHub trust policy without a `sub`
  condition, so the role matches `<sub_claim_prefix>:*` and lets the immutable
  id claims carry the real check. CarModPicker still issues the legacy
  `repo:WebbPulse/CarModPicker` prefix, which is why each repository records
  its own. A refused assume shows up in this account's CloudTrail as
  `AssumeRoleWithWebIdentity`, with the token's subject in `userIdentity`.
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
- **Package groups come from `awscc`, not `aws`.** The `hashicorp/aws` provider has
  no package group resource (upstream issue 36528), so `awscc_codeartifact_package_group`
  goes through Cloud Control. `awscc` has no `default_tags`; the tags are passed
  explicitly. A `BLOCK` on a group always wins over a package's own origin control.
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
    ├── versions.tf        required_version and providers; the runner writes the backend
    ├── providers.tf       the aws provider and its default tags, and awscc
    ├── variables.tf       aws_region and environment
    ├── locals.tf          the prefix, common tags, the publisher policy statements, and the Dependabot repositories
    ├── data.tf            caller identity and region
    ├── codeartifact.tf    the domain, its five repositories, and the first-party package groups
    ├── ecr.tf             the base image repository and its policy
    ├── iam_publishers.tf  the three GitHub OIDC publisher roles
    ├── iam_dependabot.tf  the read-only CodeArtifact role Dependabot assumes through OIDC
    ├── management.tf      the resource group, anomaly detection and budgets
    └── outputs.tf         ARNs, ids, and the rendered consumer policy
```
