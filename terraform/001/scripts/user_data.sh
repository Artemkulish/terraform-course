#!/bin/bash

apt update
apt install -y nginx

echo "<center>Hello from EC2 instance! My AZ is $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone) <br> My hostname is $(curl -s http://169.254.169.254/latest/meta-data/hostname)" > /var/www/html/index.html
