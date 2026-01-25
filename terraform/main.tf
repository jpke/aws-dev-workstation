# Dev Workstation EC2 Module
# Provides a remote development environment with NICE DCV, minimal desktop, and dev tools

data "aws_region" "current" {}

# Get the default VPC if not specified
data "aws_vpc" "default" {
  count   = var.vpc_id == null ? 1 : 0
  default = true
}

# Get default subnet if not specified
data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Get latest Ubuntu 24.04 LTS x86_64 AMI if not specified
data "aws_ami" "ubuntu" {
  count       = var.ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  vpc_id    = var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.default[0].ids[0]
  ami_id    = var.ami_id != null ? var.ami_id : data.aws_ami.ubuntu[0].id

  # Use provided key_name, or generated key if create_key_pair is true
  effective_key_name = var.key_name != null ? var.key_name : (var.create_key_pair ? aws_key_pair.generated[0].key_name : null)

  common_tags = merge(var.tags, {
    Name        = var.name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Purpose     = "Development Workstation"
  })
}

# Generate SSH key pair if requested
resource "tls_private_key" "ssh" {
  count     = var.create_key_pair ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "generated" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = "${var.name}-key"
  public_key = tls_private_key.ssh[0].public_key_openssh

  tags = merge(local.common_tags, {
    Name = "${var.name}-key"
  })
}

# Security Group
resource "aws_security_group" "workstation" {
  name        = "${var.name}-sg"
  description = "Security group for dev workstation"
  vpc_id      = local.vpc_id

  # SSH access
  dynamic "ingress" {
    for_each = length(var.allowed_ssh_cidrs) > 0 ? [1] : []
    content {
      description = "SSH access"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidrs
    }
  }

  # NICE DCV access (HTTPS port 8443)
  dynamic "ingress" {
    for_each = length(var.allowed_dcv_cidrs) > 0 ? [1] : []
    content {
      description = "NICE DCV access"
      from_port   = 8443
      to_port     = 8443
      protocol    = "tcp"
      cidr_blocks = var.allowed_dcv_cidrs
    }
  }

  # Web development ports
  dynamic "ingress" {
    for_each = var.enable_web_dev_ports && length(var.web_dev_cidrs) > 0 ? [3000, 5173, 8080] : []
    content {
      description = "Web dev port ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.web_dev_cidrs
    }
  }

  # Allow all outbound traffic
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# IAM Role for the instance
resource "aws_iam_role" "workstation" {
  count = var.create_instance_profile ? 1 : 0

  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# SSM managed policy for Session Manager access
resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.create_instance_profile ? 1 : 0
  role       = aws_iam_role.workstation[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# NICE DCV license policy (required for DCV)
resource "aws_iam_role_policy" "dcv_license" {
  count = var.create_instance_profile && var.install_dcv ? 1 : 0
  name  = "${var.name}-dcv-license"
  role  = aws_iam_role.workstation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "arn:aws:s3:::dcv-license.${data.aws_region.current.name}/*"
      }
    ]
  })
}

# Additional IAM policies
resource "aws_iam_role_policy_attachment" "additional" {
  count      = var.create_instance_profile ? length(var.additional_iam_policies) : 0
  role       = aws_iam_role.workstation[0].name
  policy_arn = var.additional_iam_policies[count.index]
}

# Instance profile
resource "aws_iam_instance_profile" "workstation" {
  count = var.create_instance_profile ? 1 : 0
  name  = "${var.name}-profile"
  role  = aws_iam_role.workstation[0].name

  tags = local.common_tags
}

# User data script for setting up the development environment
locals {
  default_user_data = <<-EOF
#!/bin/bash
set -e

# Log all output
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "Starting dev workstation setup..."

# Update system
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install essential packages
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    vim \
    htop \
    unzip \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common

%{if var.install_desktop}
echo "Installing minimal desktop environment..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ubuntu-desktop-minimal \
    gdm3

# Disable Wayland (required for NICE DCV) and use X11
echo "WaylandEnable=false" >> /etc/gdm3/custom.conf
echo "DefaultSession=ubuntu.desktop" >> /etc/gdm3/custom.conf

# Set GDM to auto-login (will be configured later for DCV user)
systemctl set-default graphical.target
%{endif}

%{if var.install_chrome}
echo "Installing Google Chrome..."
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-archive-keyring.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
%{endif}

%{if var.install_docker}
echo "Installing Docker..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker ubuntu
%{endif}

%{if var.install_nodejs}
echo "Installing Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
# Install pnpm and yarn globally
npm install -g pnpm yarn
%{endif}

%{if var.install_dcv}
echo "Installing NICE DCV..."
# Install DCV prerequisites
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    mesa-utils \
    xserver-xorg-core

# Download and install NICE DCV (x86_64 version)
cd /tmp
wget https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-ubuntu2404-x86_64.tgz
tar -xzf nice-dcv-ubuntu2404-x86_64.tgz
cd nice-dcv-*-x86_64

# Install DCV server
DEBIAN_FRONTEND=noninteractive apt-get install -y ./nice-dcv-server_*.deb
DEBIAN_FRONTEND=noninteractive apt-get install -y ./nice-dcv-web-viewer_*.deb
DEBIAN_FRONTEND=noninteractive apt-get install -y ./nice-xdcv_*.deb || true

# Configure DCV
cat > /etc/dcv/dcv.conf <<DCVCONF
[license]
license-file = ""

[log]
level = "info"

[session-management]
virtual-session-xdcv-args = ""

[session-management/defaults]
permissions-file = ""

[session-management/automatic-console-session]
owner = "ubuntu"
storage-root = "/home/ubuntu"

[display]
target-fps = 60

[connectivity]
enable-quic-frontend = true
web-port = 8443
web-url-path = "/"
DCVCONF

# Enable and start DCV
systemctl enable dcvserver
systemctl start dcvserver || true

# Create a virtual session for the ubuntu user
dcv create-session --type=virtual --owner ubuntu --storage-root /home/ubuntu dev-session || true

# Set password for ubuntu user (for DCV authentication)
# IMPORTANT: Change this password after first login!
echo "ubuntu:CHANGE_ME_IMMEDIATELY" | chpasswd

echo "NICE DCV installation complete. Default session 'dev-session' created."
echo "IMPORTANT: Change the default password for user 'ubuntu'!"
%{endif}

# Install AWS CLI v2 (x86_64)
echo "Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Install Claude Code dependencies (will need manual installation of Claude Code itself)
echo "Installing development tools..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3-pip \
    python3-venv

# Clean up
apt-get autoremove -y
apt-get clean

echo "Dev workstation setup complete!"
echo "Please change the ubuntu user password after first login."
EOF

  user_data = var.user_data != null ? var.user_data : local.default_user_data
}

# =============================================================================
# EC2 Instance Configuration
# =============================================================================

# Launch Template (used by both spot fleet and on-demand)
resource "aws_launch_template" "workstation" {
  name = "${var.name}-lt"

  image_id      = local.ami_id
  key_name      = local.effective_key_name
  user_data     = base64encode(local.user_data)

  iam_instance_profile {
    name = var.create_instance_profile ? aws_iam_instance_profile.workstation[0].name : null
  }

  network_interfaces {
    associate_public_ip_address = var.associate_public_ip
    security_groups             = [aws_security_group.workstation.id]
    subnet_id                   = local.subnet_id
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = var.root_volume_type
      iops                  = var.root_volume_type == "gp3" || startswith(var.root_volume_type, "io") ? var.root_volume_iops : null
      throughput            = var.root_volume_type == "gp3" ? var.root_volume_throughput : null
      encrypted             = true
      delete_on_termination = var.delete_on_termination
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.common_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${var.name}-root-volume"
    })
  }

  tags = local.common_tags
}

# EC2 Instance (works for both on-demand and spot)
resource "aws_instance" "workstation" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = local.effective_key_name
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.workstation.id]
  iam_instance_profile   = var.create_instance_profile ? aws_iam_instance_profile.workstation[0].name : null
  user_data              = local.user_data

  # Spot instance configuration (only when use_spot_instance is true)
  dynamic "instance_market_options" {
    for_each = var.use_spot_instance ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        instance_interruption_behavior = var.spot_interruption_behavior
        spot_instance_type             = "persistent"
      }
    }
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    iops                  = var.root_volume_type == "gp3" || startswith(var.root_volume_type, "io") ? var.root_volume_iops : null
    throughput            = var.root_volume_type == "gp3" ? var.root_volume_throughput : null
    encrypted             = true
    delete_on_termination = var.delete_on_termination
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  tags = merge(local.common_tags, {
    Name = var.name
  })

  volume_tags = merge(local.common_tags, {
    Name = "${var.name}-root-volume"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}

# Local to get the instance details for outputs
locals {
  instance_id         = aws_instance.workstation.id
  instance_public_ip  = aws_instance.workstation.public_ip
  instance_private_ip = aws_instance.workstation.private_ip
}

# Elastic IP (optional)
resource "aws_eip" "workstation" {
  count  = var.create_eip ? 1 : 0
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.name}-eip"
  })
}

resource "aws_eip_association" "workstation" {
  count         = var.create_eip ? 1 : 0
  instance_id   = aws_instance.workstation.id
  allocation_id = aws_eip.workstation[0].id
}

# =============================================================================
# Auto-Stop and Notification System (uses ntfy.sh for push notifications)
# =============================================================================

# IAM Role for Lambda
resource "aws_iam_role" "auto_stop_lambda" {
  count = var.enable_auto_stop ? 1 : 0
  name  = "${var.name}-auto-stop-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM Policy for Lambda
resource "aws_iam_role_policy" "auto_stop_lambda" {
  count = var.enable_auto_stop ? 1 : 0
  name  = "${var.name}-auto-stop-lambda-policy"
  role  = aws_iam_role.auto_stop_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:StopInstances"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateTags"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda function code
locals {
  lambda_code = <<-PYTHON
import boto3
import os
import urllib.request
import urllib.error
from datetime import datetime, timezone

def send_ntfy(topic, title, message, priority="default", tags=None):
    """Send notification via ntfy.sh"""
    if not topic:
        print("No ntfy topic configured, skipping push notification")
        return False

    url = f"https://ntfy.sh/{topic}"
    headers = {
        "Title": title,
        "Priority": priority,
    }
    if tags:
        headers["Tags"] = tags

    try:
        req = urllib.request.Request(url, data=message.encode('utf-8'), headers=headers, method='POST')
        with urllib.request.urlopen(req, timeout=10) as response:
            print(f"ntfy notification sent: {response.status}")
            return True
    except urllib.error.URLError as e:
        print(f"Failed to send ntfy notification: {e}")
        return False

def lambda_handler(event, context):
    instance_id = os.environ['INSTANCE_ID']
    base_notify_hours = float(os.environ['NOTIFY_AFTER_HOURS'])
    base_stop_hours = float(os.environ['STOP_AFTER_HOURS'])
    instance_name = os.environ['INSTANCE_NAME']
    ntfy_topic = os.environ.get('NTFY_TOPIC', '')

    ec2 = boto3.client('ec2')

    # Get instance details
    response = ec2.describe_instances(InstanceIds=[instance_id])

    if not response['Reservations']:
        print(f"Instance {instance_id} not found")
        return {'statusCode': 404, 'body': 'Instance not found'}

    instance = response['Reservations'][0]['Instances'][0]
    state = instance['State']['Name']

    if state != 'running':
        print(f"Instance {instance_id} is {state}, not running. Skipping.")
        return {'statusCode': 200, 'body': f'Instance is {state}'}

    # Check tags
    tags = {tag['Key']: tag['Value'] for tag in instance.get('Tags', [])}
    notified = tags.get('AutoStopNotified', 'false') == 'true'

    # Check for defer tag - adds hours to thresholds
    defer_hours = 0
    try:
        defer_hours = float(tags.get('AutoStopDeferHours', '0'))
    except ValueError:
        defer_hours = 0

    notify_hours = base_notify_hours + defer_hours
    stop_hours = base_stop_hours + defer_hours

    if defer_hours > 0:
        print(f"Defer active: +{defer_hours} hours (notify at {notify_hours}h, stop at {stop_hours}h)")

    # Calculate runtime
    launch_time = instance['LaunchTime']
    now = datetime.now(timezone.utc)
    runtime_hours = (now - launch_time).total_seconds() / 3600

    print(f"Instance {instance_id} has been running for {runtime_hours:.2f} hours")

    # Stop if over stop threshold
    if runtime_hours >= stop_hours:
        print(f"Stopping instance {instance_id} after {runtime_hours:.2f} hours")
        ec2.stop_instances(InstanceIds=[instance_id])

        # Send stop notification via ntfy
        send_ntfy(
            ntfy_topic,
            f"Dev Workstation Stopped",
            f"Auto-stopped after {runtime_hours:.1f}h\n\nRestart: aws ec2 start-instances --instance-ids {instance_id}",
            priority="high",
            tags="octagonal_sign"
        )

        # Reset tags for next start
        ec2.create_tags(
            Resources=[instance_id],
            Tags=[
                {'Key': 'AutoStopNotified', 'Value': 'false'},
                {'Key': 'AutoStopDeferHours', 'Value': '0'}
            ]
        )

        return {'statusCode': 200, 'body': 'Instance stopped'}

    # Send notification if over notify threshold and not already notified
    if runtime_hours >= notify_hours and not notified:
        print(f"Sending notification for instance {instance_id}")
        remaining_hours = stop_hours - runtime_hours

        # Send warning notification via ntfy
        send_ntfy(
            ntfy_topic,
            f"Auto-stop in ~{remaining_hours:.0f}h",
            f"Running for {runtime_hours:.1f}h\n\nDefer 2h: aws ec2 create-tags --resources {instance_id} --tags Key=AutoStopDeferHours,Value=2\n\nStop now: aws ec2 stop-instances --instance-ids {instance_id}",
            priority="high",
            tags="warning"
        )

        # Tag instance as notified
        ec2.create_tags(
            Resources=[instance_id],
            Tags=[{'Key': 'AutoStopNotified', 'Value': 'true'}]
        )

        return {'statusCode': 200, 'body': 'Notification sent'}

    return {'statusCode': 200, 'body': 'No action needed'}
PYTHON
}

# Lambda function
data "archive_file" "auto_stop_lambda" {
  count       = var.enable_auto_stop ? 1 : 0
  type        = "zip"
  output_path = "${path.module}/auto_stop_lambda.zip"

  source {
    content  = local.lambda_code
    filename = "index.py"
  }
}

resource "aws_lambda_function" "auto_stop" {
  count            = var.enable_auto_stop ? 1 : 0
  filename         = data.archive_file.auto_stop_lambda[0].output_path
  source_code_hash = data.archive_file.auto_stop_lambda[0].output_base64sha256
  function_name    = "${var.name}-auto-stop"
  role             = aws_iam_role.auto_stop_lambda[0].arn
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30

  environment {
    variables = {
      INSTANCE_ID        = local.instance_id
      NOTIFY_AFTER_HOURS = tostring(var.notify_after_hours)
      STOP_AFTER_HOURS   = tostring(var.stop_after_hours)
      INSTANCE_NAME      = var.name
      NTFY_TOPIC         = var.notification_topic != null ? var.notification_topic : ""
    }
  }

  tags = local.common_tags
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "auto_stop_lambda" {
  count             = var.enable_auto_stop ? 1 : 0
  name              = "/aws/lambda/${var.name}-auto-stop"
  retention_in_days = 7

  tags = local.common_tags
}

# EventBridge rule to trigger Lambda periodically
resource "aws_cloudwatch_event_rule" "auto_stop_schedule" {
  count               = var.enable_auto_stop ? 1 : 0
  name                = "${var.name}-auto-stop-schedule"
  description         = "Trigger auto-stop check for dev workstation"
  schedule_expression = "rate(${var.auto_stop_check_interval} minutes)"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "auto_stop_lambda" {
  count     = var.enable_auto_stop ? 1 : 0
  rule      = aws_cloudwatch_event_rule.auto_stop_schedule[0].name
  target_id = "auto-stop-lambda"
  arn       = aws_lambda_function.auto_stop[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  count         = var.enable_auto_stop ? 1 : 0
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_stop[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.auto_stop_schedule[0].arn
}
