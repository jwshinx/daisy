terraform {
  backend "s3" {
    bucket         = "jft-daisy-tfstate"
    key            = "development.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "daisy-tf-state-lock"
  }

  required_providers {
    aws = "~> 3.24.0"
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_region" "current" {}

resource "aws_ecs_cluster" "weather_cluster" {
  name = "weather-cluster"
}

#####################################################################
# task definition
#####################################################################
resource "aws_ecs_task_definition" "weather_task" {
  family                   = "weather" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "weather",
      "image": "${var.ecr_image}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  memory                   = 512
  cpu                      = 256
  execution_role_arn       = aws_iam_role.task_execution_role.arn
  task_role_arn            = aws_iam_role.app_iam_role.arn
}

resource "aws_iam_role" "task_execution_role" {
  name               = "weather-task-exec-role"
  assume_role_policy = file("./templates/ecs/assume-role-policy.json")
}

resource "aws_iam_role" "app_iam_role" {
  # role necessary for runtime
  name               = "weather-app-iam-role-task"
  assume_role_policy = file("./templates/ecs/assume-role-policy.json")
}

# resource "aws_iam_role" "task_execution_role" {
#   name               = "task_execution_role"
#   assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
# }

# data "aws_iam_policy_document" "assume_role_policy" {
#   statement {
#     actions = ["sts:AssumeRole"]

#     principals {
#       type        = "Service"
#       identifiers = ["ecs-tasks.amazonaws.com"]
#     }
#   }
# }

resource "aws_iam_policy" "task_execution_role_policy" {
  name        = "weather-task-exec-role-policy"
  path        = "/"
  description = "Allow retrieving images and adding to logs"
  policy      = file("./templates/ecs/task-exec-role.json")
}

resource "aws_iam_role_policy_attachment" "task_execution_role" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = aws_iam_policy.task_execution_role_policy.arn
}

resource "aws_iam_role_policy_attachment" "task_execution_role_policy" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

#####################################################################
# service
#####################################################################
resource "aws_ecs_service" "weather_service" {
  name            = "weather-service"
  cluster         = aws_ecs_cluster.weather_cluster.id
  task_definition = aws_ecs_task_definition.weather_task.arn
  launch_type     = "FARGATE"
  desired_count   = 3

  network_configuration {
    security_groups = [aws_security_group.service_security_group.id]
    subnets = [
      aws_default_subnet.default_subnet_a.id,
      aws_default_subnet.default_subnet_b.id,
      aws_default_subnet.default_subnet_c.id,
    ]
    assign_public_ip = true # Providing our containers with public IPs
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.weather_tg.arn # Referencing our target group
    container_name   = aws_ecs_task_definition.weather_task.family
    container_port   = 3000
  }
}

resource "aws_security_group" "service_security_group" {
  description = "allow access to application load balancer"
  name        = "weather-service-sg"
  vpc_id      = aws_default_vpc.default_vpc.id
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # from_port = 80
    # to_port   = 80
    # protocol  = "tcp"
    # Only allowing traffic in from the load balancer security group
    security_groups = [aws_security_group.load_balancer_security_group.id]
  }

  egress {
    from_port   = 0             # Allowing any incoming port
    to_port     = 0             # Allowing any outgoing port
    protocol    = "-1"          # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

#####################################################################
# network
#####################################################################
resource "aws_default_vpc" "default_vpc" {
}

resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "us-east-1a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "us-east-1b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "us-east-1c"
}

#####################################################################
# load balancer
#####################################################################
resource "aws_alb" "weather_alb" {
  name               = "weather-lb" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    aws_default_subnet.default_subnet_a.id,
    aws_default_subnet.default_subnet_b.id,
    aws_default_subnet.default_subnet_c.id
  ]

  security_groups = [aws_security_group.load_balancer_security_group.id]
}

resource "aws_security_group" "load_balancer_security_group" {
  description = "allow access to application load balancer"
  name        = "weather-lb-sg"
  vpc_id      = aws_default_vpc.default_vpc.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "weather_tg" {
  name        = "weather-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
  depends_on = [
    aws_alb.weather_alb
  ]

  health_check {
    matcher = "200,301,302"
    path    = "/"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_alb.weather_alb.arn # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.weather_tg.arn # Referencing our tagrte group
  }
}
