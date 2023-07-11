resource "aws_launch_template" "web" {
  name = "${local.name_prefix}-launch-template"

  image_id      = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  key_name      = aws_key_pair.web.key_name

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = filebase64("${path.root}/scripts/user_data.sh")

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name_prefix}-nginx"
    }
  }
}

resource "aws_autoscaling_group" "web" {
  name = "${local.name_prefix}-autoscaling-group"

  max_size = 2
  min_size = 1

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.this.arn]
}

resource "aws_autoscaling_policy" "name" {
  name        = "${local.name_prefix}-autoscaling-policy-cpu"
  policy_type = "TargetTrackingScaling"

  autoscaling_group_name = aws_autoscaling_group.web.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 30
  }
}
