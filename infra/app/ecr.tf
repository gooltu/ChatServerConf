# Image pushed here by a separate deploy step (not this Terraform) —
# likely from the other Claude Code session working on ServerProjextX
# itself. infra/iam's nodeapp-runtime-role already grants pull-only access
# to exactly this repo.
resource "aws_ecr_repository" "serverprojectx" {
  name = "serverprojectx"

  image_scanning_configuration {
    scan_on_push = true
  }
}
