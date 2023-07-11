# output "ec2_instance_public_ip" {
#   value = {
#     for k, v in aws_eip.web : k => v.public_ip
#   }
# }

output "alb_public_dns" {
  value = aws_alb.this.dns_name
}
