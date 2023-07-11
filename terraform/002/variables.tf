variable "ssh_public_key" {
  default     = null
  type        = string
  description = "SSH public key to be used to connect to EC2 instances."
}
