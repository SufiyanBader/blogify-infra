#!/bin/bash
if ! nc -zv 127.0.0.1 5672 2>/dev/null; then
  echo "RabbitMQ port 5672 not accessible, recreating..."
  docker stop blogify-rabbitmq 2>/dev/null || true
  docker rm blogify-rabbitmq 2>/dev/null || true
  docker run -d \
    --name blogify-rabbitmq \
    --restart unless-stopped \
    --network blogify \
    -p 0.0.0.0:5672:5672 \
    -p 0.0.0.0:15672:15672 \
    -e RABBITMQ_DEFAULT_USER=blogify \
    -e RABBITMQ_DEFAULT_PASS=blogify \
    -v /var/data/rabbitmq:/var/lib/rabbitmq \
    rabbitmq:3.13-management-alpine
  sleep 35
fi