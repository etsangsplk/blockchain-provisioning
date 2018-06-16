[
  {
    "name": "nginx",
    "image": "nginx:latest",
    "memory": 256,
    "cpu": 256,
    "essential": true,
    "portMappings": [
      {
        "containerPort": ${port},
        "hostPort": ${port},
        "protocol": "tcp"
      }
    ],
    "mountPoints": [
      {
        "sourceVolume": "data",
        "containerPath": "/data"
      }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${log_group}",
        "awslogs-region": "eu-central-1",
        "awslogs-stream-prefix": "${service_name}"
      }
    }
  }
]
