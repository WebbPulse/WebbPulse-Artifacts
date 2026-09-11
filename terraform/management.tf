module "app_baseline" {
  source  = "app.terraform.io/WebbPulse/platform-modules/aws//modules/app-baseline"
  version = "~> 2.0"

  name                = local.prefix
  notification_emails = ["tyler@webbpulse.com"]

  resource_group_description = "All WebbPulse Artifacts managed resources"
  resource_group_tag_filters = {
    Project = [local.project]
  }

  budgets = {
    "monthly-warn"     = { limit_amount = "10" }
    "monthly-critical" = { limit_amount = "25" }
  }
}
