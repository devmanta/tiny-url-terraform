terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
}

resource "aws_instance" "tiny-url-instance" {
  ami           = "ami-024ea438ab0376a47"
  instance_type = "t2.micro"
  
  tags = {
    Name = "tiny-url-instance"
  }
}
