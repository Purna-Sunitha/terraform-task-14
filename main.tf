## main.tf ##

resource "aws_vpc" "my-vpc" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = var.vpc_name
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = var.igw_name
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.my-vpc.id

  route {
    cidr_block = var.pub_rt_igw_access_cidr
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = var.rt_name
  }
}

resource "aws_subnet" "subnets" {
  for_each = { for idx, subnet in var.subnets : subnet.name => subnet }

  vpc_id                  = aws_vpc.my-vpc.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = each.value.type == "loadbalancer"|| each.value.type == "jumpserver" ? true : false

  tags = {
    Name = each.value.name
    type = each.value.type
  }
}

resource "aws_route_table_association" "public_subnet_association" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.type == "loadbalancer"|| subnet.type == "jumpserver" }
  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.public_rt.id
} 

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.my-vpc.id

  tags = {
    Name = var.pri_rt
  }
}

resource "aws_route_table_association" "private_subnet_association" {
  for_each = { for subnet in var.subnets : subnet.name => subnet if subnet.type == "application" || subnet.type == "database" }

  subnet_id      = aws_subnet.subnets[each.key].id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_lb" "main" {
  name               = "my-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets = distinct([
  for az, subnet in { for s in aws_subnet.subnets : s.availability_zone => s if s.tags["type"] == "loadbalancer" } :
  subnet.id
])
  tags = {
    Name = var.lb_name
  }
}

resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.my-vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.sg_name
  }
}
resource "aws_security_group" "rds_sg" {
  vpc_id = aws_vpc.my-vpc.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  tags = {
    Name = "rds-sg"
  }
}
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = [
    for subnet in aws_subnet.subnets : subnet.id
    if lookup({ for s in var.subnets : s.name => s if s.name != null }, subnet.tags.Name, null) != null
    && lookup({ for s in var.subnets : s.name => s if s.name != null }, subnet.tags.Name, null).type == "database"
  ]

}
resource "aws_db_instance" "wordpress_db" {
  identifier            = var.db_identifier_name
  engine               = var.db_engine
  instance_class       = var.db_instance_type
  allocated_storage    = var.db_storage
  username            = var.db_username
  password            = var.db_passwd
  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  publicly_accessible  = false
  skip_final_snapshot  = true
}

resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.my-vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-sg"
  }
}

resource "aws_instance" "wordpress" {
  ami           = var.ami_id
  instance_type = var.instance_type
  subnet_id = aws_subnet.subnets["jump_subnet"].id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
 
  user_data = <<-EOF
  #!/bin/bash
  sudo yum update -y
  sudo yum install -y httpd php php-mysqlnd wget unzip
  sudo systemctl start httpd
  sudo systemctl enable httpd
  cd /var/www/html
  wget https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz
  mv wordpress/* .
  rm -rf wordpress latest.tar.gz
  cp wp-config-sample.php wp-config.php

  # Set database details in wp-config.php
  RDS_ENDPOINT="${aws_db_instance.wordpress_db.endpoint}"
  sed -i "s/database_name_here/wordpressdb/" wp-config.php
  sed -i "s/username_here/wp_user/" wp-config.php
  sed -i "s/password_here/wp_password/" wp-config.php
  sed -i "s/localhost/$RDS_ENDPOINT/" wp-config.php

  sudo systemctl restart httpd
  EOF

  tags = {
    Name = var.instance_name
  }
}
