terraform {
  backend "s3" {
    bucket         = "sportlink-terraform-backend"
    key            = "Prod/CloudWatch/terraform.tfstate"
    region         = "ap-northeast-2"
    profile        = "terraform_user"
    dynamodb_table = "sportlink-terraform-bucket-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform_user"
}

data "aws_instances" "eks_nodes" {
  filter {
    name   = "tag:eks:nodegroup"
    values = ["prod-worker-nodes"]
  }
}

data "terraform_remote_state" "bastion" {
  backend = "s3"
  config = {
    bucket = "sportlink-terraform-backend"
    key    = "Prod/bastion/terraform.tfstate"
    region = "ap-northeast-2"
    profile = "terraform_user"
  }
}

data "terraform_remote_state" "rds" {
  backend = "s3"
  config = {
    bucket = "sportlink-terraform-backend"
    key    = "Prod/RDS/terraform.tfstate"
    region = "ap-northeast-2"
    profile = "terraform_user"
  }
}

data "aws_caller_identity" "current" {}

# SNS Topic 생성
resource "aws_sns_topic" "bastion_az1_topic" {
  name = "bastion_az1_topic"
}

resource "aws_sns_topic" "bastion_az2_topic" {
  name = "bastion_az2_topic"
}

# Lambda 역할 생성
resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action    = "sts:AssumeRole",
        Effect    = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda 정책 생성
resource "aws_iam_policy" "lambda_policy" {
  name        = "lambda_policy"
  description = "Policy for Lambda function to access CloudWatch Logs and SNS"
  
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:FilterLogEvents"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = "sns:Publish",
        Resource = [
          aws_sns_topic.bastion_az1_topic.arn,
          aws_sns_topic.bastion_az2_topic.arn
        ]
      },
      {
        Effect   = "Allow",
        Action   = "s3:PutObject",
        Resource = "${aws_s3_bucket.cloudwatch_logs_bucket.arn}/*"
      },
      {
        Effect   = "Allow",
        Action   = "logs:PutSubscriptionFilter",
        Resource = "*"
      }
    ]
  })
}


# Lambda 역할과 정책 연결
resource "aws_iam_role_policy_attachment" "lambda_role_policy_attachment" {
  role       = aws_iam_role.lambda_role.name
  policy_arn  = aws_iam_policy.lambda_policy.arn
}

# Lambda 함수 생성
resource "aws_lambda_function" "slack_notifier" {
  filename         = "lambda_function_payload.zip"
  function_name    = "prod_slack_notifier"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.9"
  source_code_hash = filebase64sha256("lambda_function_payload.zip")
  timeout          = 30

  environment {
    variables = {
      SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/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"
      BUCKET_NAME        = aws_s3_bucket.cloudwatch_logs_bucket.bucket
    }
  }
}

# Lambda와 SNS 주제 연결
resource "aws_lambda_permission" "sns_invocation_az1" {
  statement_id  = "AllowExecutionFromSNS_AZ1"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.bastion_az1_topic.arn
}

resource "aws_lambda_permission" "sns_invocation_az2" {
  statement_id  = "AllowExecutionFromSNS_AZ2"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.bastion_az2_topic.arn
}

# CloudWatch 알람 생성 (CPU 사용률)

# Bastion Host AZ1
resource "aws_cloudwatch_metric_alarm" "cpu_high_az1" {
  alarm_name          = "high-cpu-az1"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm fires if CPU utilization exceeds 80% for the bastion host in AZ1."
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.bastion_az1_topic.arn]
  alarm_actions             = [aws_sns_topic.bastion_az1_topic.arn]

  dimensions = {
    InstanceId = data.terraform_remote_state.bastion.outputs.BastionHost_AZ1_id
  }
}

# Bastion Host AZ2
resource "aws_cloudwatch_metric_alarm" "cpu_high_az2" {
  alarm_name          = "high-cpu-az2"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm fires if CPU utilization exceeds 80% for the bastion host in AZ2."
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.bastion_az2_topic.arn]
  alarm_actions             = [aws_sns_topic.bastion_az2_topic.arn]

  dimensions = {
    InstanceId = data.terraform_remote_state.bastion.outputs.BastionHost_AZ2_id
  }
}

# EKS Node
resource "aws_cloudwatch_metric_alarm" "eks_node_cpu_high" {
  count = length(data.aws_instances.eks_nodes.ids)

  alarm_name          = "high-cpu-eks-node-${count.index + 1}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm fires if CPU utilization exceeds 80% for an EKS node."
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.bastion_az1_topic.arn]
  alarm_actions             = [aws_sns_topic.bastion_az1_topic.arn]

  dimensions = {
    InstanceId = data.aws_instances.eks_nodes.ids[count.index]
  }
}

# RDS Instance
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "high-cpu-rds"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This alarm fires if CPU utilization exceeds 80% for the RDS instance."
  insufficient_data_actions = []
  ok_actions                = [aws_sns_topic.bastion_az1_topic.arn]
  alarm_actions             = [aws_sns_topic.bastion_az1_topic.arn]

  dimensions = {
    # DBInstanceIdentifier = data.terraform_remote_state.rds.outputs.db_instance_resource_id
  }
}

# SNS Topic Subscription for Lambda
resource "aws_sns_topic_subscription" "lambda_subscription_az1" {
  topic_arn = aws_sns_topic.bastion_az1_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn
}

resource "aws_sns_topic_subscription" "lambda_subscription_az2" {
  topic_arn = aws_sns_topic.bastion_az2_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier.arn
}

# S3 버킷 생성
resource "aws_s3_bucket" "cloudwatch_logs_bucket" {
  bucket        = "prod-cloudwatch-logs-bucket"
  force_destroy = true
}

resource "aws_cloudwatch_log_group" "prod_log_group" {
  name = "/aws/lambda/prod-watch-log-group"  
}


# S3 버킷 정책 생성
data "aws_iam_policy_document" "cloudwatch_logs_policy" {
  statement {
    sid    = "CloudWatchLogsToS3"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudwatch_logs_bucket.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudwatch_logs_policy" {
  bucket = aws_s3_bucket.cloudwatch_logs_bucket.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_policy.json
}

# CloudWatch Logs Subscription Filter 생성
resource "aws_cloudwatch_log_subscription_filter" "cloudwatch_logs_to_s3" {
  name            = "cloudwatch-logs-to-s3"
  log_group_name  = aws_cloudwatch_log_group.prod_log_group.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.slack_notifier.arn

  depends_on = [
    aws_lambda_permission.cloudwatch_logs_to_lambda
  ]
}


resource "aws_lambda_permission" "cloudwatch_logs_to_lambda" {
  statement_id  = "AllowExecutionFromCloudWatchLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.slack_notifier.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:aws:logs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/prod-watch-log-group:*"
}
