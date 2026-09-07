# Base image repositories. The per-domain FastAPI Lambdas ship as OCI images, and the base layer
# they are all built on belongs here rather than in any one application's account: four accounts
# building against one base image is one repository to scan and one image to patch, not four.
#
# One repository to start with. A second base image is one more entry in the map.
module "ecr" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/ecr-repository"
  version = "~> 2.0"

  # The repository comes out as "webbpulse/python-lambda-base". A slash reads as a namespace and the
  # console groups on it, so every shared base image sorts together.
  name_prefix = "webbpulse"

  repositories = {
    "python-lambda-base" = {
      description = "Base image for the per-domain FastAPI Lambdas"
    }
  }

  # Immutable tags are the point of a base image: a tag that cannot be moved is what makes a build
  # reproducible, and what makes the digest a consumer records mean something a month later. It also
  # rules out a floating "latest", so consumers pin an explicit tag or a digest.
  image_tag_mutability = "IMMUTABLE"

  # Cross-account pulls need both sides to allow. This is the registry owner's half: the module
  # writes a pull statement for these accounts plus a second statement letting lambda.amazonaws.com
  # retrieve the image on behalf of a function in one of them, which is what keeps a container image
  # Lambda alive when Lambda re-fetches the image after an optimisation pass. Each consumer account
  # still grants the matching actions on its own role.
  #
  # Lambda cannot pull an image across regions, so a consumer function has to run in us-west-2.
  repository_policy_principals = [for id in local.consumer_account_ids : "arn:aws:iam::${id}:root"]

  # The module default keeps the last 10 images tagged "sha-" and expires untagged images after a
  # day. A base image four accounts build against wants deeper rollback headroom than a deployable
  # does, and the storage is pennies. The prefix list covers both tag schemes a base image plausibly
  # carries: a commit sha, and a Python version series. A tagged image matching no prefix here is
  # never expired, which fails safe.
  keep_last_tagged_images    = 30
  expire_untagged_after_days = 7
  tag_prefix_list            = ["sha-", "py"]

  # A destroy must not be able to take the images with it while anything still builds against them.
  force_delete = false
}
