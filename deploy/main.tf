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
  family                   = "weather-task" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "weather_app",
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
  requires_compatibilities = ["FARGATE"]                          # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"                             # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512                                  # Specifying the memory our container requires
  cpu                      = 256                                  # Specifying the CPU our container requires
  execution_role_arn       = aws_iam_role.task_execution_role.arn # starting
  task_role_arn            = aws_iam_role.app_iam_role.arn        # runtime
}

resource "aws_iam_role" "task_execution_role" {
  name               = "weather-task-exec-role"
  assume_role_policy = file("./templates/ecs/assume-role-policy.json")
}

resource "aws_iam_role" "app_iam_role" {
  # role necessary for runtime
  name               = "weather-app-iam-roll-task"
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

# resource "aws_iam_role_policy_attachment" "task_execution_role_policy" {
#   role       = aws_iam_role.task_execution_role.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
# }

#####################################################################
# service
#####################################################################
resource "aws_ecs_service" "weather_service" {
  name            = "weather-service"
  cluster         = aws_ecs_cluster.weather_cluster.id
  task_definition = aws_ecs_task_definition.weather_task.arn
  launch_type     = "FARGATE"
  desired_count   = 3 # Setting the number of containers we want deployed to 3

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn # Referencing our target group
    # container_name   = aws_ecs_task_definition.weather_task.family
    # try again
    container_name = "weather_app"
    container_port = 3000 # Specifying the container port
  }

  network_configuration {
    security_groups = [aws_security_group.service_security_group.id]
    subnets = [
      aws_default_subnet.default_subnet_a.id,
      aws_default_subnet.default_subnet_b.id,
      aws_default_subnet.default_subnet_c.id,
    ]
    assign_public_ip = true # Providing our containers with public IPs
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
resource "aws_alb" "application_load_balancer" {
  name               = "weather-lb" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    aws_default_subnet.default_subnet_a.id,
    aws_default_subnet.default_subnet_b.id,
    aws_default_subnet.default_subnet_c.id
  ]
  # Referencing the security group
  security_groups = [aws_security_group.load_balancer_security_group.id]
}

# Creating a security group for the load balancer:
resource "aws_security_group" "load_balancer_security_group" {
  ingress {
    # from_port   = 80 # Allowing traffic in from port 80
    # to_port     = 80
    # protocol    = "tcp"
    # cidr_blocks = ["0.0.0.0/0"] # Allowing traffic in from all sources
    from_port   = 0             # Allowing any incoming port
    to_port     = 0             # Allowing any outgoing port
    protocol    = "-1"          # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }

  egress {
    from_port   = 0             # Allowing any incoming port
    to_port     = 0             # Allowing any outgoing port
    protocol    = "-1"          # Allowing any outgoing protocol 
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic out to all IP addresses
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
  depends_on = [
    aws_alb.application_load_balancer
  ]

  health_check {
    matcher = "200,301,302"
    path    = "/"
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_alb.application_load_balancer.arn # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn # Referencing our tagrte group
  }
}
