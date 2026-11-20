data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# This role already exists in the audited account. It is intentionally a data
# source so Terraform cannot create, update, or delete the service-linked role.
data "aws_iam_role" "config_service_linked" {
  name = "AWSServiceRoleForConfig"
}
