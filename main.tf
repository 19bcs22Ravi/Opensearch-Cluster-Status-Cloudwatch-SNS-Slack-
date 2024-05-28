provider "aws" {
  region = "ap-south-1"
}

# OpenSearch Domain  make changes according to your requirement
resource "aws_opensearch_domain" "opensearch" {
  domain_name    = "systlab-opensearch"
  engine_version = "Elasticsearch_7.10"

  cluster_config {
    instance_type            = "r5.xlarge.search"
    instance_count           = 2
    dedicated_master_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp2"
    volume_size = 10
  }
}

# IAM Role for Lambda Execution
resource "aws_iam_role" "lambda_exec" {
  name = "lambda-exec-role"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        },
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# IAM Policy for Lambda Execution Role
resource "aws_iam_policy" "lambda_exec_policy" {
  name        = "lambda-exec-policy"
  description = "Policy for Lambda execution role"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "es:DescribeElasticsearchDomain",
          "es:DescribeElasticsearchDomainConfig"
        ],
        Resource = "arn:aws:es:ap-south-1:533267030389:domain/systlab-opensearch"  #opensearch arn
      },
      {
        Effect   = "Allow",
        Action   = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics"
        ],
        Resource = "*"
      },
      {
        Effect   = "Allow",
        Action   = [
          "sns:Publish"
        ],
        Resource = "arn:aws:sns:ap-south-1:533267030389:Default_CloudWatch_Alarms_Topic"  # sns arn create before applying the config
      }
    ]
  })
}

# Attach the policy to the Lambda execution role
resource "aws_iam_role_policy_attachment" "lambda_exec_policy_attachment" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_exec_policy.arn
}

# Lambda Function
resource "aws_lambda_function" "notify_slack" {
  filename      = "./lambda_function.zip"
  function_name = "lambda_function"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.8"
  environment {
    variables = {
      SLACK_WEBHOOK_URL = "" #your slack webhook
      SNS_TOPIC_ARN     = "arn:aws:sns:ap-south-1:533267030389:Default_CloudWatch_Alarms_Topic"     #sns arn
    }
  }
}

# Add a resource-based policy to the Lambda function to allow CloudWatch Alarms to invoke it
resource "aws_lambda_permission" "allow_cloudwatch_to_invoke" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify_slack.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_metric_alarm.cluster_status_is_red.arn
}

# SNS Topic
resource "aws_sns_topic" "default_alarms_topic" {
  name = "Default_CloudWatch_Alarms_Topic"              #sns topic name
}

# CloudWatch Metric Alarm for OpenSearch Domain Cluster Status Red
resource "aws_cloudwatch_metric_alarm" "cluster_status_is_red" {
  #count               = 1
  alarm_name          = "ElasticSearch-ClusterStatusIsRed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  metric_name         = "ClusterStatus.red"
  namespace           = "AWS/ES"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "Average elasticsearch cluster status is in red over last 1 minute(s)"
  alarm_actions       = [
    aws_lambda_function.notify_slack.arn,
    aws_sns_topic.default_alarms_topic.arn
  ]
  treat_missing_data  = "ignore"

  dimensions = {
    DomainName = "systlab-opensearch"
    ClientId   = data.aws_caller_identity.current.account_id
  }
}

# Data source to get the current AWS account ID
data "aws_caller_identity" "current" {}

# Adding new resource-based policy
resource "aws_lambda_permission" "allow_cloudwatch_alarms_to_invoke" {
  statement_id  = "rv-01"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify_slack.function_name
  principal     = "lambda.alarms.cloudwatch.amazonaws.com"
  source_arn    = "arn:aws:cloudwatch:ap-south-1:533267030389:alarm:ElasticSearch-ClusterStatusIsRed"   #cloudwatch arn
}
