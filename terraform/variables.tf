variable "aws_region" {
  description = "AWS region for the proof of concept. eu-central-1 keeps data in Frankfurt and supports SES receiving."
  type        = string
  default     = "eu-central-1"
}

variable "name_prefix" {
  description = "Lowercase prefix used for AWS resource names."
  type        = string
  default     = "email-classifier-p2"
}

variable "tenant_id" {
  description = "Logical tenant/team key used for DynamoDB queries."
  type        = string
  default     = "support-team"
}

variable "raw_email_prefix" {
  description = "S3 prefix for raw inbound emails."
  type        = string
  default     = "incoming/"
}

variable "raw_email_retention_days" {
  description = "Retention period for raw emails in S3 and DynamoDB TTL."
  type        = number
  default     = 30
}

variable "api_allowed_origins" {
  description = "CORS origins for the API Gateway HTTP API."
  type        = list(string)
  default     = ["*"]
}

variable "enable_deletion_protection" {
  description = "Enables DynamoDB deletion protection for production-like deployments."
  type        = bool
  default     = false
}

variable "enable_ses_receiving" {
  description = "Creates SES receiving resources. Keep false until a receiving domain is verified and MX records are ready."
  type        = bool
  default     = false
}

variable "activate_ses_rule_set" {
  description = "Activates the created SES rule set. Only set true if this account should receive mail for the configured domain."
  type        = bool
  default     = false
}

variable "ses_domain" {
  description = "Domain to verify for SES receiving, for example example.com. Leave empty for S3 upload based testing."
  type        = string
  default     = ""
}

variable "email_recipients" {
  description = "Recipient addresses handled by the SES receipt rule."
  type        = list(string)
  default     = ["support@example.com"]
}

variable "tags" {
  description = "Additional tags applied to AWS resources."
  type        = map(string)
  default     = {}
}

