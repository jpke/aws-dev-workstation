# Auto-Stop System
# Lambda function, EventBridge, and CloudWatch for automatic instance shutdown
# Uses ntfy.sh for push notifications

# =============================================================================
# IAM for Lambda
# =============================================================================

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

# =============================================================================
# Lambda Function
# =============================================================================

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

# =============================================================================
# CloudWatch & EventBridge
# =============================================================================

resource "aws_cloudwatch_log_group" "auto_stop_lambda" {
  count             = var.enable_auto_stop ? 1 : 0
  name              = "/aws/lambda/${var.name}-auto-stop"
  retention_in_days = 7

  tags = local.common_tags
}

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
