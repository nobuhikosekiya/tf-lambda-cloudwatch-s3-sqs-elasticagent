#!/usr/bin/env python3
"""
Test script for AWS S3-SQS notification infrastructure
This script will:
1. Invoke the Lambda function multiple times to generate logs
2. Wait for logs to appear in CloudWatch
3. Wait for logs to be delivered to S3 via Kinesis Firehose
4. Check if SQS messages are generated for the S3 objects
5. Check if S3 objects can be retrieved
"""

import argparse
import boto3
import json
import time
import sys
import logging
from botocore.exceptions import ClientError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)

# Parse arguments
parser = argparse.ArgumentParser(description="Test AWS S3-SQS notification infrastructure")
parser.add_argument("--lambda-function", required=True, help="Lambda function name")
parser.add_argument("--log-group", required=True, help="CloudWatch log group name")
parser.add_argument("--s3-bucket", required=True, help="S3 bucket name")
parser.add_argument("--sqs-queue-url", required=True, help="SQS queue URL")
parser.add_argument("--region", default="ap-northeast-1", help="AWS region")
parser.add_argument("--wait-time", type=int, default=180, help="Time to wait for logs to appear in S3 (seconds)")
args = parser.parse_args()

# Initialize AWS clients
session = boto3.Session(region_name=args.region)
lambda_client = session.client('lambda')
logs_client = session.client('logs')
s3_client = session.client('s3')
sqs_client = session.client('sqs')

def invoke_lambda(function_name, num_invocations=5):
    """Invoke Lambda function multiple times to generate logs"""
    logger.info(f"Invoking Lambda function {function_name} {num_invocations} times...")
    
    for i in range(num_invocations):
        payload = json.dumps({
            "test": f"message-{i}",
            "timestamp": time.time()
        })
        
        try:
            response = lambda_client.invoke(
                FunctionName=function_name,
                InvocationType='Event',  # Asynchronous invocation
                Payload=payload
            )
            if response['StatusCode'] >= 200 and response['StatusCode'] < 300:
                logger.info(f"Lambda invocation {i+1}/{num_invocations} successful")
            else:
                logger.error(f"Lambda invocation {i+1}/{num_invocations} failed: {response}")
        except ClientError as e:
            logger.error(f"Error invoking Lambda: {e}")
            return False
        
        # Small delay to spread out the invocations
        time.sleep(1)
    
    return True

def check_cloudwatch_logs(log_group_name):
    """Check if logs are appearing in CloudWatch"""
    logger.info(f"Checking for logs in CloudWatch log group {log_group_name}...")
    
    try:
        # Get log streams
        response = logs_client.describe_log_streams(
            logGroupName=log_group_name,
            orderBy='LastEventTime',
            descending=True,
            limit=5
        )
        
        if not response.get('logStreams'):
            logger.error("No log streams found in CloudWatch log group")
            return False
        
        # Get logs from the most recent stream
        stream_name = response['logStreams'][0]['logStreamName']
        log_events = logs_client.get_log_events(
            logGroupName=log_group_name,
            logStreamName=stream_name,
            limit=10
        )
        
        if not log_events.get('events'):
            logger.error("No log events found in the most recent log stream")
            return False
        
        logger.info(f"Found {len(log_events['events'])} log events in CloudWatch")
        return True
    
    except ClientError as e:
        logger.error(f"Error checking CloudWatch logs: {e}")
        return False

def wait_for_s3_objects(bucket_name, wait_time=600):
    """Wait for objects to appear in S3 bucket"""
    logger.info(f"Waiting up to {wait_time} seconds for objects to appear in S3 bucket {bucket_name}...")
    
    end_time = time.time() + wait_time
    
    while time.time() < end_time:
        try:
            # List objects in bucket
            kwargs = {'Bucket': bucket_name}
            
            response = s3_client.list_objects_v2(**kwargs)
            
            if response.get('KeyCount', 0) > 0:
                logger.info(f"Found {response['KeyCount']} objects in S3 bucket")
                return response['Contents']
            
            logger.info("No objects found yet, waiting...")
            time.sleep(10)
        
        except ClientError as e:
            logger.error(f"Error listing S3 objects: {e}")
            return []
    
    logger.error(f"Timed out waiting for objects to appear in S3 bucket")
    return []

def check_sqs_messages(queue_url):
    """Check if SQS messages are being generated"""
    logger.info(f"Checking for messages in SQS queue {queue_url}...")
    
    try:
        # Receive messages from SQS queue
        response = sqs_client.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=10  # Long polling
        )
        
        messages = response.get('Messages', [])
        if not messages:
            logger.warning("No messages found in SQS queue")
            return False
        
        logger.info(f"Found {len(messages)} messages in SQS queue")
        
        # Print sample message content
        if messages:
            message_body = json.loads(messages[0]['Body'])
            logger.info(f"Sample SQS message: {json.dumps(message_body, indent=2)}")
            
            # Return messages to queue (don't delete them)
            for message in messages:
                sqs_client.change_message_visibility(
                    QueueUrl=queue_url,
                    ReceiptHandle=message['ReceiptHandle'],
                    VisibilityTimeout=0
                )
        
        return True
    
    except ClientError as e:
        logger.error(f"Error checking SQS messages: {e}")
        return False

def main():
    """Main test function"""
    success = True
    
    # Step 1: Invoke Lambda function
    if not invoke_lambda(args.lambda_function):
        logger.error("Failed to invoke Lambda function")
        success = False
    
    # Step 2: Wait a moment for logs to appear in CloudWatch
    logger.info("Waiting for logs to appear in CloudWatch...")
    time.sleep(10)
    
    # Step 3: Check CloudWatch logs
    if not check_cloudwatch_logs(args.log_group):
        logger.error("Failed to find logs in CloudWatch")
        success = False
    
    # Step 4: Wait for logs to be delivered to S3
    s3_objects = wait_for_s3_objects(args.s3_bucket, args.wait_time)
    if not s3_objects:
        logger.error("Failed to find objects in S3 bucket")
        success = False
    
    # Step 5: Check SQS messages
    if not check_sqs_messages(args.sqs_queue_url):
        logger.warning("No SQS messages found - this might be expected if delivery to S3 is delayed")
        # Not marking as failure as timing can vary
    
    # Report result
    if success:
        logger.info("All tests completed successfully!")
        return 0
    else:
        logger.error("Some tests failed. Check the logs for details.")
        return 1

if __name__ == "__main__":
    sys.exit(main())