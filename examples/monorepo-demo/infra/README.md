# Infra (Terraform)

Demo IaC stack for ai-review monorepo testing.

```bash
terraform init
terraform validate
terraform fmt -check -recursive
```

No real AWS apply required for the review pipeline — validation is enough.
