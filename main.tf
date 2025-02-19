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

# VPC 및 서브넷 설정
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  
  tags = {
    Name = "main-vpc"
  }
}

# 퍼블릭 서브넷 2개 생성
resource "aws_subnet" "public" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  
  tags = {
    Name = "public-subnet-${count.index}"
  }
}

# 프라이빗 서브넷 2개 생성
resource "aws_subnet" "private" {
  count = 2
  vpc_id = aws_vpc.main.id
  cidr_block = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]
  
  tags = {
    Name = "private-subnet-${count.index}"
  }
}

# 가용 영역 데이터 소스
data "aws_availability_zones" "available" {}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  
  tags = {
    Name = "main-igw"
  }
}

# NAT Gateway를 위한 EIP
resource "aws_eip" "nat" {
  domain = "vpc"
  
  tags = {
    Name = "nat-eip"
  }
}

# NAT Gateway
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id = aws_subnet.public[0].id
  
  tags = {
    Name = "main-nat"
  }
}

# 퍼블릭 라우팅 테이블
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  
  tags = {
    Name = "public-rt"
  }
}

# 프라이빗 라우팅 테이블
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  
  tags = {
    Name = "private-rt"
  }
}

# 라우팅 테이블 연결
resource "aws_route_table_association" "public" {
  count = 2
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = 2
  subnet_id = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ElastiCache (Redis) 보안 그룹
resource "aws_security_group" "redis" {
  name = "redis-sg"
  description = "Security group for Redis"
  vpc_id = aws_vpc.main.id
  
  ingress {
    from_port = 6379
    to_port = 6379
    protocol = "tcp"
    security_groups = [aws_security_group.ecs.id]
  }
  
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "redis-sg"
  }
}

# ElastiCache 서브넷 그룹
resource "aws_elasticache_subnet_group" "redis" {
  name = "redis-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

# ElastiCache Redis 클러스터
resource "aws_elasticache_cluster" "redis" {
  cluster_id = "spring-redis"
  engine = "redis"
  node_type = "cache.t2.micro"  # 필요에 따라 조정
  num_cache_nodes = 1
  parameter_group_name = "default.redis6.x"
  engine_version = "6.x"
  port = 6379
  subnet_group_name = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]
}

# ECS 클러스터
resource "aws_ecs_cluster" "main" {
  name = "spring-boot-cluster"
}

# ECR 리포지토리
resource "aws_ecr_repository" "app" {
  name = "spring-boot-app"
}

# ECS 태스크 실행 역할
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs-execution-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# 태스크 실행 역할에 필요한 정책 연결
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS 보안 그룹
resource "aws_security_group" "ecs" {
  name = "ecs-sg"
  description = "Security group for ECS tasks"
  vpc_id = aws_vpc.main.id
  
  ingress {
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "ecs-sg"
  }
}

# ECS 태스크 정의
resource "aws_ecs_task_definition" "app" {
  family = "spring-boot-app"
  network_mode = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu = "256"
  memory = "512"
  execution_role_arn = aws_iam_role.ecs_execution_role.arn
  
  container_definitions = jsonencode([
    {
      name = "spring-boot-app"
      image = "${aws_ecr_repository.app.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort = 8080
        }
      ]
      environment = [
        {
          name = "SPRING_DATA_REDIS_HOST"
          value = aws_elasticache_cluster.redis.cache_nodes[0].address
        },
        {
          name = "SPRING_DATA_REDIS_PORT"
          value = "6379"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = aws_cloudwatch_log_group.app.name
          "awslogs-region" = "ap-northeast-2"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# CloudWatch 로그 그룹
resource "aws_cloudwatch_log_group" "app" {
  name = "/ecs/spring-boot-app"
  retention_in_days = 30
}

# Application Load Balancer
resource "aws_lb" "app" {
  name = "spring-boot-alb"
  internal = false
  load_balancer_type = "application"
  security_groups = [aws_security_group.alb.id]
  subnets = aws_subnet.public[*].id
  
  tags = {
    Name = "spring-boot-alb"
  }
}

# ALB 보안 그룹
resource "aws_security_group" "alb" {
  name = "alb-sg"
  description = "Security group for ALB"
  vpc_id = aws_vpc.main.id
  
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "alb-sg"
  }
}

# ALB 타겟 그룹
resource "aws_lb_target_group" "app" {
  name = "spring-boot-tg"
  port = 8080
  protocol = "HTTP"
  vpc_id = aws_vpc.main.id
  target_type = "ip"
  
  health_check {
    path = "/actuator/health"
    interval = 30
    timeout = 5
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

# ALB 리스너
resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.app.arn
  port = 80
  protocol = "HTTP"
  
  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ECS 서비스
resource "aws_ecs_service" "app" {
  name = "spring-boot-service"
  cluster = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count = 2
  launch_type = "FARGATE"
  
  network_configuration {
    subnets = aws_subnet.private[*].id
    security_groups = [aws_security_group.ecs.id]
    assign_public_ip = false
  }
  
  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name = "spring-boot-app"
    container_port = 8080
  }
  
  depends_on = [aws_lb_listener.app]
}

# 출력 정보
output "alb_dns_name" {
  value = aws_lb.app.dns_name
  description = "Application Load Balancer DNS Name"
}

output "redis_endpoint" {
  value = aws_elasticache_cluster.redis.cache_nodes[0].address
  description = "ElastiCache Redis Endpoint"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
  description = "ECR Repository URL"
}