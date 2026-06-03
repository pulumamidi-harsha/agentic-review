resource "aws_s3_bucket" "demo" {
  bucket = "${var.project_name}-artifacts"

  tags = {
    Project = var.project_name
    Managed = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}
