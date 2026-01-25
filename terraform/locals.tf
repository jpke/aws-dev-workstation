# Local Values
# Computed values used across the module

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
