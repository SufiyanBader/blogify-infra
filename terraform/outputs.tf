output "server_ip" {
  value = aws_eip.blogify_eip.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.blogify_eip.public_ip}"
}
