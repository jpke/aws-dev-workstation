# Instance Lifecycle Management
# Auto-stop Lambda, EventBridge Scheduler for start/stop, state-change tracking, SQS task queue
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
          "ec2:StartInstances",
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
# Lambda Function (dual-mode: handles both scheduled checks and state changes)
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

def handle_state_change(event, ec2):
    """Handle EC2 state-change event: tag instance with LastStartedAt and reset auto-stop tags."""
    instance_id = event['detail']['instance-id']
    state = event['detail']['state']

    if state != 'running':
        print(f"State change to '{state}' - ignoring (only handle 'running')")
        return {'statusCode': 200, 'body': f'Ignoring state: {state}'}

    now = datetime.now(timezone.utc).isoformat()
    print(f"Instance {instance_id} started - tagging LastStartedAt={now}")

    ec2.create_tags(
        Resources=[instance_id],
        Tags=[
            {'Key': 'LastStartedAt', 'Value': now},
            {'Key': 'AutoStopDeferHours', 'Value': '0'},
        ]
    )

    return {'statusCode': 200, 'body': 'Tagged instance with start time'}

def lambda_handler(event, context):
    ec2 = boto3.client('ec2')

    # Route based on event source: EC2 state change vs scheduled check
    if event.get('source') == 'aws.ec2':
        return handle_state_change(event, ec2)

    # Fail-safe check: ensure instance isn't left running if scheduled stop fails
    instance_id = os.environ['INSTANCE_ID']
    base_stop_hours = float(os.environ['STOP_AFTER_HOURS'])
    instance_name = os.environ['INSTANCE_NAME']
    ntfy_topic = os.environ.get('NTFY_TOPIC', '')

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

    # Check for defer tag - adds hours to thresholds
    defer_hours = 0
    try:
        defer_hours = float(tags.get('AutoStopDeferHours', '0'))
    except ValueError:
        defer_hours = 0

    stop_hours = base_stop_hours + defer_hours

    if defer_hours > 0:
        print(f"Defer active: +{defer_hours} hours (stop at {stop_hours}h)")

    # Calculate runtime using LastStartedAt tag (falls back to LaunchTime)
    last_started_at = tags.get('LastStartedAt')
    if last_started_at:
        try:
            start_time = datetime.fromisoformat(last_started_at)
            print(f"Using LastStartedAt tag: {last_started_at}")
        except ValueError:
            print(f"Invalid LastStartedAt tag value: {last_started_at}, falling back to LaunchTime")
            start_time = instance['LaunchTime']
    else:
        start_time = instance['LaunchTime']
        print("No LastStartedAt tag found, using LaunchTime")

    now = datetime.now(timezone.utc)
    runtime_hours = (now - start_time).total_seconds() / 3600

    print(f"Instance {instance_id} has been running for {runtime_hours:.2f} hours (fail-safe stop at {stop_hours}h)")

    # Fail-safe stop: instance exceeded maximum runtime
    if runtime_hours >= stop_hours:
        print(f"FAIL-SAFE: Stopping instance {instance_id} after {runtime_hours:.2f} hours")
        ec2.stop_instances(InstanceIds=[instance_id])

        send_ntfy(
            ntfy_topic,
            "FAIL-SAFE: Dev Workstation Stopped",
            f"Instance still running after {runtime_hours:.1f}h — scheduled stop may have failed.\n\nRestart: aws ec2 start-instances --instance-ids {instance_id}",
            priority="urgent",
            tags="rotating_light"
        )

        # Reset defer tag for next start
        ec2.create_tags(
            Resources=[instance_id],
            Tags=[{'Key': 'AutoStopDeferHours', 'Value': '0'}]
        )

        return {'statusCode': 200, 'body': 'Fail-safe: instance stopped'}

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
      INSTANCE_ID      = local.instance_id
      STOP_AFTER_HOURS = tostring(var.stop_after_hours)
      INSTANCE_NAME    = var.name
      NTFY_TOPIC       = var.notification_topic != null ? var.notification_topic : ""
    }
  }

  tags = local.common_tags
}

# =============================================================================
# CloudWatch & EventBridge (periodic fail-safe check)
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

# =============================================================================
# EC2 Instance State-Change Tracking
# Tags the instance with LastStartedAt on every start (manual or scheduled)
# so the auto-stop timer resets correctly across stop/start cycles
# =============================================================================

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  count       = var.enable_auto_stop ? 1 : 0
  name        = "${var.name}-instance-started"
  description = "Fires when dev workstation transitions to running"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
    detail = {
      state       = ["running"]
      instance-id = [local.instance_id]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "tag_start_time" {
  count     = var.enable_auto_stop ? 1 : 0
  rule      = aws_cloudwatch_event_rule.instance_state_change[0].name
  target_id = "tag-start-time"
  arn       = aws_lambda_function.auto_stop[0].arn
}

resource "aws_lambda_permission" "allow_ec2_state_change" {
  count         = var.enable_auto_stop ? 1 : 0
  statement_id  = "AllowEC2StateChange"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auto_stop[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.instance_state_change[0].arn
}

# =============================================================================
# Scheduled Start/Stop via EventBridge Scheduler
# Natively supports IANA timezones (no manual UTC offset calculations)
# =============================================================================

resource "aws_iam_role" "scheduler" {
  count = var.enable_scheduled_start ? 1 : 0
  name  = "${var.name}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "scheduler_ec2" {
  count = var.enable_scheduled_start ? 1 : 0
  name  = "${var.name}-scheduler-ec2"
  role  = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:StopInstances"
        ]
        Resource = "arn:aws:ec2:${data.aws_region.current.name}:*:instance/${local.instance_id}"
      }
    ]
  })
}

resource "aws_scheduler_schedule" "start_instance" {
  for_each = var.enable_scheduled_start ? toset(var.schedule_start_expressions) : toset([])

  name        = "${var.name}-start-${index(var.schedule_start_expressions, each.value)}"
  description = "Scheduled start for ${var.name}: ${each.value}"
  group_name  = "default"

  schedule_expression          = each.value
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = [local.instance_id]
    })
  }
}

resource "aws_scheduler_schedule" "stop_instance" {
  for_each = var.enable_scheduled_start ? toset(var.schedule_stop_expressions) : toset([])

  name        = "${var.name}-stop-${index(var.schedule_stop_expressions, each.value)}"
  description = "Scheduled stop for ${var.name}: ${each.value}"
  group_name  = "default"

  schedule_expression          = each.value
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = [local.instance_id]
    })
  }
}

# =============================================================================
# SQS Task Queue
# Allows queueing tasks for the workstation when the instance is off
# =============================================================================

resource "aws_sqs_queue" "task_queue" {
  count = var.enable_task_queue ? 1 : 0
  name  = "${var.name}-tasks"

  message_retention_seconds  = 1209600 # 14 days (max)
  visibility_timeout_seconds = 300     # 5 minutes
  receive_wait_time_seconds  = 20      # Long polling

  sqs_managed_sse_enabled = true # Encryption at rest

  tags = local.common_tags
}
