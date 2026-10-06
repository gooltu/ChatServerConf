resource "aws_security_group" "alb" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb-sg" }
}

resource "aws_security_group" "mongooseim" {
  name   = "mongooseim-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "ws-xmpp/BOSH from ALB"
    from_port       = 5280
    to_port         = 5280
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Erlang distribution (epmd + the dynamic distribution port range) between
  # MongooseIM nodes themselves — required for Mnesia clustering (plan §5).
  # `self = true` scopes this to traffic between members of this same SG,
  # not the wider VPC.
  ingress {
    description = "epmd (cluster discovery)"
    from_port   = 4369
    to_port     = 4369
    protocol    = "tcp"
    self        = true
  }
  ingress {
    description = "Erlang distribution port range (cluster traffic)"
    from_port   = 9100
    to_port     = 9200
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mongooseim-sg" }
}

resource "aws_security_group" "nodeapp" {
  name   = "nodeapp-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "REST API from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description     = "MongooseIM auth.http callback to /mongooseim/*"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.mongooseim.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "nodeapp-sg" }
}

resource "aws_security_group" "rds" {
  name   = "rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "MySQL from MongooseIM"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.mongooseim.id]
  }
  ingress {
    description     = "MySQL from Node app"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.nodeapp.id]
  }

  tags = { Name = "rds-sg" }
}
