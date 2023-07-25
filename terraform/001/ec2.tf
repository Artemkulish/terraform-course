locals {
  name_prefix = "${var.environment}-${var.project}"
  ec2_instances = {
    first = {
      type = "t2.micro"
      az   = "us-east-1a"
    },
    second = {
      type = "t3.micro"
      az   = "us-east-1b"
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  owners = ["099720109477"]
}

resource "aws_eip" "web" {
  for_each = local.ec2_instances

  instance = aws_instance.web[each.key].id
}

resource "aws_instance" "web" {
  for_each = local.ec2_instances

  ami               = data.aws_ami.ubuntu.id
  instance_type     = each.value.type
  security_groups   = [aws_security_group.web.name]
  key_name          = aws_key_pair.web.key_name
  availability_zone = each.value.az

  user_data = <<EOF
#!/bin/bash

apt update
apt install -y nginx

echo "<center>Hello from EC2 instance! My AZ is $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone) <br> My hostname is $(curl -s http://169.254.169.254/latest/meta-data/hostname)" > /var/www/html/index.html
EOF

  tags = {
    Name = "${local.name_prefix}-web-${each.key}"
  }
}

resource "aws_key_pair" "web" {
  public_key = file("${path.root}/demo_rsa.pub")
}

resource "aws_security_group" "web" {
  name        = "${local.name_prefix}-sg"
  description = "SG for web EC2 instance"

  ingress {
    description = "Open 80 port for Nginx"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Open 22 port for testing purposees"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
