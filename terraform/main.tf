terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_key_pair" "blogify_key" {
  key_name   = "blogify-key"
  public_key = file(var.public_key_path)
}

resource "aws_security_group" "blogify_sg" {
  name        = "blogify-sg"
  description = "Allow HTTP, HTTPS, SSH, and service management UIs"

  ingress { description = "SSH"   from_port = 22   to_port = 22   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { description = "HTTP"  from_port = 80   to_port = 80   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  ingress { description = "HTTPS" from_port = 443  to_port = 443  protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }

  # Monitoring (restrict to your IP in production)
  ingress { description = "Grafana"    from_port = 3100 to_port = 3100 protocol = "tcp" cidr_blocks = [var.admin_cidr] }
  ingress { description = "Prometheus" from_port = 9090 to_port = 9090 protocol = "tcp" cidr_blocks = [var.admin_cidr] }
  ingress { description = "RabbitMQ UI" from_port = 15672 to_port = 15672 protocol = "tcp" cidr_blocks = [var.admin_cidr] }
  ingress { description = "MinIO console" from_port = 9001 to_port = 9001 protocol = "tcp" cidr_blocks = [var.admin_cidr] }

  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }

  tags = { Name = "blogify-sg" }
}

resource "aws_instance" "blogify_server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.blogify_key.key_name
  vpc_security_group_ids = [aws_security_group.blogify_sg.id]

  root_block_device {
    volume_size = 30   # Microservices + monitoring need more headroom than free-tier 8GB default
    volume_type = "gp3"
  }

  tags = {
    Name        = "blogify-server"
    Environment = "production"
    Project     = "blogify-microservices"
  }
}

resource "aws_eip" "blogify_eip" {
  instance = aws_instance.blogify_server.id
  domain   = "vpc"
  tags     = { Name = "blogify-eip" }
}
