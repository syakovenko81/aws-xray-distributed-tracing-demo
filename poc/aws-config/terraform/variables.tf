variable "region" {
  description = "AWS region for the isolated AWS Config PoC."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = var.region == "us-east-1"
    error_message = "This PoC is intentionally restricted to us-east-1."
  }
}

variable "project_name" {
  description = "Short project prefix used in AWS Config resource names."
  type        = string
  default     = "aws-config-poc"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "project_name must be 3-24 lowercase letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment label used in resource names and tags."
  type        = string
  default     = "poc"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must be 2-12 lowercase letters, numbers, or hyphens."
  }
}

variable "tags" {
  description = "Additional tags for supported AWS resources."
  type        = map(string)
  default     = {}
}
