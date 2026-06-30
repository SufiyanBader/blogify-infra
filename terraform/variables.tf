variable "aws_region" {
  type    = string
  default = "ap-south-1"   # Mumbai
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI for ap-south-1 — verify/update before apply"
  type        = string
  default     = "ami-0f58b397bc5c1f2e8"
}

variable "instance_type" {
  description = "t2.micro is free-tier but tight for 6 services + monitoring. t3.small recommended if budget allows."
  type        = string
  default     = "t2.micro"
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "admin_cidr" {
  description = "Your IP/32 for restricting access to admin UIs (Grafana, Prometheus, RabbitMQ, MinIO). Use 0.0.0.0/0 only for testing."
  type        = string
  default     = "0.0.0.0/0"
}
