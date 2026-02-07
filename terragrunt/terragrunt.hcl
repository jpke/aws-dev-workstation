# Dev Workstation Terragrunt Configuration
#
# This is an example configuration. Copy this file and customize for your environment.
#
# Prerequisites:
# - AWS credentials configured (via environment variables or AWS profile)
# - Terraform >= 1.0
# - Terragrunt >= 0.50
#
# Usage:
#   terragrunt init
#   terragrunt plan
#   terragrunt apply

locals {
  # Customize these values for your environment
  aws_region = "us-east-1"
}

terraform {
  source = "../terraform"
}

# Configure remote state (optional - remove this block to use local state)
# remote_state {
#   backend = "s3"
#   config = {
#     bucket  = "your-terraform-state-bucket"
#     key     = "dev-workstation/terraform.tfstate"
#     region  = local.aws_region
#     encrypt = true
#   }
#
#   generate = {
#     path      = "backend.tf"
#     if_exists = "overwrite_terragrunt"
#   }
# }

# Generate provider configuration
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  # Optional: assume role for cross-account deployment
  # assume_role {
  #   role_arn     = "arn:aws:iam::ACCOUNT_ID:role/YourRole"
  #   session_name = "TerragruntDevWorkstation"
  # }
}

# TLS provider for SSH key generation
provider "tls" {}
EOF
}

inputs = {
  # ============================================================================
  # REQUIRED: Customize these for your environment
  # ============================================================================

  # Your public IP address for SSH/DCV access
  # Find your IP at: https://checkip.amazonaws.com/
  allowed_ssh_cidrs = ["YOUR_IP_ADDRESS/32"]
  allowed_dcv_cidrs = ["YOUR_IP_ADDRESS/32"]

  # ============================================================================
  # Instance Configuration (adjust as needed)
  # ============================================================================

  name          = "dev-workstation"
  instance_type = "m7i-flex.large"  # x86_64 Intel Flex - 2 vCPU, 8GB RAM
  environment   = "development"

  # Storage Configuration
  root_volume_size       = 100
  root_volume_type       = "gp3"
  root_volume_iops       = 3000
  root_volume_throughput = 125

  # Network Configuration
  # Leave as null to use default VPC/subnet, or specify your own
  # subnet_id = "subnet-xxxxxxxxx"

  associate_public_ip = true
  create_eip          = false  # Set to true if you want a static IP (~$3.60/month)

  # SSH Key - Terraform will generate and manage the key pair
  # After apply, save the private key with:
  # terragrunt output -raw private_key_pem > ~/.ssh/dev-workstation-key.pem && chmod 600 ~/.ssh/dev-workstation-key.pem
  create_key_pair = true

  # Web development ports (React, Vite, etc.)
  enable_web_dev_ports = true
  web_dev_cidrs        = ["YOUR_IP_ADDRESS/32"]

  # ============================================================================
  # Software Installation
  # ============================================================================

  install_desktop = true   # Minimal Ubuntu desktop
  install_dcv     = true   # NICE DCV for remote access
  install_chrome  = true   # Chrome/Chromium for testing
  install_docker  = true   # Docker for containerized dev
  install_nodejs  = true   # Node.js LTS + pnpm + yarn

  # ============================================================================
  # Tailscale (zero-trust network access)
  # ============================================================================

  # Tailscale provides SSH, DCV, and all ports over a private WireGuard mesh.
  # When enabled with DCV, it auto-provisions TLS certs (no browser warnings).
  # Generate an auth key at: https://login.tailscale.com/admin/settings/keys

  install_tailscale  = false
  # tailscale_auth_key = "tskey-auth-XXXX"  # Sensitive - use SOPS or env vars

  # Enable port 443 redirect for DCV (useful with Tailscale where traffic bypasses SGs)
  enable_dcv_port_443 = false

  # ============================================================================
  # IAM Configuration
  # ============================================================================

  create_instance_profile = true
  additional_iam_policies = [
    # Add any additional policies your dev work needs, e.g.:
    # "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess",
    # "arn:aws:iam::aws:policy/AmazonDynamoDBReadOnlyAccess",
  ]

  # ============================================================================
  # Spot Instance Configuration
  # ============================================================================

  # Use spot instances to save ~60-70% vs on-demand
  # Tradeoff: AWS can reclaim capacity (instance stops, but EBS volume preserved)
  use_spot_instance          = true
  spot_interruption_behavior = "stop"

  # ============================================================================
  # Scheduled Start/Stop (EventBridge Scheduler)
  # ============================================================================

  # Automatically start and stop the instance on a schedule.
  # Uses EventBridge Scheduler with native IANA timezone support.

  enable_scheduled_start = false
  schedule_timezone      = "America/New_York"

  # Example: 3 work windows per day, 3 hours each
  # schedule_start_expressions = [
  #   "cron(0 7 ? * MON-FRI *)",   # 7:00 AM ET weekdays
  #   "cron(0 12 ? * MON-FRI *)",  # 12:00 PM ET weekdays
  #   "cron(0 17 ? * MON-FRI *)",  # 5:00 PM ET weekdays
  # ]
  # schedule_stop_expressions = [
  #   "cron(0 10 ? * MON-FRI *)",  # 10:00 AM ET weekdays
  #   "cron(0 15 ? * MON-FRI *)",  # 3:00 PM ET weekdays
  #   "cron(0 20 ? * MON-FRI *)",  # 8:00 PM ET weekdays
  # ]

  # ============================================================================
  # Auto-Stop Fail-Safe (prevents runaway costs)
  # ============================================================================

  # Safety net: stops instance if it runs longer than expected.
  # Works as a fail-safe in case scheduled stops fail or manual starts are forgotten.

  enable_auto_stop         = true
  stop_after_hours         = 4     # Fail-safe stop at 4 hours
  auto_stop_check_interval = 60    # Check every hour

  # Optional: ntfy.sh topic for push notifications
  # Sign up at https://ntfy.sh/ and create a topic
  # notification_topic = "your-ntfy-topic"

  # ============================================================================
  # SQS Task Queue
  # ============================================================================

  # Queue tasks for the workstation even when the instance is off.
  # Messages persist for 14 days. The instance consumes them on startup.

  enable_task_queue = false

  # ============================================================================
  # Tags
  # ============================================================================

  tags = {
    Environment = "development"
    Project     = "DevWorkstation"
    Purpose     = "Remote Development Environment"
    ManagedBy   = "Terraform"
  }
}
