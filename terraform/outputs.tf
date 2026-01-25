# Outputs for Dev Workstation Module

output "instance_id" {
  description = "ID of the EC2 instance"
  value       = local.instance_id
}

output "private_ip" {
  description = "Private IP address of the instance"
  value       = local.instance_private_ip
}

output "public_ip" {
  description = "Public IP address of the instance (if assigned)"
  value       = var.create_eip ? aws_eip.workstation[0].public_ip : local.instance_public_ip
}

output "elastic_ip" {
  description = "Elastic IP address (if created)"
  value       = var.create_eip ? aws_eip.workstation[0].public_ip : null
}

output "security_group_id" {
  description = "ID of the security group"
  value       = aws_security_group.workstation.id
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to the instance"
  value       = var.create_instance_profile ? aws_iam_role.workstation[0].arn : null
}

output "iam_instance_profile_arn" {
  description = "ARN of the instance profile"
  value       = var.create_instance_profile ? aws_iam_instance_profile.workstation[0].arn : null
}

output "ami_id" {
  description = "AMI ID used for the instance"
  value       = local.ami_id
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = aws_launch_template.workstation.id
}

# SSH Key Pair Outputs
output "key_pair_name" {
  description = "Name of the SSH key pair used"
  value       = local.effective_key_name
}

output "private_key_pem" {
  description = "Private key in PEM format (only if create_key_pair is true). Save this to a file with chmod 600"
  value       = var.create_key_pair ? tls_private_key.ssh[0].private_key_openssh : null
  sensitive   = true
}

output "public_key_openssh" {
  description = "Public key in OpenSSH format (only if create_key_pair is true)"
  value       = var.create_key_pair ? tls_private_key.ssh[0].public_key_openssh : null
}

output "dcv_url" {
  description = "URL for NICE DCV connection (requires EIP or public IP)"
  value       = var.install_dcv && local.instance_public_ip != null ? "https://${var.create_eip ? aws_eip.workstation[0].public_ip : local.instance_public_ip}:8443" : null
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = local.effective_key_name != null && local.instance_public_ip != null ? "ssh -i ~/.ssh/${local.effective_key_name}.pem ubuntu@${var.create_eip ? aws_eip.workstation[0].public_ip : local.instance_public_ip}" : "Use SSM Session Manager (no SSH key configured)"
}

output "ssm_command" {
  description = "AWS SSM Session Manager command to connect"
  value       = local.instance_id != null ? "aws ssm start-session --target ${local.instance_id}" : null
}

output "connection_info" {
  description = "Connection information for the workstation"
  value = {
    instance_id  = local.instance_id
    public_ip    = var.create_eip ? aws_eip.workstation[0].public_ip : local.instance_public_ip
    private_ip   = local.instance_private_ip
    key_pair     = local.effective_key_name
    dcv_url      = var.install_dcv && local.instance_public_ip != null ? "https://${var.create_eip ? aws_eip.workstation[0].public_ip : local.instance_public_ip}:8443" : null
    ssh          = local.effective_key_name != null && local.instance_public_ip != null ? "ssh -i ~/.ssh/${local.effective_key_name}.pem ubuntu@${var.create_eip ? aws_eip.workstation[0].public_ip : local.instance_public_ip}" : "Use SSM Session Manager"
    ssm          = local.instance_id != null ? "aws ssm start-session --target ${local.instance_id}" : null
    notes        = var.install_dcv ? "Default DCV session: dev-session, username: ubuntu. Change the default password!" : null
    save_ssh_key = var.create_key_pair ? "Run: terragrunt output -raw private_key_pem > ~/.ssh/${local.effective_key_name}.pem && chmod 600 ~/.ssh/${local.effective_key_name}.pem" : null
  }
}

# Spot Instance Outputs
output "is_spot_instance" {
  description = "Whether this is a spot instance"
  value       = var.use_spot_instance
}

output "spot_instance_info" {
  description = "Spot instance configuration"
  value = var.use_spot_instance ? {
    instance_type         = var.instance_type
    interruption_behavior = var.spot_interruption_behavior
    note                  = "Instance will ${var.spot_interruption_behavior} if AWS reclaims capacity. You can stop/start this instance normally."
  } : null
}

# Auto-Stop Outputs
output "auto_stop_enabled" {
  description = "Whether auto-stop is enabled"
  value       = var.enable_auto_stop
}

output "auto_stop_info" {
  description = "Auto-stop configuration"
  value = var.enable_auto_stop ? {
    notify_after_hours = var.notify_after_hours
    stop_after_hours   = var.stop_after_hours
    check_interval     = "${var.auto_stop_check_interval} minutes"
    ntfy_topic         = var.notification_topic
    lambda_arn         = aws_lambda_function.auto_stop[0].arn
  } : null
}

output "instance_commands" {
  description = "Helpful CLI commands for managing the instance"
  value = {
    stop_instance  = local.instance_id != null ? "aws ec2 stop-instances --instance-ids ${local.instance_id}" : null
    start_instance = local.instance_id != null ? "aws ec2 start-instances --instance-ids ${local.instance_id}" : null
    defer_autostop = local.instance_id != null ? "aws ec2 create-tags --resources ${local.instance_id} --tags Key=AutoStopDeferHours,Value=2" : null
    reset_timer    = local.instance_id != null ? "# Stop then start to reset the auto-stop timer completely" : null
  }
}
