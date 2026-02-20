# AWS Deployment Guide — Stockpile Weight Estimator

## Architecture

```
User → ALB (port 80/443) → EC2 instance (port 8501) → Docker container (Streamlit app)
```

Single EC2 instance running Docker. No database, no external services.

---

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Instance type | t3.large (2 vCPU, 8GB RAM) | c5.xlarge (4 vCPU, 8GB RAM) |
| Storage | 50 GB gp3 | 100 GB gp3 |
| OS | Ubuntu 22.04 AMI | Ubuntu 22.04 AMI |
| Ports | 8501 (or 80/443 via ALB) | 80/443 via ALB |

COLMAP reconstruction is CPU-intensive. 4 vCPUs recommended for acceptable processing times.

---

## Step 1: Launch EC2 Instance

1. Go to **EC2 → Launch Instance**
2. Select **Ubuntu Server 22.04 LTS** AMI
3. Instance type: **c5.xlarge** (or t3.large for budget)
4. Storage: **100 GB gp3**
5. Security group inbound rules:
   - SSH (22) from your IP
   - Custom TCP (8501) from anywhere (or restrict to ALB)
   - HTTP (80) / HTTPS (443) if using ALB
6. Launch with your SSH key pair

---

## Step 2: Install Docker on EC2

SSH into the instance:

```bash
ssh -i your-key.pem ubuntu@<EC2_PUBLIC_IP>
```

Install Docker:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo usermod -aG docker ubuntu
newgrp docker
```

---

## Step 3: Deploy the App

Clone or copy the project to the server:

```bash
# Option A: Git clone (if repo is set up)
git clone <YOUR_REPO_URL> ~/stockpile
cd ~/stockpile

# Option B: SCP from local machine
# (run this from your local machine)
# scp -i your-key.pem -r /Users/mrmacbook/projects/stock_pile ubuntu@<EC2_PUBLIC_IP>:~/stockpile
```

Build and start:

```bash
cd ~/stockpile
docker compose up -d --build
```

This takes 5-10 minutes on first build (installs COLMAP, Python deps).

Verify it's running:

```bash
docker compose ps
curl http://localhost:8501/_stcore/health
```

The app is now accessible at `http://<EC2_PUBLIC_IP>:8501`

---

## Step 4: (Optional) Set Up ALB + HTTPS

For production with a domain name and HTTPS:

1. **Request an ACM certificate** for your domain
2. **Create a Target Group**: protocol HTTP, port 8501, health check path `/_stcore/health`
3. **Register** the EC2 instance in the target group
4. **Create an ALB**: listener on 443 (HTTPS) forwarding to the target group
5. **DNS**: Point your domain to the ALB

---

## Management

```bash
# View logs
docker compose logs -f

# Restart
docker compose restart

# Update (after code changes)
cd ~/stockpile
git pull
docker compose up -d --build

# Stop
docker compose down
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Out of memory during COLMAP | Use a larger instance (c5.2xlarge) or reduce COLMAP quality to "low" |
| Upload fails | Max upload size is 500MB. For larger videos, increase `maxUploadSize` in docker-compose.yml |
| Slow processing | COLMAP is CPU-bound. Use c5/c6i instances (compute-optimized). Processing takes 5-30 min per video |
| Container won't start | Check logs: `docker compose logs` |
| Port 8501 not accessible | Check EC2 security group allows inbound TCP 8501 |
