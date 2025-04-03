# AWS Elastic Agent with S3-SQS Notification System

This Terraform project sets up an AWS infrastructure to collect and monitor logs using the Elastic Agent with S3-SQS notification system.

## Architecture

```
                                                                 ┌─────────────────┐
                                                                 │                 │
                                                                 │  EC2 Instance   │
                                                  ┌───────────►  │  Elastic Agent  │
                                                  │              │                 │
                                                  │              └─────────────────┘
                                                  │                      ▲
                                                  │                      │
┌──────────────┐     ┌─────────────────┐     ┌───┴───────────┐          │
│              │     │                 │     │               │          │
│  CloudWatch  │────►│  Kinesis       │────►│  S3 Bucket    │◄─────────┘
│  Logs        │     │  Firehose      │     │  (logs)       │
│              │     │                 │     │               │
└──────────────┘     └─────────────────┘     └───────────────┘
       ▲                                            │
       │                                            │
       │                                            ▼
       │                                     ┌────────────┐
┌──────┴───────┐                             │            │
│              │                             │  SQS Queue │
│    Lambda    │                             │            │
│              │                             └────────────┘
└──────────────┘                                   │
                                                   │
                                                   ▼
                                        ┌─────────────────┐
                                        │                 │
                                        │  EC2 Instance   │
                                        │  Elastic Agent  │
                                        │                 │
                                        └─────────────────┘
```

## Components

This Terraform project creates and configures the following AWS resources:

1. **EC2 Instance with Elastic Agent**: A server to run the Elastic Agent that will collect logs.
2. **S3 Bucket**: Storage for CloudWatch logs delivered via Kinesis Firehose.
3. **SQS Queue**: Receives S3 bucket notifications when new objects are created.
4. **Lambda Function**: Generates sample logs to demonstrate the logging pipeline.
5. **CloudWatch Log Group**: Captures logs from the Lambda function.
6. **Kinesis Firehose**: Streams CloudWatch logs to S3 bucket.
7. **IAM Roles and Policies**: Proper permissions for all components to interact.

## Prerequisites

- AWS CLI installed and configured
- Terraform (>= 1.0.0)
- SSH key pair for EC2 instance access

## Usage

1. Clone this repository
2. Create a `terraform.tfvars` file based on the provided example
3. Initialize Terraform:
   ```
   terraform init
   ```
4. Plan the deployment:
   ```
   terraform plan
   ```
5. Apply the configuration:
   ```
   terraform apply
   ```

### Configuration Variables

Key variables can be set in your `terraform.tfvars` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region to deploy resources | `ap-northeast-1` |
| `aws_profile` | AWS profile to use for credentials | `default` |
| `prefix` | Prefix for all resource names | `elastic` |
| `ec2_instance_type` | EC2 instance type for Elastic Agent | `t3.medium` |
| `ec2_ami_id` | AMI ID for EC2 instances | `ami-0599b6e53ca798bb2` |
| `s3_bucket_prefix` | Prefix for S3 bucket name | `logs` |
| `sqs_queue_name` | Name for SQS queue | `s3-notifications` |

## Testing the Setup

After deployment, you can test the setup by:

1. Invoking the Lambda function to generate logs:
   ```
   aws lambda invoke --function-name $(terraform output -raw lambda_function_name) --payload '{"test": "message"}' response.json
   ```

2. Verify logs are flowing to CloudWatch:
   ```
   aws logs tail $(terraform output -raw cloudwatch_log_group)
   ```

3. Wait for logs to be delivered to S3 (this may take a few minutes):
   ```
   aws s3 ls s3://$(terraform output -raw s3_bucket_name)/cloudwatch-logs/lambda/ --recursive
   ```

4. SSH to the Elastic Agent EC2 instance to verify SQS message processing:
   ```
   ssh ec2-user@$(terraform output -raw elastic_agent_public_ip)
   ```

## Elastic Agent Configuration Example

An example configuration for the Elastic Agent to collect logs from S3 via SQS notifications:

```yaml
- type: aws-s3
  queue_url: <sqs_queue_url>
  expand_event_list_from_field: Records
  visibility_timeout: 300s
  api_timeout: 120s
  file_selectors:
    - regex: '/cloudwatch-logs/lambda/<prefix>-log-generator/'
```

Replace `<sqs_queue_url>` with the actual SQS queue URL from the Terraform output and `<prefix>` with your configured prefix.

## Cleanup

To remove all resources created by this Terraform project:

```
terraform destroy
```

Note: The S3 bucket is configured with `force_destroy = true` to allow deletion even when it contains objects.

## License

This project is licensed under the MIT License - see the LICENSE file for details.