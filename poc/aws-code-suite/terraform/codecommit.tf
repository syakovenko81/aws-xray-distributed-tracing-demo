resource "aws_codecommit_repository" "poc" {
  repository_name = var.codecommit_repository_name
  description     = "Isolated AWS Code Suite Lambda CI/CD PoC source repository"
}
