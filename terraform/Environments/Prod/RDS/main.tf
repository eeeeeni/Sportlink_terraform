terraform {
  backend "s3" {
    bucket         = "sportlink-terraform-backend"
    key            = "Prod/RDS/terraform.tfstate"
    region         = "ap-northeast-2"
    profile        = "terraform_user"
    dynamodb_table = "sportlink-terraform-bucket-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform_user"
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket         = "sportlink-terraform-backend"
    key            = "Prod/VPC/terraform.tfstate"
    region         = "ap-northeast-2"
    profile        = "terraform_user"
    dynamodb_table = "sportlink-terraform-bucket-lock"
    encrypt        = true
  }
}

# Secrets Manager 설정
resource "aws_secretsmanager_secret" "db_secret" {
  name = "sportlink-prod-rds-name-and-password"
}

resource "aws_secretsmanager_secret_version" "db_secret_version" {
  secret_id     = aws_secretsmanager_secret.db_secret.id
  secret_string = jsonencode({
    db_username = var.DB_USERNAME
    db_password = var.DB_PASSWORD
  })
}

# RDS SG
module "RDS_SG" {
  source          = "github.com/eeeeeni/Terraform-project-SG"
  name            = "prod-rds-sg"
  description     = "DB Port Allow"
  vpc_id          = data.terraform_remote_state.vpc.outputs.vpc_id
  use_name_prefix = false

  ingress_with_cidr_blocks = [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "DB Port Allow"
      cidr_blocks = data.terraform_remote_state.vpc.outputs.private_subnets[0]
    },
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "DB Port Allow"
      cidr_blocks = data.terraform_remote_state.vpc.outputs.private_subnets[1]
    }
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
}

resource "aws_db_subnet_group" "default" {
  name       = "prod-rds-subnet-group"
  subnet_ids = data.terraform_remote_state.vpc.outputs.database_subnet_ids

  tags = {
    Name = "prod-rds-subnet-group"
  }
}

module "rds" {
  source                              = "github.com/eeeeeni/Terraform-project-RDS"
  identifier                          = "prod-rds"
  engine                              = "mysql"
  engine_version                      = "5.7"
  instance_class                      = "db.t3.micro"
  allocated_storage                   = 5
  multi_az                            = true
  iam_database_authentication_enabled = true
  manage_master_user_password         = false
  skip_final_snapshot                 = true
  family                              = "mysql5.7"
  parameters = [
    {
      name  = "character_set_client"
      value = "utf8mb4"
    },
    {
      name  = "character_set_server"
      value = "utf8mb4"
    }
  ]
  major_engine_version = "5.7"
  db_name              = "proddb"
  username             = jsondecode(aws_secretsmanager_secret_version.db_secret_version.secret_string).db_username
  password             = jsondecode(aws_secretsmanager_secret_version.db_secret_version.secret_string).db_password
  port                 = 3306

  subnet_ids             = data.terraform_remote_state.vpc.outputs.database_subnet_ids
  vpc_security_group_ids = [module.RDS_SG.security_group_id]
  db_subnet_group_name   = aws_db_subnet_group.default.name
}
