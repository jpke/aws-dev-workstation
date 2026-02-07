# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-02-07

### Added

- **Tailscale integration**: Install Tailscale for zero-trust network access with `install_tailscale` and `tailscale_auth_key` variables. When enabled alongside DCV, auto-provisions TLS certificates via a systemd service that re-provisions on each boot (DCV overwrites its certs on restart).
- **Scheduled start/stop**: EventBridge Scheduler with native IANA timezone support. Configure multiple start/stop cron expressions via `schedule_start_expressions` and `schedule_stop_expressions`.
- **SQS task queue**: Optional SQS queue (`enable_task_queue`) for submitting work to the workstation while the instance is off. Messages persist for 14 days and the instance role has permissions to consume them on startup.
- **DCV port 443 redirect**: `enable_dcv_port_443` variable adds an iptables PREROUTING rule (443 → 8443) persisted with `iptables-persistent`. Useful with Tailscale where traffic bypasses security groups.
- **DCV virtual session systemd service**: `dcv-virtual-session.service` auto-creates a virtual DCV session on every boot, since DCV only supports auto-creating console sessions natively.
- **EC2 state-change tracking**: EventBridge rule fires when the instance transitions to `running`, triggering the Lambda to tag it with `LastStartedAt`. This ensures the auto-stop timer resets correctly across stop/start cycles (EC2 `LaunchTime` only resets on initial launch).
- **Dual-mode Lambda**: The auto-stop Lambda now handles both scheduled periodic checks and EC2 state-change events, routing based on `event.source`.
- **EventBridge Scheduler IAM**: Dedicated IAM role for `scheduler.amazonaws.com` with scoped `ec2:StartInstances` and `ec2:StopInstances` permissions.
- **New outputs**: `schedule_info`, `task_queue_url`, `task_queue_arn`, `send_task_command`.

### Changed

- **Downsized default instance type** in example terragrunt.hcl from `m7i.xlarge` (4 vCPU, 16 GB) to `m7i-flex.large` (2 vCPU, 8 GB).
- **Updated spot instance type defaults** from `.xlarge` tier to `.large` tier to match the downsized instance.
- **Auto-stop is now a fail-safe**: The Lambda acts as a safety net for scheduled stop failures rather than the primary stop mechanism. Notification message updated to indicate fail-safe behavior.
- **Runtime calculation uses `LastStartedAt` tag** instead of EC2 `LaunchTime`, with fallback to `LaunchTime` for backwards compatibility.
- **`stop_after_hours` default** changed from `8` to `4`.
- **`auto_stop_check_interval` default** changed from `15` to `60` minutes.
- **Lambda IAM policy** now includes `ec2:StartInstances` and uses wildcard log resource for simplicity.
- **DCV security group** split into two dynamic ingress blocks: port 443 (when `enable_dcv_port_443` is true) and port 8443 (when false).
- **README** rewritten with updated architecture diagram, Tailscale/scheduling/SQS documentation, HTTPS cert guide, and revised cost estimates.

### Removed

- **`notify_after_hours` variable**: Warning notifications removed. The Lambda now only notifies when it actually stops an instance (fail-safe trigger).
- **`NOTIFY_AFTER_HOURS` Lambda environment variable** and associated warning notification logic.
- **`AutoStopNotified` tag handling**: No longer needed since there is no separate warning step.

[Unreleased]: https://github.com/jpke/terraform-aws-dev-workstation/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jpke/terraform-aws-dev-workstation/releases/tag/v1.0.0
