terraform {
  backend "s3" {
    bucket         = "sportlink-terraform-backend"
    key            = "Prod/route53/terraform.tfstate"
    region         = "ap-northeast-2"
    profile        = "terraform_user"
    dynamodb_table = "sportlink-terraform-bucket-lock"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform_user"
}

resource "aws_acm_certificate" "sportlink_store" {
  domain_name               = "sportlink.store"
  subject_alternative_names = ["*.sportlink.store"]
  validation_method         = "DNS"

  tags = {
    Name = "prod-acm-sportlink.store"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_zone" "sportlink_store" {
  name = "sportlink.store"
}

resource "aws_route53_record" "sportlink_store_validation" {
  for_each = {
    for dvo in aws_acm_certificate.sportlink_store.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id = aws_route53_zone.sportlink_store.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "sportlink_store" {
  certificate_arn         = aws_acm_certificate.sportlink_store.arn
  validation_record_fqdns = [
    for record in aws_route53_record.sportlink_store_validation : record.fqdn
  ]
}

# Argo CD 관리용 도메인
resource "aws_route53_record" "argocd_sportlink_store" {
  zone_id = aws_route53_zone.sportlink_store.zone_id
  name    = "argocd.sportlink.store"
  type    = "CNAME"
  ttl     = 60
  records = ["aad4050f9e31d49b981d4f5c788f6bf9-1879551068.ap-northeast-2.elb.amazonaws.com"] # 실제 CNAME 값으로 대체
}

# Grafana 관리용 도메인
resource "aws_route53_record" "grafana_sportlink_store" {
  zone_id = aws_route53_zone.sportlink_store.zone_id
  name    = "grafana.sportlink.store"
  type    = "A"
  ttl     = 60
  records = ["13.124.204.74"] # 그라파나 인스턴스 ip
}
