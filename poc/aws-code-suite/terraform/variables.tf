variable "region" {
  description = "AWS region for the isolated PoC."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short, unique prefix for PoC resources."
  type        = string
  default     = "aws-code-suite-lambda-poc"
}

variable "environment" {
  description = "Environment label used in resource names and tags."
  type        = string
  default     = "poc"
}

variable "codecommit_repository_name" {
  description = "Name of the dedicated CodeCommit repository."
  type        = string
  default     = "aws-code-suite-lambda-poc"
}

variable "lambda_alias_name" {
  description = "Stable alias moved by CodeDeploy during deployment."
  type        = string
  default     = "live"
}

variable "artifact_bucket_force_destroy" {
  description = "Delete all versioned artifact objects during terraform destroy."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags for all supported AWS resources."
  type        = map(string)
  default     = {}
}
