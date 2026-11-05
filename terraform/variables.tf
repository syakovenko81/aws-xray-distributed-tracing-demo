variable "region" {
  description = "AWS region for all resources. The ADOT layer must be published in this region."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name used in resource names."
  type        = string
  default     = "aws-xray-demo"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "project_name must be 3-24 lowercase letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment name used in resource names."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9-]{2,12}$", var.environment))
    error_message = "environment must be 2-12 lowercase letters, numbers, or hyphens."
  }
}

variable "adot_python_layer_arn" {
  description = "Current AWS-managed ADOT Python Lambda layer ARN for the selected region."
  type        = string
  default     = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"
}
