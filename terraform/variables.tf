# Variables for Dev Workstation EC2 Module

variable "aws_region" {
  description = "AWS region for the EC2 instance"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string
  default     = "development"
}

variable "name" {
  description = "Name prefix for resources"
  type        = string
  default     = "dev-workstation"
}

# Instance Configuration
variable "instance_type" {
  description = "EC2 instance type (x86_64 recommended: m7i.xlarge)"
  type        = string
  default     = "m7i.xlarge"
}

variable "ami_id" {
  description = "AMI ID for the instance. If not provided, latest Ubuntu 24.04 LTS x86_64 will be used"
  type        = string
  default     = null
}

variable "key_name" {
  description = "Name of an existing SSH key pair for EC2 access. If null and create_key_pair is true, a new key pair will be generated"
  type        = string
  default     = null
}

variable "create_key_pair" {
  description = "Whether to create a new SSH key pair. The private key will be available in outputs"
  type        = bool
  default     = false
}

# Storage Configuration
variable "root_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 100
}

variable "root_volume_type" {
  description = "Type of the root EBS volume (gp3, gp2, io1, io2)"
  type        = string
  default     = "gp3"
}

variable "root_volume_iops" {
  description = "IOPS for the root volume (only for gp3, io1, io2)"
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "Throughput for the root volume in MB/s (only for gp3)"
  type        = number
  default     = 125
}

variable "delete_on_termination" {
  description = "Whether to delete the root volume on instance termination"
  type        = bool
  default     = true
}

# Network Configuration
variable "vpc_id" {
  description = "VPC ID where the instance will be launched. If null, uses default VPC"
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Subnet ID where the instance will be launched. If null, uses default subnet"
  type        = string
  default     = null
}

variable "associate_public_ip" {
  description = "Whether to associate a public IP address"
  type        = bool
  default     = true
}

variable "create_eip" {
  description = "Whether to create and associate an Elastic IP"
  type        = bool
  default     = false
}

# Security Group Configuration
variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed SSH access"
  type        = list(string)
  default     = []
}

variable "allowed_dcv_cidrs" {
  description = "List of CIDR blocks allowed NICE DCV access (port 8443)"
  type        = list(string)
  default     = []
}

variable "enable_web_dev_ports" {
  description = "Whether to open common web development ports (3000, 5173, 8080)"
  type        = bool
  default     = false
}

variable "web_dev_cidrs" {
  description = "List of CIDR blocks allowed access to web dev ports"
  type        = list(string)
  default     = []
}

# IAM Configuration
variable "create_instance_profile" {
  description = "Whether to create an IAM instance profile with SSM access"
  type        = bool
  default     = true
}

variable "additional_iam_policies" {
  description = "List of additional IAM policy ARNs to attach to the instance role"
  type        = list(string)
  default     = []
}

# User Data Configuration
variable "user_data" {
  description = "Custom user data script. If null, uses default setup script"
  type        = string
  default     = null
}

variable "install_dcv" {
  description = "Whether to install NICE DCV in the default user data"
  type        = bool
  default     = true
}

variable "install_desktop" {
  description = "Whether to install a minimal desktop environment"
  type        = bool
  default     = true
}

variable "install_chrome" {
  description = "Whether to install Google Chrome"
  type        = bool
  default     = true
}

variable "install_docker" {
  description = "Whether to install Docker"
  type        = bool
  default     = true
}

variable "install_nodejs" {
  description = "Whether to install Node.js LTS"
  type        = bool
  default     = true
}

# Spot Instance Configuration
variable "use_spot_instance" {
  description = "Whether to use a spot instance instead of on-demand"
  type        = bool
  default     = false
}

variable "spot_instance_types" {
  description = "List of instance types for spot fleet (all must be x86_64). First type is preferred."
  type        = list(string)
  default = [
    "m7i.xlarge", # Primary: 4 vCPU, 16GB - latest gen Intel general purpose
    "m7a.xlarge", # Fallback: 4 vCPU, 16GB - latest gen AMD general purpose
    "m6i.xlarge", # Fallback: 4 vCPU, 16GB - previous gen Intel
    "m6a.xlarge", # Fallback: 4 vCPU, 16GB - previous gen AMD
    "c7i.xlarge", # Fallback: 4 vCPU, 8GB - compute optimized (less RAM but good for builds)
  ]
}

variable "spot_allocation_strategy" {
  description = "Spot allocation strategy: capacityOptimized (minimize interruptions), lowestPrice, diversified, or priceCapacityOptimized"
  type        = string
  default     = "capacityOptimized"

  validation {
    condition     = contains(["capacityOptimized", "lowestPrice", "diversified", "capacityOptimizedPrioritized", "priceCapacityOptimized"], var.spot_allocation_strategy)
    error_message = "spot_allocation_strategy must be one of: capacityOptimized, capacityOptimizedPrioritized, lowestPrice, diversified, priceCapacityOptimized"
  }
}

variable "spot_interruption_behavior" {
  description = "Behavior when spot instance is interrupted: stop or terminate"
  type        = string
  default     = "stop"

  validation {
    condition     = contains(["stop", "terminate"], var.spot_interruption_behavior)
    error_message = "spot_interruption_behavior must be 'stop' or 'terminate'"
  }
}

# Auto-Stop Configuration
variable "enable_auto_stop" {
  description = "Whether to enable automatic instance stopping and notifications"
  type        = bool
  default     = false
}

variable "notify_after_hours" {
  description = "Send notification after instance has been running this many hours"
  type        = number
  default     = 5
}

variable "stop_after_hours" {
  description = "Automatically stop instance after it has been running this many hours"
  type        = number
  default     = 8
}

variable "notification_topic" {
  description = "ntfy.sh topic for push notifications (e.g., 'my-alerts')"
  type        = string
  default     = null
}

variable "auto_stop_check_interval" {
  description = "How often (in minutes) to check instance runtime"
  type        = number
  default     = 15
}

# Tags
variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
