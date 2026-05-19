output "raw_email_bucket" {
  description = "S3 bucket for raw inbound emails and manual .eml test uploads."
  value       = aws_s3_bucket.raw_email.bucket
}

output "raw_email_prefix" {
  description = "Prefix that triggers the classifier Lambda."
  value       = local.raw_email_filter_prefix
}

output "metadata_table" {
  description = "DynamoDB table containing classification metadata."
  value       = aws_dynamodb_table.email_metadata.name
}

output "api_base_url" {
  description = "HTTP API base URL for dashboard/API tests."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "dashboard_url" {
  description = "HTTPS dashboard URL served by CloudFront."
  value       = "https://${aws_cloudfront_distribution.dashboard.domain_name}"
}

output "ses_domain_verification_token" {
  description = "TXT token for SES domain verification when ses_domain is set."
  value       = try(aws_ses_domain_identity.inbound[0].verification_token, null)
}

output "ses_mx_record_value" {
  description = "MX value for SES email receiving in the configured AWS region."
  value       = "10 inbound-smtp.${var.aws_region}.amazonaws.com"
}

