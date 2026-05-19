data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(
    {
      Project = "Automatische E-Mail-Kategorisierung"
      Course  = "Cloud Programming"
      Phase   = "2"
    },
    var.tags
  )

  account_id              = data.aws_caller_identity.current.account_id
  raw_email_filter_prefix = trim(var.raw_email_prefix, "/") == "" ? "" : "${trim(var.raw_email_prefix, "/")}/"
  receipt_rule_set_name   = "${var.name_prefix}-inbound"
  receipt_rule_name       = "${var.name_prefix}-store-raw-email"
  receipt_rule_arn        = "arn:aws:ses:${var.aws_region}:${local.account_id}:receipt-rule-set/${local.receipt_rule_set_name}:receipt-rule/${local.receipt_rule_name}"

  dashboard_files = {
    "index.html" = "text/html"
    "styles.css" = "text/css"
    "app.js"     = "application/javascript"
  }
}

data "aws_iam_policy_document" "kms_key" {
  statement {
    sid = "AllowAccountAdministration"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid = "AllowSESToEncryptInboundMail"
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid = "AllowCloudWatchLogsEncryption"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:ReEncryptFrom",
      "kms:ReEncryptTo",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${local.account_id}:*"]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "KMS key for Phase 2 email classifier data at rest"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_s3_bucket" "raw_email" {
  bucket        = "${var.name_prefix}-${local.account_id}-${var.aws_region}-raw"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "raw_email" {
  bucket                  = aws_s3_bucket.raw_email.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "raw_email" {
  bucket = aws_s3_bucket.raw_email.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_email" {
  bucket = aws_s3_bucket.raw_email.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw_email" {
  bucket = aws_s3_bucket.raw_email.id

  rule {
    id     = "expire-raw-email"
    status = "Enabled"

    filter {
      prefix = local.raw_email_filter_prefix
    }

    expiration {
      days = var.raw_email_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

data "aws_iam_policy_document" "raw_email_bucket" {
  statement {
    sid = "AllowSESToWriteInboundEmail"
    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.raw_email.arn}/${local.raw_email_filter_prefix}*"]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [local.receipt_rule_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "raw_email" {
  bucket = aws_s3_bucket.raw_email.id
  policy = data.aws_iam_policy_document.raw_email_bucket.json
}

resource "aws_dynamodb_table" "email_metadata" {
  name                        = "${var.name_prefix}-metadata"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "email_id"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "email_id"
    type = "S"
  }

  attribute {
    name = "tenant_id"
    type = "S"
  }

  attribute {
    name = "received_at"
    type = "S"
  }

  global_secondary_index {
    name            = "tenant-received_at-index"
    hash_key        = "tenant_id"
    range_key       = "received_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.data.arn
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}

data "archive_file" "classifier_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambdas/classifier"
  output_path = "${path.module}/classifier_lambda.zip"
}

data "archive_file" "api_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambdas/api"
  output_path = "${path.module}/api_lambda.zip"
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "classifier_lambda" {
  name               = "${var.name_prefix}-classifier-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role" "api_lambda" {
  name               = "${var.name_prefix}-api-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "classifier_lambda" {
  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.classifier.arn}:*"]
  }

  statement {
    sid       = "ReadRawEmail"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.raw_email.arn}/${local.raw_email_filter_prefix}*"]
  }

  statement {
    sid       = "WriteMetadata"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.email_metadata.arn]
  }

  statement {
    sid = "UseComprehend"
    actions = [
      "comprehend:DetectDominantLanguage",
      "comprehend:DetectKeyPhrases",
      "comprehend:DetectSentiment",
    ]
    resources = ["*"]
  }

  statement {
    sid = "DecryptRawEmail"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.data.arn]
  }
}

data "aws_iam_policy_document" "api_lambda" {
  statement {
    sid = "WriteLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }

  statement {
    sid = "ReadAndDeleteMetadata"
    actions = [
      "dynamodb:DeleteItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
    ]
    resources = [
      aws_dynamodb_table.email_metadata.arn,
      "${aws_dynamodb_table.email_metadata.arn}/index/tenant-received_at-index",
    ]
  }

  statement {
    sid       = "DeleteRawEmailForUserDataRemoval"
    actions   = ["s3:DeleteObject"]
    resources = ["${aws_s3_bucket.raw_email.arn}/${local.raw_email_filter_prefix}*"]
  }

  statement {
    sid       = "DecryptMetadata"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
  }
}

resource "aws_iam_role_policy" "classifier_lambda" {
  name   = "${var.name_prefix}-classifier-policy"
  role   = aws_iam_role.classifier_lambda.id
  policy = data.aws_iam_policy_document.classifier_lambda.json
}

resource "aws_iam_role_policy" "api_lambda" {
  name   = "${var.name_prefix}-api-policy"
  role   = aws_iam_role.api_lambda.id
  policy = data.aws_iam_policy_document.api_lambda.json
}

resource "aws_cloudwatch_log_group" "classifier" {
  name              = "/aws/lambda/${var.name_prefix}-classifier"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${var.name_prefix}-api"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.data.arn
}

resource "aws_lambda_function" "classifier" {
  function_name    = "${var.name_prefix}-classifier"
  role             = aws_iam_role.classifier_lambda.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.classifier_lambda.output_path
  source_code_hash = data.archive_file.classifier_lambda.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME               = aws_dynamodb_table.email_metadata.name
      TENANT_ID                = var.tenant_id
      RAW_EMAIL_RETENTION_DAYS = tostring(var.raw_email_retention_days)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.classifier,
    aws_iam_role_policy.classifier_lambda,
  ]
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.name_prefix}-api"
  role             = aws_iam_role.api_lambda.arn
  handler          = "app.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.api_lambda.output_path
  source_code_hash = data.archive_file.api_lambda.output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME       = aws_dynamodb_table.email_metadata.name
      TENANT_ID        = var.tenant_id
      RAW_EMAIL_BUCKET = aws_s3_bucket.raw_email.bucket
      ALLOWED_ORIGINS  = join(",", var.api_allowed_origins)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.api,
    aws_iam_role_policy.api_lambda,
  ]
}

resource "aws_lambda_permission" "allow_s3_classifier" {
  statement_id  = "AllowS3InvokeClassifier"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.classifier.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw_email.arn
}

resource "aws_s3_bucket_notification" "raw_email" {
  bucket = aws_s3_bucket.raw_email.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.classifier.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.raw_email_filter_prefix
  }

  depends_on = [aws_lambda_permission.allow_s3_classifier]
}

resource "aws_apigatewayv2_api" "email_api" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["content-type", "authorization"]
    allow_methods = ["GET", "DELETE", "OPTIONS"]
    allow_origins = var.api_allowed_origins
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "email_api" {
  api_id                 = aws_apigatewayv2_api.email_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.email_api.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.email_api.id}"
}

resource "aws_apigatewayv2_route" "list_emails" {
  api_id    = aws_apigatewayv2_api.email_api.id
  route_key = "GET /emails"
  target    = "integrations/${aws_apigatewayv2_integration.email_api.id}"
}

resource "aws_apigatewayv2_route" "get_email" {
  api_id    = aws_apigatewayv2_api.email_api.id
  route_key = "GET /emails/{email_id}"
  target    = "integrations/${aws_apigatewayv2_integration.email_api.id}"
}

resource "aws_apigatewayv2_route" "delete_email" {
  api_id    = aws_apigatewayv2_api.email_api.id
  route_key = "DELETE /emails/{email_id}"
  target    = "integrations/${aws_apigatewayv2_integration.email_api.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.email_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigateway_api" {
  statement_id  = "AllowAPIGatewayInvokeAPI"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.email_api.execution_arn}/*/*"
}

resource "aws_s3_bucket" "dashboard" {
  bucket        = "${var.name_prefix}-${local.account_id}-${var.aws_region}-dashboard"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "${var.name_prefix}-dashboard-oac"
  description                       = "OAC for private dashboard S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "Phase 2 email classifier dashboard"

  origin {
    domain_name              = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_id                = "dashboard-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  default_cache_behavior {
    target_origin_id       = "dashboard-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

data "aws_iam_policy_document" "dashboard_bucket" {
  statement {
    sid = "AllowCloudFrontRead"
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.dashboard.arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.dashboard.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id
  policy = data.aws_iam_policy_document.dashboard_bucket.json
}

resource "aws_s3_object" "dashboard_assets" {
  for_each     = local.dashboard_files
  bucket       = aws_s3_bucket.dashboard.id
  key          = each.key
  source       = "${path.module}/../dashboard/${each.key}"
  content_type = each.value
  etag         = filemd5("${path.module}/../dashboard/${each.key}")
}

resource "aws_s3_object" "dashboard_config" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "config.js"
  content_type = "application/javascript"
  content = templatefile("${path.module}/../dashboard/config.template.js", {
    api_base_url = aws_apigatewayv2_stage.default.invoke_url
  })
}

resource "aws_cloudwatch_metric_alarm" "classifier_errors" {
  alarm_name          = "${var.name_prefix}-classifier-errors"
  alarm_description   = "Classifier Lambda has errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.classifier.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "${var.name_prefix}-api-errors"
  alarm_description   = "API Lambda has errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.api.function_name
  }
}

resource "aws_ses_domain_identity" "inbound" {
  count  = var.enable_ses_receiving && var.ses_domain != "" ? 1 : 0
  domain = var.ses_domain
}

resource "aws_ses_receipt_rule_set" "inbound" {
  count         = var.enable_ses_receiving ? 1 : 0
  rule_set_name = local.receipt_rule_set_name
}

resource "aws_ses_receipt_rule" "store_raw_email" {
  count         = var.enable_ses_receiving ? 1 : 0
  name          = local.receipt_rule_name
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
  recipients    = var.email_recipients
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"

  s3_action {
    bucket_name       = aws_s3_bucket.raw_email.bucket
    object_key_prefix = local.raw_email_filter_prefix
    position          = 1
  }

  depends_on = [aws_s3_bucket_policy.raw_email]
}

resource "aws_ses_active_receipt_rule_set" "inbound" {
  count         = var.enable_ses_receiving && var.activate_ses_rule_set ? 1 : 0
  rule_set_name = aws_ses_receipt_rule_set.inbound[0].rule_set_name
}
