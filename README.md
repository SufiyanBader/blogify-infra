# Blogify — Infra (deployment repo)

Infrastructure-as-code and blue-green deployment automation for the [`blogify-platform`](../blogify-platform) microservices app.

## What's here

```
terraform/    EC2 instance, security group, elastic IP
ansible/      Server bootstrap: Docker, Nginx, data layer, initial deploy
nginx/        Gateway config template (per-service blue/green routing)
scripts/      deploy-service.sh (single service) + deploy-all.sh (orchestrator)
monitoring/   Prometheus config
.github/      CI that listens for dispatches from blogify-platform
```

## How blue-green works here

Each of the 5 services gets **two ports** (blue + green) and **its own Nginx upstream**:

| Service | Blue port | Green port |
|---|---|---|
| auth | 4101 | 4102 |
| posts | 4201 | 4202 |
| comments | 4301 | 4302 |
| media | 4401 | 4402 |
| notification-worker | 4501 | 4502 |

The gateway includes `<service>-active.conf`, a one-line file that's just a symlink-like copy of either `<service>-blue.conf` or `<service>-green.conf`. Deploying a service:

1. Pulls the new image into the **idle** slot
2. Starts it, polls `/health` up to 10 times (50s)
3. If healthy: copies the new slot's upstream config over `-active.conf`, runs `nginx -s reload` (zero dropped connections — Nginx finishes in-flight requests on the old upstream while routing new ones to the new upstream)
4. Re-verifies through the gateway itself
5. Waits 20s, then stops the old container
6. If any health check fails at any point: old slot stays live, new container is torn down, script exits non-zero

Services deploy **independently** — you can roll out a new `posts` image without touching `auth`, `comments`, etc.

## One-time setup

### 1. Provision the server

```bash
cd terraform
terraform init
terraform apply
terraform output server_ip   # note this IP
```

### 2. Configure it

```bash
cd ../ansible
# Edit inventory.ini -> replace YOUR_SERVER_IP
export DOCKERHUB_NAMESPACE=sufiyanbader
export JWT_SECRET=$(openssl rand -hex 32)
ansible-playbook -i inventory.ini playbook.yml
```

This installs Docker + Nginx, starts Postgres/Redis/RabbitMQ/MinIO, sets up blue-green configs for all 5 services, and does the **first deploy** (everything starts on the blue slot).

### 3. Set up monitoring (optional, do this on the server)

```bash
scp -r docker-compose.monitoring.yml monitoring ubuntu@<SERVER_IP>:/opt/blogify/
ssh ubuntu@<SERVER_IP>
cd /opt/blogify && docker compose -f docker-compose.monitoring.yml up -d
```

Grafana: `http://<SERVER_IP>:3100` (admin/admin123) — import dashboard 1860 (Node Exporter) and 14282 (Docker containers).

### 4. Configure GitHub secrets

In **this repo** (`blogify-infra`) → Settings → Secrets and variables → Actions:

| Secret | Value |
|---|---|
| `EC2_HOST` | Server public IP |
| `EC2_SSH_KEY` | Private key contents (matches the key used in Terraform) |
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `JWT_SECRET` | Same secret used in the Ansible run |

In the **`blogify-platform`** repo, also set:

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` | Docker Hub creds |
| `INFRA_REPO_PAT` | A GitHub PAT (repo scope) that can dispatch events to this repo |
| `INFRA_REPO_OWNER` | Your GitHub username |

## How a deploy happens end-to-end

1. You push code to `blogify-platform` (e.g. edit `services/posts/index.js`)
2. Its CI detects only `posts` changed, builds + pushes `sufiyanbader/blogify-posts:<sha>` to Docker Hub
3. It fires a `repository_dispatch` event of type `deploy-services` to this repo, with payload `{ services: ["posts"], image_tag: "<sha>" }`
4. This repo's workflow wakes up, SSHes into the EC2 server, and runs `deploy-all.sh sufiyanbader <sha> posts`
5. `deploy-all.sh` calls `deploy-service.sh posts ...` — blue-green swap happens for just that one service
6. Gateway health is verified, summary posted to the GitHub Actions run

## Manual deploy (without CI)

```bash
ssh ubuntu@<SERVER_IP>
sudo JWT_SECRET=<secret> /opt/blogify/deploy-all.sh sufiyanbader latest posts,comments
```

## Manual rollback

```bash
ssh ubuntu@<SERVER_IP>
# Example: revert posts service back to blue
sudo cp /etc/nginx/conf.d/posts-blue.conf /etc/nginx/conf.d/posts-active.conf
sudo nginx -s reload
```

## Useful checks on the server

```bash
docker ps                                  # see which slots are running
curl http://localhost/api/posts/health     # check current active posts version
curl http://localhost/nginx-health         # gateway liveness
docker logs blogify-posts-blue --tail 50   # service logs
```
