provider "aws" {
    region = "eu-central-1"
}

// -----------------------------------------------------------------------------
// NETWORK
//
// Defines a VPC with a single publicly visible subnet
// see: https://ops.tips/blog/a-pratical-look-at-basic-aws-networking/
// -----------------------------------------------------------------------------

resource "aws_vpc" "circles" {
    cidr_block       = "10.0.0.0/16"
    enable_dns_support = true
    enable_dns_hostnames = true

    tags {
        Name = "circles-vpc"
    }
}

resource "aws_subnet" "circles" {
    vpc_id                  = "${aws_vpc.circles.id}"
    cidr_block              = "10.0.0.0/24"
    map_public_ip_on_launch = true
    availability_zone = "eu-central-1b"

    tags {
        Name = "circles-subnet"
    }
}

resource "aws_internet_gateway" "circles" {
    vpc_id = "${aws_vpc.circles.id}"

    tags {
        Name = "circles-internet-gateway"
    }
}

resource "aws_route" "internet_access" {
    route_table_id         = "${aws_vpc.circles.main_route_table_id}"
    destination_cidr_block = "0.0.0.0/0"
    gateway_id             = "${aws_internet_gateway.circles.id}"
}

// -----------------------------------------------------------------------------
// LOAD BALANCER & SCALING GROUP
//
// Runs health checks and ensures that at least one node is always up and healthy
// -----------------------------------------------------------------------------

variable "ethstats_port" {
    default = 3000
}

variable "ethstats_protocol" {
    default = "http"
}

variable "node_count" {
    default = 2
}

// -----------------------------------------------------------------------------

resource "aws_elb" "circles" {
    name = "circles"

    // ethstats

    listener {
        instance_port = "${var.ethstats_port}"
        instance_protocol = "${var.ethstats_protocol}"
        lb_port = "${var.ethstats_port}"
        lb_protocol = "${var.ethstats_protocol}"
    }

    health_check {
        healthy_threshold = 3
        unhealthy_threshold = 2
        timeout = 10
        target = "HTTP:${var.ethstats_port}/"
        interval = 30
    }

    idle_timeout = 60
    subnets         = ["${aws_subnet.circles.id}"]
    security_groups = ["${aws_security_group.circles.id}"]

    lifecycle {
        create_before_destroy = true
    }

    tags {
        Name = "circles-elastic-load-balancer"
    }
}

// Rolling deployments are only available as a cloudformation primitive
// see: https://github.com/hashicorp/terraform/issues/1552#issuecomment-190864512
resource "aws_cloudformation_stack" "circles_autoscaling_group" {
  name = "circles-autoscaling-group-stack"
  template_body = <<EOF
{
    "Resources": {
        "circles": {
            "Type": "AWS::AutoScaling::AutoScalingGroup",
            "Properties": {
                "LaunchConfigurationName": "${aws_launch_configuration.circles.name}",

                "MaxSize": "${var.node_count + 1}",
                "MinSize": "${var.node_count - 1}",
                "DesiredCapacity": "${var.node_count}",

                "HealthCheckGracePeriod" : 300,
                "HealthCheckType": "ELB",

                "LoadBalancerNames": ["${aws_elb.circles.id}"],
                "VPCZoneIdentifier": ["${aws_subnet.circles.id}"],

                "TerminationPolicies": ["OldestLaunchConfiguration", "OldestInstance"],
                "Tags": [{
                    "Key" : "Name",
                    "Value" : "circles-autoscaling-group",
                    "PropagateAtLaunch" : "true"
                }]
            },
            "UpdatePolicy": {
                "AutoScalingRollingUpdate": {
                    "MinInstancesInService": "${var.node_count - 1}",
                    "MaxBatchSize": "1",
                    "PauseTime": "PT0S"
                }
            }
        }
    }
}
EOF
}

// -----------------------------------------------------------------------------
// NODE
//
// Defines a single node running all services:
//
// 1. node is booted
// 2. cloud-init is run & bootstraps to docker-compose
// 3. docker-compose brings everything else up
// -----------------------------------------------------------------------------

variable "ubuntu_version" {
    default = "16.04"
}

variable "ubuntu_release_name" {
    default = "xenial"
}

variable "docker_compose_version" {
    default = "1.20.1"
}

// -----------------------------------------------------------------------------

data "aws_ami" "ec2-linux" {
    most_recent = true

    filter {
        name = "name"
        values = ["amzn-ami-*-x86_64-gp2"]
    }

    filter {
        name = "virtualization-type"
        values = ["hvm"]
    }

    filter {
        name = "owner-alias"
        values = ["amazon"]
    }
}

data "template_file" "cloud_init" {
    template = "${file("${path.module}/cloud-init.yaml")}"

    vars {
        docker_compose_file = "${file("${path.module}/docker-compose.yaml")}"
        docker_compose_version = "${var.docker_compose_version}"
    }
}

resource "aws_launch_configuration" "circles" {
    lifecycle { create_before_destroy = true }

    instance_type = "t2.micro"
    image_id = "${data.aws_ami.ec2-linux.id}"

    security_groups = ["${aws_security_group.circles.id}"]
    user_data       = "${data.template_file.cloud_init.rendered}"
}

// -----------------------------------------------------------------------------
// FIREWALL
// -----------------------------------------------------------------------------

resource "aws_security_group" "circles" {
    name = "circles"
    vpc_id = "${aws_vpc.circles.id}"

    ingress {
        from_port   = "${var.ethstats_port}"
        to_port     = "${var.ethstats_port}"
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

// -----------------------------------------------------------------------------
// OUTPUTS
// -----------------------------------------------------------------------------

output "ethstats" {
  value = "${aws_elb.circles.dns_name}:3000"
}
