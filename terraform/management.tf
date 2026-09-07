# Account level housekeeping: the tag based resource group, Cost Explorer anomaly detection and the
# free budget alerts, from the shared app-baseline module.
#
# The budgets are deliberately small. This account holds a package registry and an image registry
# and runs no workloads, so its real spend is a few dollars a month of CodeArtifact and ECR storage.
# A ten dollar warning is generous headroom rather than a tight bound, and the point of it is to
# catch something structurally wrong, such as a lifecycle policy that stopped pruning, long before
# the amount itself matters.
module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 2.0"

  name                = local.prefix
  notification_emails = ["tyler@webbpulse.com"]

  # Filter on the bare project tag, not on the prefix: no resource carries "artifacts-shared" as its
  # Project tag. Every resource in this root picks the tag up from provider default_tags.
  resource_group_description = "All WebbPulse Artifacts managed resources"
  resource_group_tag_filters = {
    Project = [local.project]
  }

  budgets = {
    "monthly-warn"     = { limit_amount = "10" }
    "monthly-critical" = { limit_amount = "25" }
  }
}
