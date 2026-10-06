output "mongooseim_runtime_role_arn" {
  value = aws_iam_role.mongooseim_runtime.arn
}

output "mongooseim_instance_profile_name" {
  value = aws_iam_instance_profile.mongooseim_runtime.name
}

output "nodeapp_runtime_role_arn" {
  value = aws_iam_role.nodeapp_runtime.arn
}

output "nodeapp_instance_profile_name" {
  value = aws_iam_instance_profile.nodeapp_runtime.name
}
