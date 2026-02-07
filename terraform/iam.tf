# IAM Resources
# Role, policies, and instance profile for the EC2 instance

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

# SQS task queue consumer policy
resource "aws_iam_role_policy" "task_queue_consumer" {
  count = var.create_instance_profile && var.enable_task_queue ? 1 : 0
  name  = "${var.name}-task-queue-consumer"
  role  = aws_iam_role.workstation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = aws_sqs_queue.task_queue[0].arn
      }
    ]
  })
}

# Instance profile
resource "aws_iam_instance_profile" "workstation" {
  count = var.create_instance_profile ? 1 : 0
  name  = "${var.name}-profile"
  role  = aws_iam_role.workstation[0].name

  tags = local.common_tags
}
