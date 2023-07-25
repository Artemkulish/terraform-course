terraform {
  backend "s3" {
    bucket         = "devops-demo-tf-remote-state-001"
    key            = "demo/terraform.tfstate"
    dynamodb_table = "tf-remote-state-lock"
    region         = "us-east-1"
  }
}

provider "aws" {
  region = local.region

  default_tags {
    tags = {
      Project     = local.project
      Environment = local.environment
      Managed     = "Terraform"
    }
  }
}

data "aws_availability_zones" "available" {}

locals {
  region      = "us-east-1"
  project     = "devops-course"
  environment = "dev"
  name        = "${local.environment}-${local.project}"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  container_name = "app"
  container_port = 80

  image  = "public.ecr.aws/ecs-sample-image/amazon-ecs-sample:latest"
  cpu    = 1024
  memory = 970
}


################################################
# VPC
################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs            = local.azs
  public_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
}

################################################
# ALB
################################################
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.0"

  name = local.name

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [module.alb_sg.security_group_id]

  http_tcp_listeners = [
    {
      port               = local.container_port
      protocol           = "HTTP"
      target_group_index = 0
    },
  ]

  target_groups = [
    {
      name             = "${local.name}-${local.container_name}-blue"
      backend_protocol = "HTTP"
      backend_port     = local.container_port
      target_type      = "ip"
    },
    {
      name             = "${local.name}-${local.container_name}-green"
      backend_protocol = "HTTP"
      backend_port     = local.container_port
      target_type      = "ip"
    }
  ]

  http_tcp_listener_rules = [
    {
      http_tcp_listener_index = 0
      priority                = 10

      actions = [{
        type = "weighted-forward"
        target_groups = [
          {
            target_group_index = 0
            weight             = 100
          },
          {
            target_group_index = 1
            weight             = 0
          }
        ]
      }]

      conditions = [{
        path_patterns = ["/*"]
      }]
    },
  ]
}

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = "${local.name}-service"
  description = "Service security group"
  vpc_id      = module.vpc.vpc_id

  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]

  egress_rules       = ["all-all"]
  egress_cidr_blocks = ["0.0.0.0/0"]
}

################################################
# Autoscaling
################################################
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"

  for_each = {
    ex-1 = {
      instance_type = "t2.micro"
      user_data     = <<-EOT
        #!/bin/bash
        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}
        EOF
      EOT
    }
  }

  name = "${local.name}-${each.key}"

  image_id      = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = each.value.instance_type

  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true

  network_interfaces = [{
    associate_public_ip_address = true
  }]

  create_iam_instance_profile = true
  iam_role_name               = local.name
  iam_role_description        = "ECS role for ${local.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.public_subnets
  health_check_type   = "EC2"
  min_size            = 4
  max_size            = 4
  desired_capacity    = 4

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for  managed_termination_protection = "ENABLED"
  protect_from_scale_in = true
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 4.0"

  name        = local.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.alb_sg.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1

  ingress_with_cidr_blocks = [
    {
      rule        = "ssh-tcp"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  egress_rules = ["all-all"]
}

################################################################
# ECS Cluster
################################################################
module "ecs_cluster" {
  source = "terraform-aws-modules/ecs/aws//modules/cluster"

  cluster_name = local.name

  # Capacity provider - autoscaling groups
  default_capacity_provider_use_fargate = false
  autoscaling_capacity_providers = {
    # On-demand instances
    ex-1 = {
      auto_scaling_group_arn         = module.autoscaling["ex-1"].autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        status = "ENABLED"
      }

      default_capacity_provider_strategy = {
        weight = 100
        base   = 1
      }
    }
  }
}


################################################
# ECS Service - blue
################################################
module "ecs_service_blue" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = "${local.name}-blue"
  cluster_arn = module.ecs_cluster.arn

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    # On-demand instances
    ex-1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["ex-1"].name
      weight            = 1
      base              = 1
    }
  }

  desired_count                      = 2
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  # Container definition(s)
  container_definitions = {
    (local.container_name) = {
      cpu    = local.cpu
      memory = local.memory
      image  = local.image
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]
      readonly_root_filesystem = false
    }
  }

  cpu    = local.cpu
  memory = local.memory

  load_balancer = {
    service = {
      target_group_arn = element(module.alb.target_group_arns, 0)
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.public_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb_sg.security_group_id
    }
  }
}

resource "aws_ecr_repository" "foo" {
  name                 = "${local.name}-ecr"
  image_tag_mutability = "MUTABLE"
}

################################################
# ECS Service - green
################################################
module "ecs_service_green" {
  source = "terraform-aws-modules/ecs/aws//modules/service"

  # Service
  name        = "${local.name}-green"
  cluster_arn = module.ecs_cluster.arn

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    # On-demand instances
    ex-1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["ex-1"].name
      weight            = 1
      base              = 1
    }
  }

  desired_count                      = 2
  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0

  # Container definition(s)
  container_definitions = {
    (local.container_name) = {
      cpu    = local.cpu
      memory = local.memory
      image  = local.image
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          protocol      = "tcp"
        }
      ]
      readonly_root_filesystem = false
    }
  }

  cpu    = local.cpu
  memory = local.memory

  load_balancer = {
    service = {
      target_group_arn = element(module.alb.target_group_arns, 1)
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  subnet_ids = module.vpc.public_subnets
  security_group_rules = {
    alb_http_ingress = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Service port"
      source_security_group_id = module.alb_sg.security_group_id
    }
  }
}
