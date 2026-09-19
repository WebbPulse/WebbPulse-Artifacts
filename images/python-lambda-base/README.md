# python-lambda-base

The base layer every per-domain FastAPI Lambda is built on: Python 3.13, the Lambda
Web Adapter, and the non-root `app` user. It carries no `webbpulse` package and no
application dependencies, has no `ENTRYPOINT` and no `CMD`. See the repository
[README](../../README.md) for how it is published and pinned.

## Why there is no builder image or builder stage

The three product backends (`CarModPicker/backend`, `Standupless/backend`,
`WebbPulse-Terraform/backend`) have byte-identical builder stages: same
`ARG BASE_IMAGE`, same digest-pinned `uv`, same `UV_*` environment, and the same
two-layer install — a locked `uv sync` that excludes `webbpulse`, then a
CodeArtifact-authenticated `uv lock --upgrade-package webbpulse` and `uv sync`.

That duplication is deliberate. Publishing a second `python-lambda-builder` image,
or a `builder` target of this one, was evaluated and rejected for three reasons.

**It would defeat the base image cache.** `WebbPulse/.github/actions/base-image-cache`
reads a single reference out of the Dockerfile:

```
sed -n 's/^[[:space:]]*ARG[[:space:]][[:space:]]*BASE_IMAGE=\(.*\)$/\1/p' "$DOCKERFILE" | head -n 1
```

It emits one `<reference>=oci-layout://<dir>@<digest>` build context. A product
pinning a builder image as well as this one gets a cache entry for the first and a
registry pull for the second, on every domain of every build. Nine domains in
CarModPicker means nine extra cross-account ECR pulls per deploy, to remove lines
that do not change between deploys.

**`ONBUILD` cannot express the install.** `ONBUILD` triggers run as part of the
child's `FROM`, before any instruction in the child stage. The install needs
`pyproject.toml` and `uv.lock` in the build context, which the child copies in
*after* `FROM`. An `ONBUILD RUN` would resolve against an empty `/build`. Ordering
the child as `COPY` then `RUN <script>` works, but then the trigger is doing
nothing and the shared artifact is only a shell script.

**It would move the fresh-dependencies cache key out of the product.** In each
product Dockerfile `ARG DEPENDENCY_RESOLUTION` sits immediately above the
CodeArtifact `RUN`, so a changed stamp invalidates that layer and leaves the locked
`uv sync` above it cached. The stamp is resolved per build and per environment by
the product's own `deploy-backend.yml`, from the currently deployed version, and a
manual redeploy passing `fresh-dependencies` forces a new one. The base image is
immutable and shared across products and environments, so it cannot own a key with
those semantics. A product would still have to declare the `ARG`, still mount
`codeartifact_token` itself, and would additionally depend on a script whose layer
invalidation behaviour now lives behind a digest bump in another repository.

What is actually shared here — a pinned `uv`, a set of `UV_*` values, a two-layer
install — is already documented, and is stable precisely because it is boring. The
cost of the duplication is re-reading 38 identical lines. The cost of removing it is
slower builds, a weaker cache, and a build-arg contract split across two repositories.

Revisit this if `base-image-cache` learns to serve more than one reference and the
fresh-dependencies stamp stops being per-product.
