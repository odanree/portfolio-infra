# Ubuntu 24.04 LTS, latest amd64 image from Canonical (account 099720109477).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "marquez_oci" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.instance.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
    tags = {
      Name = "${var.tag_name}-root"
    }
  }

  # Bootstrap: install docker + compose. Application stack is dropped in via
  # scp/rsync after `terraform apply` — see ../scripts/deploy-app.sh.
  user_data = <<-EOF
              #!/bin/bash
              set -eux
              apt-get update -y
              # `awscli` (v1) was dropped from Ubuntu 24.04 archives; AWS CLI v2
              # ships as a snap. docker.io + docker-compose-v2 stay on apt.
              DEBIAN_FRONTEND=noninteractive apt-get install -y \
                  docker.io \
                  docker-compose-v2 \
                  jq
              snap install aws-cli --classic
              usermod -aG docker ubuntu
              systemctl enable --now docker
              mkdir -p /opt/app
              chown -R ubuntu:ubuntu /opt/app
              EOF

  user_data_replace_on_change = false

  tags = {
    Name = var.tag_name
  }

  lifecycle {
    ignore_changes = [
      ami,       # Don't rebuild the box every time Canonical publishes a new AMI
      user_data, # Bootstrap script changes are out-of-band; don't trigger a replacement
    ]
  }
}

resource "aws_eip" "instance" {
  domain   = "vpc"
  instance = aws_instance.marquez_oci.id

  tags = {
    Name = "${var.tag_name}-eip"
  }
}
