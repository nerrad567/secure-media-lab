# 🔒 secure-media-lab – Secure Home Lab & Remote Stack

[![Platform](https://img.shields.io/badge/Platform-WSL2%20%7C%20Ubuntu%2024.04-blue?style=for-the-badge&logo=linux)](https://ubuntu.com)
![VPN](https://img.shields.io/badge/VPN-WireGuard-88171A?style=for-the-badge&logo=wireguard&logoColor=white)
![Dockerized](https://img.shields.io/badge/Stack-Docker%20Containers-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Firewall](https://img.shields.io/badge/Firewall-iptables-informational?style=for-the-badge&logo=gnuprivacyguard)
![Sync & Automation](https://img.shields.io/badge/Automation-Bash%20%7C%20PowerShell-4B275F?style=for-the-badge&logo=gnubash&logoColor=white)
![Backups](https://img.shields.io/badge/Backups-Encrypted%20via%20rclone%20%2B%20B2-critical?style=for-the-badge&logo=veritas)
![Status](https://img.shields.io/badge/Status-Live%20Lab-green?style=for-the-badge&logo=server)
![Privacy](https://img.shields.io/badge/Access-Controlled%20%26%20Private-black?style=for-the-badge&logo=protonvpn)


## Secure Home Lab + Remote Stack with WSL2, Docker, WireGuard, and Automation Scripts

This project documents my personal lab setup combining a containerized service stack, remote VPS tunneling, and automated syncing logic using Bash, PowerShell, and Linux networking tools. It allows for convenient centralized access and backup of my home media collection. Built as a learning environment, this stack helps explore system automation, secure data handling, and private infrastructure design.

**🛠️ Project Timeline:** Completed initial build in one weekend + several workday evenings.

---

### 🔐 Key Features

- **Remote VPS (Ubuntu 24.04):** Hosts private services and a WireGuard server. Access is limited to a chrooted `syncuser` (access via ssh key) user with readonly bind mounts and a restricted shell with access only to rsync for file retrieval and synchronization tasks, as well as a separate sudo-enabled user authenticated via password-protected SSH keys.
- **WireGuard VPN:** Secure peer-to-peer tunnel between VPS and multiple WireGuard clients using the 10.0.0.0/24 subnet.
- **Docker Stack (WSL2 Ubuntu):** Self-hosted services running in isolated containers on a Windows host via WSL2.
- **iptables Firewall Rules:** Rate-limiting to mitigate SSH hammering, reduce brute-force noise, and control exposure. Also used for network segmentation and service-specific access control.
- **Reverse Proxy (nginx):** Provides secure access to services using consistent, browser-friendly URLs; prevents security warnings via clean local proxy routing.
- **Rsync Automation Script:** Syncs files from the remote server to local storage, with persistent task-aware tracking.
- **Download Monitoring:** Web API integration for job tracking and state inspection.
- **PowerShell Orchestration:** Handles WSL2 startup, disk mount management, and port proxy setup.
- **Systemd Services:** Includes custom service units (e.g., for mounting encrypted remote storage via rclone) to automate key startup tasks and ensure persistent, resilient operation.
- **Encrypted Backup:** Remote offsite storage handled by rclone, rcrypt + Backblaze B2 bucket.

---

### ⚙️ Tech Stack

- **Platforms:** Ubuntu 24.04, Windows 11
- **Containerization:** Docker (via WSL2)
- **Networking:** WireGuard, iptables, rsync
- **Languages/Scripting:** Bash, PowerShell
- **Automation & File Sync:** rsync, rclone, curl, jq
- **Storage/Backup:** rclone + Backblaze B2 (encrypted)
- **File Transfer:** qBittorrent Web API, SSH
- **Reverse Proxy:** nginx

---

### 🗂️ Project Structure

```
├── dockerCompose/        # Docker Compose YAML and related configs
├── iptables/             # Custom iptables firewall rule sets
├── vpsSync/              # Bash script: remote-to-local rsync with task state tracking
├── wslUpdate/            # PowerShell script for WSL2 automation and monitoring
├── powershell/           # Additional PowerShell scripts for system control
├── nginx/                # nginx reverse proxy config and landing page
├── systemd/              # service files for mounting encrypted remote storage via rclone
└── README.md             # This file
```

---

### 📸 Network Flow Diagram

```text
    ┌──────────────────────────────┐
    │   Other WireGuard Clients    │
    │ (e.g., Mobile, Laptop Users) │
    └─────────────┬────────────────┘
                  │
  Secure Tunnel to VPS (WireGuard Server)
                  │
             10.0.0.x/24
                  │
┌──────┐   ┌──────▼─────┐             ┌─────────────────────┐            ┌─────────────────────┐
│      │   │ VPS Server │             │ Windows 11 Host     │            │ LAN Client Devices  │
│  B2  │   │ Ubuntu 24  │             │ (WireGuard Client)  │ ◀ ──────── │ - Media Clients     │
│  BKT │◀▶│ - WG Server│◀──────────▶│ - PowerShell Script │            │                     │
│      │   │ - Remote FS│             │ - Portproxy         │            │                     │
└──────┘   └────▲───────┘             └──────┬──────────────┘            └─────────────────────┘
                │                            │
                │         Internal VPN       ▼
                │      (10.0.0.0/24 subnet) ┌────────────────────┐
                └─────────────────────────▶│ WSL2 (Ubuntu)      │
                                            │ - Docker Stack     │
                                            │ - Media Mgmt Tools │
                                            │ - File Sync        │
                                            └────────────────────┘


Access Routes:
- 🔐 WG Clients connect through the **VPS WireGuard Server** for secure access to internal tools
- 🖥️ LAN Clients connect directly to local-only services (e.g. Jellyfin) via **NAT port forwarding**
- 🔁 Data sync via rsync from VPS to WSL node using SSH + API checks
- ☁️ Encrypted storage flows from remote stack to Backblaze B2 using rclone
```

---

📘 Status
This project is under continuous iteration. AI tools were used to accelerate scripting, troubleshoot configurations, and refine logic — while maintaining strong understanding of the core principles and system behavior. Built to explore DevOps, Linux networking, and OT/infrastructure crossover practices.

🔜 Next Objective:
Migrate the current stack from Windows 11 + WSL2 to a dedicated local Debian server to improve system stability, energy efficiency, and hardware utilization — moving toward a more production-aligned environment.


---

### 📄 License

MIT

---
