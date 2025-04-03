output "elastic_agent_instance_id" {
  description = "ID of the EC2 instance running Elastic Agent"
  value       = aws_instance.elastic_agent.id
}

output "elastic_agent_public_ip" {
  description = "Public IP address of the EC2 instance running Elastic Agent"
  value       = aws_instance.elastic_agent.public_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket created for logs"
  value       = aws_s3_bucket.log_bucket.id
}

output "s3_bucket_arn" {
  description = "ARN of the S3 bucket created for logs"
  value       = aws_s3_bucket.log_bucket.arn
}

output "sqs_queue_url" {
  description = "URL of the SQS queue created for S3 notifications"
  value       = aws_sqs_queue.s3_notifications.id
}

output "lambda_function_name" {
  description = "Name of the Lambda function created for logging"
  value       = aws_lambda_function.log_generator.function_name
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group for Lambda function"
  value       = aws_cloudwatch_log_group.lambda_logs.name
}

output "kinesis_firehose_delivery_stream" {
  description = "Kinesis Firehose Delivery Stream for CloudWatch Logs"
  value       = aws_kinesis_firehose_delivery_stream.log_stream.name
}

output "elastic_agent_s3_sqs_config_example" {
  description = "Example Elastic Agent configuration for AWS S3-SQS integration"
  value       = <<-EOT
    - type: aws-s3
      queue_url: ${aws_sqs_queue.s3_notifications.id}
      expand_event_list_from_field: Records
      visibility_timeout: 300s
      api_timeout: 120s
      file_selectors:
        - regex: '/cloudwatch-logs/lambda/${var.prefix}-log-generator/'  # Match the Firehose prefix
  EOT
}