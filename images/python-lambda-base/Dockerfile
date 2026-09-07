# syntax=docker/dockerfile:1.7
#
# webbpulse/python-lambda-base
#
# The base layer every per-domain WebbPulse FastAPI Lambda is built FROM. It holds the Python
# runtime and the AWS Lambda Web Adapter, and deliberately nothing else: no webbpulse package, no
# application dependencies. Those install in each application's own build, so bumping a shared
# package or an application requirement never requires a base rebuild, and this image only changes
# when the runtime or the adapter does.
#
# Built and pushed as a multi-architecture manifest for linux/amd64 and linux/arm64, because
# CarModPicker builds x86_64 Lambdas and Portfolio builds arm64. Lambda refuses an OCI index only
# for the image it pulls for a function, not for the parent an application image is built FROM, so
# a multi-arch base is safe: each application build resolves the one manifest matching its own
# --platform and produces a single-platform image of its own.

# python:3.13-slim, pinned by digest so a rebuild of this file is reproducible.
#
# To bump: read the current index digest and replace the one below.
#   curl -s "https://public.ecr.aws/token/?scope=repository:docker/library/python:pull&service=public.ecr.aws" \
#     | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])'
#   curl -sI -H "Authorization: Bearer <token>" \
#     -H "Accept: application/vnd.oci.image.index.v1+json" \
#     https://public.ecr.aws/v2/docker/library/python/manifests/3.13-slim \
#     | grep -i docker-content-digest
# The digest must be the one on the index, not on a per-platform manifest, or the build stops being
# multi-architecture. Public ECR mirrors Docker Hub's official images, so this is the same content
# as docker.io/library/python:3.13-slim without Docker Hub's anonymous pull rate limit.
FROM public.ecr.aws/docker/library/python:3.13-slim@sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285

# The AWS Lambda Web Adapter, copied in as a Lambda extension. It runs beside the function, receives
# the Lambda invoke, and proxies it to the HTTP server the application starts on AWS_LWA_PORT, which
# is what lets an ordinary uvicorn process serve Lambda traffic unchanged.
#
# Bump the same way, reading the index digest of the tag:
#   https://public.ecr.aws/v2/awsguru/aws-lambda-adapter/manifests/1.0.1
# The adapter image is itself a multi-architecture manifest, so this COPY resolves to the binary
# matching the platform currently being built and no per-architecture branching is needed.
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1@sha256:1e5ab4d9242167500ed8a7bed8a79b448228aaa51cf382fb51fe4bf8a5f9a811 \
     /lambda-adapter /opt/extensions/lambda-adapter

# The port the adapter proxies to, and the port the application must listen on. Both names are set
# because the adapter reads AWS_LWA_PORT while most frameworks and Uvicorn wrappers read PORT, and
# an application that binds one while the adapter polls the other hangs on every invoke rather than
# failing loudly.
ENV AWS_LWA_PORT=8080 \
    PORT=8080

# AWS_LWA_READINESS_CHECK_PATH is deliberately not set here. It is an application decision: the
# adapter blocks the first invoke until that path answers, so the path has to be one the application
# actually serves and one that does no I/O. Each entrypoint sets it, normally to /health.

# A non-root working directory convention. Application builds COPY their code into /app and install
# their dependencies against this same layout, so every WebbPulse Lambda image has the same shape.
# Lambda does not require a non-root user and gives each function its own container, but running as
# one keeps the image honest for local runs and for anything that scans it.
RUN groupadd --system --gid 1000 app \
    && useradd --system --uid 1000 --gid app --create-home --home-dir /home/app app \
    && mkdir -p /app \
    && chown -R app:app /app

WORKDIR /app
USER app

# No ENTRYPOINT or CMD. This image never runs on its own: every application image sets its own CMD
# to the entrypoint module for the domain it serves.
