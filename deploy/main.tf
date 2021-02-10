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

  network_configuration {
    subnets = [
      aws_default_subnet.default_subnet_a.id,
      aws_default_subnet.default_subnet_b.id,
      aws_default_subnet.default_subnet_c.id,
    ]
    assign_public_ip = true # Providing our containers with public IPs
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