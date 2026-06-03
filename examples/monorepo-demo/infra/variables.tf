variable "aws_region" {
  description = "AWS region for demo resources"
  type        = string
  default     = "eu-central-1"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "monorepo-demo"
}
