# S3 Terraform Bucket<!-- omit in toc -->

Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: CC-BY-SA-4.0

## Table of Contents<!-- omit in toc -->

- [Introduction](#introduction)
- [Deployed Resource Details](#deployed-resource-details)
- [Implementation Instructions](#implementation-instructions)
- [References](#references)

## Introduction

The S3 Terraform Bucket solution creates S3 buckets for Terraform state storage in each `AWS account` in the AWS Organization.

This solution automatically creates S3 buckets with the following features:
- **Versioning enabled** for state file history and rollback capabilities
- **Server-side encryption** using AES256 for data security
- **Public access blocked** to ensure data privacy
- **Lifecycle policies** to manage storage costs and cleanup
- **Proper tagging** for resource management and cost allocation

The solution is triggered when new accounts are added to the AWS Organization, account tag updates, and on account status changes.

**Key solution features:**

- Creates S3 buckets for Terraform state storage in all existing accounts including the `management account` and future accounts.
- Ability to exclude accounts via provided account tags.
- Triggered when new accounts are added to the AWS Organization, account tag updates, and on account status changes.
- Configurable bucket naming with prefix and suffix options.

### S3 Bucket Features<!-- omit in toc -->

> **The S3 buckets created by this solution include the following security and management features:**

- **Versioning**
  - Enables versioning on all buckets to maintain state file history
  - Allows rollback to previous versions if needed
  - Helps with disaster recovery scenarios

- **Server-Side Encryption**
  - Uses AES256 encryption for all objects stored in the bucket
  - Ensures data is encrypted at rest
  - Complies with security best practices

- **Public Access Blocking**
  - Blocks all public access to the bucket and its contents
  - Prevents accidental exposure of sensitive Terraform state files
  - Maintains data privacy and security

- **Lifecycle Policies**
  - Automatically deletes non-current versions after 90 days
  - Aborts incomplete multipart uploads after 7 days
  - Helps manage storage costs and cleanup

- **Resource Tagging**
  - Tags buckets with purpose, environment, and management information
  - Enables cost allocation and resource tracking
  - Follows AWS tagging best practices

---

## Deployed Resource Details

### 1.0 Control Tower Management Account<!-- omit in toc -->

#### 1.1 AWS CloudFormation<!-- omit in toc -->

- All resources are deployed via AWS CloudFormation as a `StackSet` and `Stack Instance` within the management account or a CloudFormation `Stack` within a specific account.
- The [Customizations for AWS Control Tower](https://aws.amazon.com/solutions/implementations/customizations-for-aws-control-tower/) solution deploys all templates as a CloudFormation `StackSet`.
- For parameter details, review the [AWS CloudFormation templates](templates/).

#### 1.2 IAM Roles<!-- omit in toc -->

- The `Lambda IAM Role` is used by the Lambda function to identify existing and future accounts that need S3 Terraform buckets created.
- The `S3 Terraform Bucket IAM Role` is assumed by the Lambda function to create S3 buckets in the management account and the member accounts.
- The `Event Rule IAM Role` is assumed by EventBridge to forward Global events to the `Home Region` default Event Bus.

#### 1.3 Regional Event Rules<!-- omit in toc -->

- The `AWS Control Tower Lifecycle Event Rule` triggers the `AWS Lambda Function` when a new AWS Account is provisioned through AWS Control Tower.
- The `Organization Compliance Scheduled Event Rule` triggers the `AWS Lambda Function` to capture AWS Account status updates (e.g. suspended to active).
  - A parameter is provided to set the schedule frequency.
  - See the [Instructions to Manually Run the Lambda Function](#instructions-to-manually-run-the-lambda-function) for triggering the `AWS Lambda Function` before the next scheduled run time.
- The `AWS Organizations Event Rule` triggers the `AWS Lambda Function` when updates are made to accounts within the organization.
  - When AWS Accounts are added to the AWS Organization outside of the AWS Control Tower Account Factory. (e.g. account created via AWS Organizations console, account invited from another AWS Organization).
  - When tags are added or updated on AWS Accounts.

#### 1.4 Global Event Rules<!-- omit in toc -->

- If the `Home Region` is different from the `Global Region (e.g. us-east-1)`, then global event rules are created within the `Global Region` to forward events to the `Home Region` default Event Bus.
- The `AWS Organizations Event Rule` forwards AWS Organization account update events.

#### 1.5 Dead Letter Queue (DLQ)<!-- omit in toc -->

- SQS dead letter queue used for retaining any failed Lambda events.

#### 1.6 AWS Lambda Function<!-- omit in toc -->

- The AWS Lambda Function contains the logic for creating and configuring S3 buckets for Terraform state storage within each account.

#### 1.7 Lambda CloudWatch Log Group<!-- omit in toc -->

- All the `AWS Lambda Function` logs are sent to a CloudWatch Log Group `</aws/lambda/<LambdaFunctionName>` to help with debugging and traceability of the actions performed.
- By default the `AWS Lambda Function` will create the CloudWatch Log Group and logs are encrypted with a CloudWatch Logs service managed encryption key.
- Parameters are provided for changing the default log group retention and encryption KMS key.

#### 1.8 Alarm SNS Topic<!-- omit in toc -->

- SNS Topic used to notify subscribers when messages hit the Dead Letter Queue (DLQ).

#### 1.9 S3 Bucket<!-- omit in toc -->

- The `AWS Lambda Function` creates S3 buckets with proper configuration for Terraform state storage.

---

### 2.0 All Existing and Future Organization Member Accounts<!-- omit in toc -->

#### 2.1 AWS CloudFormation<!-- omit in toc -->

- See [1.1 AWS CloudFormation](#11-aws-cloudformation)

#### 2.2 S3 Terraform Bucket IAM Role<!-- omit in toc -->

- The `S3 Terraform Bucket IAM Role` is assumed by the Lambda function within the management account to create S3 buckets in the account.

#### 2.3 S3 Bucket<!-- omit in toc -->

- See [1.9 S3 Bucket](#19-s3-bucket)

---

## Implementation Instructions

### Prerequisites<!-- omit in toc -->

1. [Download and Stage the SRA Solutions](../../../docs/DOWNLOAD-AND-STAGE-SOLUTIONS.md). **Note:** This only needs to be done once for all the solutions.
2. Verify that the [SRA Prerequisites Solution](../../common/common_prerequisites/) has been deployed.
3. No AWS Organizations Service Control Policies (SCPs) are blocking the `s3:CreateBucket`, `s3:PutBucketVersioning`, `s3:PutBucketEncryption`, and `s3:PutBucketPublicAccessBlock` API actions

### Solution Deployment<!-- omit in toc -->

Choose a Deployment Method:

- [AWS CloudFormation](#aws-cloudformation)
- [Customizations for AWS Control Tower](../../../docs/CFCT-DEPLOYMENT-INSTRUCTIONS.md)

#### AWS CloudFormation<!-- omit in toc -->

In the `management account (home region)`, launch the [sra-s3-terraform-bucket-main-ssm.yaml](templates/sra-s3-terraform-bucket-main-ssm.yaml) template. This uses an approach where some of the CloudFormation parameters are populated from SSM parameters created by the [SRA Prerequisites Solution](../../common/common_prerequisites/).

  ```bash
  aws cloudformation deploy --template-file $HOME/aws-sra-examples/aws_sra/solutions/s3/s3_terraform_bucket/templates/sra-s3-terraform-bucket-main-ssm.yaml --stack-name sra-s3-terraform-bucket-main-ssm --capabilities CAPABILITY_NAMED_IAM
  ```

#### Verify Solution Deployment<!-- omit in toc -->

How to verify after the pipeline completes?

1. Log into an account and navigate to the S3 console page
2. Look for a bucket named `terraform-state-<account-id>-<suffix>` (e.g., `terraform-state-123456789012-x7k9m`)
3. Verify the bucket has versioning enabled
4. Verify the bucket has server-side encryption enabled
5. Verify the bucket has public access blocked
6. Verify the bucket has proper tags applied

#### Solution Update Instructions<!-- omit in toc -->

1. [Download and Stage the SRA Solutions](../../../docs/DOWNLOAD-AND-STAGE-SOLUTIONS.md). **Note:** Get the latest code and run the staging script.
2. Update the existing CloudFormation Stack or CFCT configuration. **Note:** Make sure to update the `SRA Solution Version` parameter and any new added parameters.

#### Solution Delete Instructions<!-- omit in toc -->

1. In the `management account (home region)`, delete the AWS CloudFormation **Stack** (`sra-s3-terraform-bucket-main-ssm` or `sra-s3-terraform-bucket-main`) created above.
2. In the `management account (home region)`, delete the AWS CloudWatch **Log Group** (e.g. /aws/lambda/<solution_name>) for the Lambda function deployed.
3. **Note:** The S3 buckets created by this solution will need to be manually deleted from each account if desired.

#### Instructions to Manually Run the Lambda Function<!-- omit in toc -->

1. In the `management account (home region)`.
2. Navigate to the AWS Lambda Functions page.
3. Select the `checkbox` next to the Lambda Function and select `Test` from the `Actions` menu.
4. Scroll down to view the `Test event`.
5. Click the `Test` button to trigger the Lambda Function with the default values.
6. Verify that the S3 bucket was created successfully within the expected account(s).

---

## References

- [Amazon S3 User Guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/)
- [Terraform Backend Configuration](https://www.terraform.io/docs/language/settings/backends/index.html)
- [AWS S3 Bucket Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [AWS S3 Server-Side Encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingServerSideEncryption.html) 