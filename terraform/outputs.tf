output "instance_id" {
  value = aws_instance.vm.id
}

output "public_ip" {
  value = aws_instance.vm.public_ip
}

output "ssh_private_key_path" {
  value = abspath(local_sensitive_file.ssh_private_key.filename)
}

output "ssh_command" {
  value = "ssh -i ${abspath(local_sensitive_file.ssh_private_key.filename)} ubuntu@${aws_instance.vm.public_ip}"
}

# Local ports on the laptop -> 127.0.0.1 ports on the VM (kind extraPortMappings).
output "ssh_tunnel_command" {
  description = "Forward the Redis DB (12000), RE REST API (9443) and RE admin UI (8443) to localhost."
  value       = "ssh -i ${abspath(local_sensitive_file.ssh_private_key.filename)} -N -L 12000:127.0.0.1:12000 -L 9443:127.0.0.1:9443 -L 8443:127.0.0.1:8443 ubuntu@${aws_instance.vm.public_ip}"
}

output "ssh_allowed_cidrs" {
  value = local.ssh_cidrs
}

output "tags" {
  value = local.common_tags
}
