# ─── CloudWatch Dashboard ─────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "EKS Node CPU Utilization"
          metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          region  = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "EKS Node Memory Utilization"
          metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", var.cluster_name]]
          period  = 300
          stat    = "Average"
          view    = "timeSeries"
          region  = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "External ALB 5XX Errors"
          metrics = [["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          region  = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "SQS Order Queue Depth"
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "${var.project_name}-order-processing"]]
          period  = 60
          stat    = "Maximum"
          view    = "timeSeries"
          region  = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "ALB Target 5XX Errors (Service Errors)"
          metrics = [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix]]
          period  = 300
          stat    = "Sum"
          view    = "timeSeries"
          region  = "us-east-1"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title   = "ALB Target Response Time (p99)"
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix]]
          period  = 60
          stat    = "p99"
          view    = "timeSeries"
          region  = "us-east-1"
        }
      }
    ]
  })
}

# ─── EKS Node CPU Alarm ───────────────────────────────────────────────────
# Replaces the old Frontend ASG + Backend ASG CPU alarms (EC2 ASGs no longer exist).
# Container Insights addon pushes node_cpu_utilization to this namespace automatically.
resource "aws_cloudwatch_metric_alarm" "eks_node_cpu_high" {
  alarm_name          = "${var.project_name}-eks-node-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "EKS node CPU > 70% — consider scaling node group"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}

# ─── EKS Node Memory Alarm ────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "eks_node_memory_high" {
  alarm_name          = "${var.project_name}-eks-node-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "node_memory_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "EKS node memory > 80% — pods may be OOMKilled"
  alarm_actions       = [var.alerts_topic_arn]
  ok_actions          = [var.alerts_topic_arn]

  dimensions = {
    ClusterName = var.cluster_name
  }
}

# ─── ALB 5XX Alarm ────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project_name}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "External ALB 5XX errors > 10 in 5 minutes"
  alarm_actions       = [var.alerts_topic_arn]

  dimensions = {
    LoadBalancer = var.external_alb_arn_suffix
  }
}

# ─── ALB Target 5XX Alarm (service-level errors) ─────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${var.project_name}-alb-target-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Backend services returning 5XX > 10 in 5 minutes"
  alarm_actions       = [var.alerts_topic_arn]

  dimensions = {
    LoadBalancer = var.external_alb_arn_suffix
  }
}

# ─── Unhealthy Targets Alarm ──────────────────────────────────────────────
# Watches the external ALB frontend target group (TargetGroupBinding, ip-type targets).
# Old version referenced internal_alb and auth_tg — those no longer exist (EKS uses kgateway).
resource "aws_cloudwatch_metric_alarm" "unhealthy_targets" {
  alarm_name          = "${var.project_name}-unhealthy-frontend-targets"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Unhealthy frontend pod targets detected in ALB"
  alarm_actions       = [var.alerts_topic_arn]

  dimensions = {
    LoadBalancer = var.external_alb_arn_suffix
    TargetGroup  = var.frontend_tg_arn_suffix
  }
}

# ─── SQS Order Queue Depth Alarm ──────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "sqs_queue_depth" {
  alarm_name          = "${var.project_name}-sqs-queue-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 100
  alarm_description   = "SQS order queue depth > 100 messages — order service may be backlogged"
  alarm_actions       = [var.alerts_topic_arn]

  dimensions = {
    QueueName = "${var.project_name}-order-processing"
  }
}

# ─── SQS Dead Letter Queue Alarm ──────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "sqs_dlq_depth" {
  alarm_name          = "${var.project_name}-sqs-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages landed in order processing DLQ — order failures detected"
  alarm_actions       = [var.alerts_topic_arn]

  dimensions = {
    QueueName = "${var.project_name}-order-processing-dlq"
  }
}

# ─── DynamoDB Throttling Alarm ────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  alarm_name          = "${var.project_name}-dynamodb-throttles"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UserErrors"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "DynamoDB user errors (throttling/validation) > 5 in 5 minutes"
  alarm_actions       = [var.alerts_topic_arn]
}

# ─── CloudWatch Log Groups ────────────────────────────────────────────────
# Explicit log groups for structured application logs per service.
# Container Insights addon writes pod stdout/stderr to /aws/containerinsights/
# automatically — these groups are for app-level structured logging.
resource "aws_cloudwatch_log_group" "auth_service" {
  name              = "/shopmesh/auth-service"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "product_service" {
  name              = "/shopmesh/product-service"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "order_service" {
  name              = "/shopmesh/order-service"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "analytics_service" {
  name              = "/shopmesh/analytics-service"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "ai_assistant_service" {
  name              = "/shopmesh/ai-assistant-service"
  retention_in_days = 30
}
