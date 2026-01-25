# EC2 Resources
# Instance, security group, SSH key, and related networking

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

# Launch Template
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

# Instance details for outputs
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
