# Create a key pair for SSH access
resource "aws_key_pair" "elastic_key" {
  key_name   = "${var.prefix}-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# S3 Bucket for logs
resource "aws_s3_bucket" "log_bucket" {
  bucket        = "${var.prefix}-${var.s3_bucket_prefix}-${random_string.suffix.result}"
  force_destroy = true
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  lower   = true
  upper   = false
}

# S3 Bucket ownership controls
resource "aws_s3_bucket_ownership_controls" "log_bucket" {
  bucket = aws_s3_bucket.log_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# S3 Bucket ACL
resource "aws_s3_bucket_acl" "log_bucket" {
  depends_on = [aws_s3_bucket_ownership_controls.log_bucket]
  bucket     = aws_s3_bucket.log_bucket.id
  acl        = "private"
}

# SQS Queue for S3 notifications
resource "aws_sqs_queue" "s3_notifications" {
  name                       = "${var.prefix}-${var.sqs_queue_name}"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 86400
  visibility_timeout_seconds = 300
  receive_wait_time_seconds  = 20
}

# SQS Queue Policy
resource "aws_sqs_queue_policy" "s3_notifications" {
  queue_url = aws_sqs_queue.s3_notifications.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action = [
          "sqs:SendMessage"
        ]
        Resource = aws_sqs_queue.s3_notifications.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.log_bucket.arn
          }
        }
      }
    ]
  })
}

# S3 Bucket Notification Configuration
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.log_bucket.id

  queue {
    queue_arn = aws_sqs_queue.s3_notifications.arn
    events    = ["s3:ObjectCreated:*"]
  }
}

# Security group for EC2 instance
resource "aws_security_group" "elastic_agent_sg" {
  name        = "${var.prefix}-elastic-agent-sg"
  description = "Security group for Elastic Agent"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }
}

# IAM Role for Elastic Agent EC2 Instance
resource "aws_iam_role" "elastic_agent_role" {
  name = "${var.prefix}-elastic-agent-role"

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
}

# IAM Policy for S3-SQS access
resource "aws_iam_policy" "elastic_agent_s3_sqs_policy" {
  name        = "${var.prefix}-elastic-agent-s3-sqs-policy"
  description = "Policy for Elastic Agent to access S3 and SQS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.s3_notifications.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.log_bucket.arn,
          "${aws_s3_bucket.log_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeTags",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach IAM Policy to Elastic Agent Role
resource "aws_iam_role_policy_attachment" "elastic_agent_policy_attachment" {
  role       = aws_iam_role.elastic_agent_role.name
  policy_arn = aws_iam_policy.elastic_agent_s3_sqs_policy.arn
}

# IAM Instance Profile for Elastic Agent EC2 Instance
resource "aws_iam_instance_profile" "elastic_agent_profile" {
  name = "${var.prefix}-elastic-agent-profile"
  role = aws_iam_role.elastic_agent_role.name
}

# EC2 Instance for Elastic Agent
resource "aws_instance" "elastic_agent" {
  ami                    = var.ec2_ami_id
  instance_type          = var.ec2_instance_type
  key_name               = aws_key_pair.elastic_key.key_name
  iam_instance_profile   = aws_iam_instance_profile.elastic_agent_profile.name
  vpc_security_group_ids = [aws_security_group.elastic_agent_sg.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name = "${var.prefix}-elastic-agent"
  }
}

# Lambda function for logging
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/lambda_function.zip"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.prefix}-lambda-role"

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
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${var.prefix}-log-generator"
  retention_in_days = 14
}

# IAM Policy for Lambda to write to CloudWatch logs
resource "aws_iam_policy" "lambda_logging_policy" {
  name        = "${var.prefix}-lambda-logging-policy"
  description = "IAM policy for Lambda function to log to CloudWatch"

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
      }
    ]
  })
}

# Attach Lambda logging policy
resource "aws_iam_role_policy_attachment" "lambda_logs_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_logging_policy.arn
}

# Lambda function
resource "aws_lambda_function" "log_generator" {
  function_name    = "${var.prefix}-log-generator"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  timeout          = 30
  
  environment {
    variables = {
      LOG_LEVEL = var.lambda_log_level
    }
  }
}

# Create CloudWatch Log Group Subscription to S3
resource "aws_cloudwatch_log_subscription_filter" "lambda_logs_to_s3" {
  name            = "${var.prefix}-lambda-logs-to-s3"
  log_group_name  = aws_cloudwatch_log_group.lambda_logs.name
  filter_pattern  = ""  # Empty pattern means all logs
  destination_arn = aws_kinesis_firehose_delivery_stream.log_stream.arn
  role_arn        = aws_iam_role.cloudwatch_subscription_role.arn
}

# IAM Role for CloudWatch Log Subscription
resource "aws_iam_role" "cloudwatch_subscription_role" {
  name = "${var.prefix}-cloudwatch-subscription-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for CloudWatch to write to Kinesis Firehose
resource "aws_iam_policy" "cloudwatch_to_firehose_policy" {
  name        = "${var.prefix}-cloudwatch-to-firehose-policy"
  description = "IAM policy for CloudWatch to deliver logs to Kinesis Firehose"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "firehose:PutRecord",
          "firehose:PutRecordBatch"
        ]
        Resource = aws_kinesis_firehose_delivery_stream.log_stream.arn
      }
    ]
  })
}

# Attach CloudWatch to Firehose policy
resource "aws_iam_role_policy_attachment" "cloudwatch_firehose_attachment" {
  role       = aws_iam_role.cloudwatch_subscription_role.name
  policy_arn = aws_iam_policy.cloudwatch_to_firehose_policy.arn
}

# IAM Role for Kinesis Firehose
resource "aws_iam_role" "firehose_role" {
  name = "${var.prefix}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Policy for Firehose to deliver to S3
resource "aws_iam_policy" "firehose_to_s3_policy" {
  name        = "${var.prefix}-firehose-to-s3-policy"
  description = "IAM policy for Firehose to deliver logs to S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.log_bucket.arn,
          "${aws_s3_bucket.log_bucket.arn}/*"
        ]
      }
    ]
  })
}

# Attach Firehose to S3 policy
resource "aws_iam_role_policy_attachment" "firehose_s3_attachment" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = aws_iam_policy.firehose_to_s3_policy.arn
}

# Kinesis Firehose Delivery Stream
resource "aws_kinesis_firehose_delivery_stream" "log_stream" {
  name        = "${var.prefix}-log-delivery-stream"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose_role.arn
    bucket_arn         = aws_s3_bucket.log_bucket.arn
    prefix             = "cloudwatch-logs/lambda/${var.prefix}-log-generator/"
    buffering_size        = 5
    buffering_interval    = 300
    compression_format = "GZIP"
  }
}