# 🔵🟢 Blue/Green Deployment Orchestrator

**A Bash-based deployment pipeline that releases new versions of an app without downtime, checks that they are healthy, and rolls back automatically if something goes wrong.**

![Bash](https://img.shields.io/badge/Bash-Scripting-4EAA25?logo=gnubash&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)
![Nginx](https://img.shields.io/badge/Nginx-Reverse%20Proxy-009639?logo=nginx&logoColor=white)
![FastAPI](https://img.shields.io/badge/FastAPI-Python%203.11-009688?logo=fastapi&logoColor=white)
![AWS](https://img.shields.io/badge/AWS-EC2-FF9900?logo=amazonaws&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/CI%2FCD-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)

---

## 📖 About

In a normal deployment, the old version is stopped and the new one is started, so users may see errors in between. **Blue/Green deployment** avoids this by keeping two copies ("slots") of the app. One slot (say, blue) serves live traffic while the new version is deployed to the other (green). Traffic is switched only after the new version passes health checks.

I built this project from scratch using Bash, Docker Compose, and Nginx to understand how release pipelines work behind the scenes, instead of using a managed deployment service.

---

## ✨ Features

- **Two app slots** (blue on port `8081`, green on port `8082`) run behind one Nginx proxy
- **Pre-cutover health check:** the new version must return `HTTP 200` on `/health` before it gets any traffic
- **Smooth traffic switch** using `nginx reload`, which lets in-flight requests finish
- **Post-cutover monitoring:** sends test requests after the switch and reverts if it sees `5xx` errors
- **Automatic cleanup:** the old container is stopped after a successful release to save memory and CPU
- **Chaos testing mode:** a `FAIL_HEALTH=true` flag makes the app deliberately fail, so rollback can be tested
- **Local-only app ports:** containers are bound to `127.0.0.1`, so only Nginx (port 80) is public
- **Push-to-deploy:** GitHub Actions deploys to EC2 whenever code is pushed to `main`

---

## 🏗️ Architecture

```text
                 [ User Traffic / CI Runner ]
                              │
                              ▼  (Port 80)
                   ┌─────────────────────┐
                   │    Nginx Proxy      │
                   │ (active_upstream)   │
                   └──────────┬──────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼ (127.0.0.1:8081)                      ▼ (127.0.0.1:8082)
 ┌──────────────────┐                    ┌──────────────────┐
 │    Slot Blue     │                    │    Slot Green    │
 │  (FastAPI app)   │                    │  (FastAPI app)   │
 └──────────────────┘                    └──────────────────┘
```

### How a deployment works

1. **Detect the live slot:** `deploy.sh` reads `/etc/nginx/conf.d/active_upstream.conf` to see whether blue or green is serving traffic.
2. **Deploy to the idle slot:** The new version is built and started in the other slot using Docker Compose.
3. **Health check before the switch:** The script checks the new container's `/health` endpoint up to 10 times. If it never returns `HTTP 200`, the deployment is aborted, the new container is removed, and Nginx is not touched, so users are unaffected.
4. **Switch traffic:** `active_upstream.conf` is updated to point to the new slot and Nginx is reloaded.
5. **Monitor and roll back:** The script sends 5 test requests through Nginx. If any returns a `5xx` error, traffic is switched back to the previous slot and the faulty container is removed.
6. **Clean up:** If everything passes, the old slot's container is stopped and removed.

---

## 🛠️ Tech Stack

| Area | Tools |
|---|---|
| App | Python 3.11, FastAPI, Uvicorn |
| Containers | Docker, Docker Compose |
| Reverse proxy | Nginx (systemd service on EC2, container locally) |
| Orchestration | Bash (`set -euo pipefail`) |
| Cloud | AWS EC2 (Amazon Linux 2023) |
| CI/CD | GitHub Actions, SSH, rsync |

---

## 📁 Repository Structure

```text
blue-green-deploy/
├── .github/
│   └── workflows/
│       └── deploy.yml           # GitHub Actions workflow (push + manual chaos trigger)
├── app/
│   ├── Dockerfile               # Python 3.11-slim image
│   ├── main.py                  # FastAPI app with /health and FAIL_HEALTH flag
│   └── requirements.txt         # FastAPI and Uvicorn
├── nginx/
│   ├── active_upstream.conf     # Points to the live slot
│   └── nginx.conf               # Local reverse proxy config
├── deploy.sh                    # Main script: deploy, health check, switch, rollback
├── docker-compose.yml           # Blue and green services (bound to 127.0.0.1)
└── setup-server.sh              # Sets up an Amazon Linux 2023 server
```

---

## 🚀 Getting Started

### Option 1: Run locally

**Prerequisites:** Docker, Docker Compose, and Bash (macOS/Linux terminal, or Git Bash/WSL on Windows)

**1. Start Nginx and the base stack**

```bash
docker compose up -d
```

**2. Make the script executable**

```bash
chmod +x deploy.sh
```

**3. Run a healthy deployment**

```bash
./deploy.sh v1.0.0 healthy
```

**4. Check the live endpoint**

```bash
curl -s http://localhost/
# {"status":"healthy","version":"v1.0.0","slot":"green","message":"Hello from the GREEN deployment slot!"}
```

**5. Try the rollback with a broken release**

```bash
./deploy.sh v2.0.0-broken broken
```

The new version's health check fails with `HTTP 500`, so the deployment is aborted, the broken container is removed, and live traffic keeps going to the working slot.

---

### Option 2: Deploy to AWS EC2

**1. Launch an EC2 instance**
- AMI: **Amazon Linux 2023**
- Security group inbound rules: allow **SSH (22)** and **HTTP (80)**. Do **not** open ports `8081` or `8082`.

**2. Copy the project and run setup**

```bash
scp -i your-key.pem -r ./blue-green-deploy ec2-user@<EC2_PUBLIC_IP>:~/blue-green-deploy
ssh -i your-key.pem ec2-user@<EC2_PUBLIC_IP>

cd ~/blue-green-deploy
chmod +x setup-server.sh deploy.sh
./setup-server.sh
```

**3. Log out and back in** (so Docker group permissions apply), then deploy

```bash
exit
ssh -i your-key.pem ec2-user@<EC2_PUBLIC_IP>
cd ~/blue-green-deploy
./deploy.sh v1.0.0 healthy
```

---

### Option 3: Set up CI/CD with GitHub Actions

**1.** Go to your repo's **Settings → Secrets and variables → Actions** and add these secrets:

| Secret | Value |
|---|---|
| `EC2_HOST` | Public IPv4 address of your EC2 instance |
| `EC2_SSH_KEY` | Full contents of your `.pem` private key |

**2.** Trigger a deployment:
- **Automatic:** push a commit to `main`
- **Manual / chaos test:** go to **Actions → Deploy to EC2 (Blue/Green) → Run workflow** and enter `broken` in the `chaos_mode` input to see the pipeline handle a failed release

---

## 🧠 What I Learned

- How Blue/Green deployment works and why it reduces risk
- How Nginx reloads work without dropping active connections
- Writing a safe Bash script with `set -euo pipefail` and clear exit paths
- Using health checks to decide whether a release should go live
- Why binding services to `127.0.0.1` keeps containers off the public internet
- Setting up GitHub Actions to deploy over SSH with `rsync`
- Testing failure scenarios on purpose (chaos testing) instead of only testing success

---

## ⚠️ Limitations

- Runs on a single EC2 instance, so it is not highly available
- Database changes and migrations are not handled
- The post-switch check only sends 5 test requests, which is a basic safety check and not full monitoring
- Rollback is triggered by `5xx` responses only

---

## 🔭 Future Improvements

- [ ] Add HTTPS with Let's Encrypt
- [ ] Push images to a registry (Docker Hub or ECR) instead of building on the server
- [ ] Send Slack or email notifications on deploy and rollback
- [ ] Add a canary step that sends a small share of traffic first
- [ ] Provision the EC2 instance and security group with Terraform
- [ ] Add automated tests to the CI pipeline before deploying

---

## 👤 Author

**Preet Yadav**

[LinkedIn](https://linkedin.com/in/preetyadav319) · [GitHub](https://github.com/preetyadav270904-ctrl)

---

⭐ If you found this useful, feel free to star the repo!
