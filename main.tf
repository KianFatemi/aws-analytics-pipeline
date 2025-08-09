provider "aws" {
  region = "us-east-1"
}

resource "aws_iam_role" "lambda_exec_role" {
  name = "analytics-pipeline-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "analytics_ingestor" {
  function_name    = "analytics-ingestor"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 120

    vpc_config {
    subnet_ids         = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

   environment {
    variables = {
      S3_BUCKET_NAME = aws_s3_bucket.raw_events_bucket.bucket
      DDB_TABLE_NAME = aws_dynamodb_table.events_table.name
      RDS_SECRET_ARN    = aws_secretsmanager_secret.rds_password.arn
      RDS_DB_HOSTNAME   = aws_db_instance.analytics_db.address
      RDS_DB_NAME       = aws_db_instance.analytics_db.db_name
    }
  }
}

resource "aws_api_gateway_rest_api" "rest_api" {
  name = "AnalyticsAPI-REST"
}

resource "aws_api_gateway_resource" "event_resource" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "event"
}

resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.event_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.event_resource.id
  http_method = aws_api_gateway_method.post_method.http_method
  
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.analytics_ingestor.invoke_arn
}

resource "aws_lambda_permission" "api_gw_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analytics_ingestor.function_name
  principal     = "apigateway.amazonaws.com"
  
  source_arn = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*/${aws_api_gateway_method.post_method.http_method}${aws_api_gateway_resource.event_resource.path}"
}

resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.event_resource.id,
      aws_api_gateway_method.post_method.id,
      aws_api_gateway_integration.lambda_integration.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "test"
}

output "api_endpoint_url" {
  value = "${aws_api_gateway_stage.api_stage.invoke_url}/${aws_api_gateway_resource.event_resource.path_part}"
}

resource "aws_s3_bucket" "raw_events_bucket" {
  bucket = "analytics-raw-events-bucket-${random_id.id.hex}" # Unique bucket name
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_dynamodb_table" "events_table" {
  name           = "processed-events"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "eventId"

  attribute {
    name = "eventId"
    type = "S" # S means String
  }
}

resource "aws_iam_role_policy" "lambda_data_permissions" {
  name = "lambda-data-access-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action   = "s3:PutObject",
        Effect   = "Allow",
        Resource = "${aws_s3_bucket.raw_events_bucket.arn}/*"
      },
      {
        Action   = "dynamodb:PutItem",
        Effect   = "Allow",
        Resource = aws_dynamodb_table.events_table.arn
      },
      {
        Action   = "secretsmanager:GetSecretValue",
        Effect   = "Allow",
        Resource = aws_secretsmanager_secret.rds_password.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_ssm_access" {
  role       = aws_iam_role.monitoring_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_security_group_rule" "monitoring_egress_to_endpoints" {
  type                     = "egress"
  from_port                = 443 
  to_port                  = 443 
  protocol                 = "tcp"
  security_group_id        = aws_security_group.monitoring_sg.id
  source_security_group_id = aws_security_group.vpc_endpoint_sg.id
}

resource "aws_security_group_rule" "endpoints_ingress_from_monitoring" {
  type                     = "ingress"
  from_port                = 443 # HTTPS
  to_port                  = 443 # HTTPS
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint_sg.id
  source_security_group_id = aws_security_group.monitoring_sg.id
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "main-vpc"
  }
}

resource "aws_subnet" "subnet_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true #
  tags = {
    Name = "rds-subnet-a"
  }
}

resource "aws_subnet" "subnet_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "rds-subnet-b"
  }
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "main-rds-subnet-group"
  subnet_ids = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  tags = {
    Name = "Main RDS subnet group"
  }
}

resource "aws_security_group" "lambda_sg" {
  name        = "lambda-sg"
  description = "Security group for the Lambda function"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "vpc_endpoint_sg" {
  name   = "vpc-endpoint-sg"
  vpc_id = aws_vpc.main.id
}

resource "aws_vpc_endpoint" "ssm_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
}

resource "aws_vpc_endpoint" "ssmmessages_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
}

resource "aws_vpc_endpoint" "ec2messages_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-sg"
  description = "Security group for the RDS instance"
  vpc_id      = aws_vpc.main.id


  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda_sg.id]
  }
}

resource "aws_secretsmanager_secret" "rds_password" {
  name = "analytics-rds-password"
}

resource "aws_secretsmanager_secret_version" "rds_password_version" {
  secret_id = aws_secretsmanager_secret.rds_password.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.password.result
  })
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_instance" "analytics_db" {
  allocated_storage    = 10
  engine               = "postgres"
  engine_version       = "15.7"
  instance_class       = "db.t3.micro" 
  db_name              = "analytics"
  username             = "postgres"
  password             = random_password.password.result
  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot  = true
  publicly_accessible  = true
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.us-east-1.s3"
  route_table_ids = [aws_vpc.main.main_route_table_id]
}

resource "aws_vpc_endpoint" "dynamodb_gateway" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.us-east-1.dynamodb"
  route_table_ids = [aws_vpc.main.main_route_table_id]
}

resource "aws_vpc_endpoint" "secretsmanager_interface" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.us-east-1.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
}


resource "aws_security_group_rule" "lambda_egress_to_endpoints" {
  type                     = "egress" 
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.lambda_sg.id 
  source_security_group_id = aws_security_group.vpc_endpoint_sg.id 
}


resource "aws_security_group_rule" "endpoints_ingress_from_lambda" {
  type                     = "ingress" 
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.vpc_endpoint_sg.id 
  source_security_group_id = aws_security_group.lambda_sg.id 
}
resource "aws_route_table_association" "subnet_b_public" {
  subnet_id      = aws_subnet.subnet_b.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

# Monitoring Stack on EC2

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_iam_role" "monitoring_instance_role" {
  name = "monitoring-instance-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_cw_access" {
  role       = aws_iam_role.monitoring_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_instance_profile" "monitoring_instance_profile" {
  name = "monitoring-instance-profile"
  role = aws_iam_role.monitoring_instance_role.name
}

resource "aws_security_group" "monitoring_sg" {
  name   = "monitoring-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

    
  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "monitoring_server" {
  ami           = data.aws_ami.amazon_linux_2.id 
  instance_type = "t3.micro"             
  subnet_id     = aws_subnet.subnet_a.id 
  iam_instance_profile = aws_iam_instance_profile.monitoring_instance_profile.name
  vpc_security_group_ids = [aws_security_group.monitoring_sg.id]


user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install docker -y
              service docker start
              usermod -a -G docker ec2-user
              curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
              chmod +x /usr/local/bin/docker-compose
              
              # Create a directory for our monitoring stack
              mkdir /home/ec2-user/monitoring
              cd /home/ec2-user/monitoring
              
              # Create docker-compose.yml
              cat <<EOT > docker-compose.yml
              ${file("${path.module}/docker-compose.yml")}
              EOT
              
              # Create prometheus.yml
              cat <<EOT > prometheus.yml
              ${file("${path.module}/prometheus.yml")}
              EOT
              
              # Create loki-config.yml
              cat <<EOT > loki-config.yml
              ${file("${path.module}/loki-config.yml")}
              EOT
              
              # Start the services
              docker-compose up -d
              EOF

  tags = {
    Name = "Monitoring-Server"
  }
}

resource "aws_route_table_association" "subnet_a_public" {
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

output "monitoring_server_public_ip" {
  value = aws_instance.monitoring_server.public_ip
}