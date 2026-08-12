# Debian Monitoring & Security Stack

Automated installation and configuration scripts for building **Debian 13 (Trixie)** monitoring, security, and network-analysis servers.

This project is designed around a staged deployment model for creating a consistent monitoring/security platform with:

* [Tailscale](https://tailscale.com/) networking and MagicDNS
* [Cockpit](https://cockpit-project.org/) server administration
* [MariaDB](https://mariadb.org/) database services
* [Zabbix](https://www.zabbix.com/) monitoring
* [Wazuh](https://wazuh.com/) security monitoring / SIEM
* Apache web services
* Automatic Debian security updates
* SMTP mail relay and system notifications
* AppArmor status/configuration
* [Zeek](https://zeek.org/) network security monitoring
* [RITA](https://github.com/activecm/rita) network beacon/C2 analysis
* Optional Wazuh agent forwarding from network sensors

The goal is to provide a repeatable way to turn a fresh Debian installation into a functional monitoring/security node without manually repeating the same configuration steps on every server.

---

## ⚠️ Project Status

This project is actively being developed and is intended primarily for **personal infrastructure, lab environments, homelabs, and controlled production deployments**.

The scripts make assumptions about the environment, networking, DNS, Tailscale configuration, and the services being deployed.

**Review each script before running it on a production system.**

In particular, the Wazuh all-in-one installer is explicitly intended for a **fresh system** and should not be blindly re-run after the initial installation.

---

# Architecture

The primary monitoring server is built in stages:

```text
                         ┌─────────────────────────┐
                         │       Tailscale         │
                         │     Private Network     │
                         └────────────┬────────────┘
                                      │
                                      │
                    ┌─────────────────▼─────────────────┐
                    │       Debian 13 Monitoring       │
                    │                                  │
                    │  ┌──────────────┐                │
                    │  │   Cockpit    │                │
                    │  │   :9090      │                │
                    │  └──────────────┘                │
                    │                                  │
                    │  ┌──────────────┐                │
                    │  │    Apache    │                │
                    │  │  Zabbix Web  │                │
                    │  └──────┬───────┘                │
                    │         │                        │
                    │  ┌──────▼───────┐                │
                    │  │    Zabbix    │                │
                    │  │    Server    │                │
                    │  │    :10051    │                │
                    │  └──────┬───────┘                │
                    │         │                        │
                    │  ┌──────▼───────┐                │
                    │  │    MariaDB   │                │
                    │  └──────────────┘                │
                    │                                  │
                    │  ┌────────────────────────────┐  │
                    │  │       Wazuh All-in-One      │  │
                    │  │                            │  │
                    │  │ Indexer                    │  │
                    │  │ Manager                    │  │
                    │  │ Filebeat                   │  │
                    │  │ Dashboard                  │  │
                    │  └────────────────────────────┘  │
                    └──────────────────────────────────┘
                                      │
                                      │ Wazuh Agents
                                      │ / Zabbix Agents
                                      ▼
                              ┌───────────────┐
                              │ Linux / Win   │
                              │ Endpoints     │
                              └───────────────┘


       Network Sensor
       ─────────────────────────────────────

       SPAN / TAP
           │
           ▼
    ┌───────────────┐
    │ Debian Sensor │
    │               │
    │ Docker Zeek   │
    │      │        │
    │      ▼        │
    │     RITA      │
    │               │
    │ Wazuh Agent   │
    └───────┬───────┘
            │
            └──────────────► Wazuh
```

---

# Repository Structure

```text
.
├── 01-base-cockpit-mariadb.sh
├── 02-zabbix-server.sh
├── 03-wazuh-allinone.sh
├── 04-autoupdate.sh
├── Zeek-rita.sh
└── README.md
```

---

# Installation Stages

## Stage 1 — Base System

### `01-base-cockpit-mariadb.sh`

Installs and configures the foundational services required by the monitoring stack.

This stage currently provides:

* Base Debian packages
* CA certificates
* OpenSSL
* `sudo`
* Cockpit
* Cockpit storage/network modules
* MariaDB
* Zabbix database
* Tailscale TLS certificates
* Cockpit TLS configuration
* MariaDB tuning
* Credential generation
* Tailscale-aware service configuration

The script expects **Debian 13 (Trixie)** and a working Tailscale installation with the `tailscale0` interface available.

It also generates credentials for MariaDB/Zabbix and stores them in a root-only credentials file.

### Before running

Edit the site-specific settings near the beginning of the script:

```bash
TS_HOSTNAME="monitor.example.ts.net"

INNODB_BUFFER_POOL="1G"
INNODB_LOG_FILE="256M"
INNODB_FLUSH_LOG="2"
```

For example:

```bash
TS_HOSTNAME="monitor.example.ts.net"
```

The Tailscale HTTPS certificate must be enabled in the Tailscale administration console.

### Run

```bash
chmod +x 01-base-cockpit-mariadb.sh
sudo ./01-base-cockpit-mariadb.sh
```

The script is designed to be idempotent and can generally be re-run safely.

---

# Stage 2 — Zabbix

## `02-zabbix-server.sh`

Installs and configures the Zabbix monitoring server and web interface.

This stage includes:

* Zabbix Server
* Zabbix Agent 2
* Apache
* Zabbix frontend
* Zabbix database integration
* HTTPS configuration
* Tailscale-aware Apache binding
* Zabbix service configuration
* Agent 2 configuration
* Service health checks

The script currently targets the **Zabbix 8.0 LTS track**.

### Configuration

Edit the site-specific values:

```bash
TS_HOSTNAME="monitor.example.ts.net"
ZABBIX_TIMEZONE="America/New_York"
ZABBIX_MAJOR="8.0"
APACHE_BIND="tailscale"
```

`APACHE_BIND` can be configured for environments where the Zabbix interface should be accessible only through Tailscale or from broader network interfaces.

### Run

Stage 2 requires Stage 1 to have completed successfully.

```bash
chmod +x 02-zabbix-server.sh
sudo ./02-zabbix-server.sh
```

The script enables and starts:

```text
zabbix-server
zabbix-agent2
apache2
```

It also checks that Zabbix Server successfully binds to TCP port `10051`.

---

# Stage 3 — Wazuh

## `03-wazuh-allinone.sh`

Installs the Wazuh all-in-one stack:

```text
Wazuh Indexer
      │
      ├── Wazuh Manager
      │
      ├── Filebeat
      │
      └── Wazuh Dashboard
```

The Wazuh host is configured to monitor itself and uses Wazuh capabilities such as:

* File Integrity Monitoring
* Security Configuration Assessment
* Rootcheck
* Vulnerability detection

### ⚠️ Important

This script is intended for a **fresh installation**.

Do **not** blindly re-run this script after completing Stage 3.

The installation performs Wazuh indexer security initialization and password rotation. Re-running it against an already configured Wazuh installation can leave credentials out of sync.

### Certificate Authority

The installation creates internal PKI material under:

```text
/root/wazuh-install
```

The Wazuh CA private key is important infrastructure key material.

**Back it up securely.**

Do not commit the generated certificates, passwords, or private keys to Git.

### Run

```bash
chmod +x 03-wazuh-allinone.sh
sudo ./03-wazuh-allinone.sh
```

The script performs final health checks against:

```text
wazuh-indexer
wazuh-manager
filebeat
wazuh-dashboard
```

It also verifies the Filebeat → Indexer and Manager → Indexer communication paths.

---

# Stage 4 — Automatic Security Updates

## `04-autoupdate.sh`

Configures unattended Debian security maintenance.

Features include:

* Automatic Debian security updates
* System mail configuration
* SMTP relay support
* AppArmor status handling
* Update notification mail
* Smartmontools/system notification mail

The script intentionally limits automatic updates to the Debian security repositories.

The Zabbix, Wazuh, and Smallstep repositories are deliberately excluded from the unattended update policy.

The script also **does not automatically reboot the server**.

### Configuration

Edit:

```bash
TS_HOSTNAME="monitor.example.ts.net"

MAIL_TO="admin@example.com"
MAIL_RELAY="mail.example.com"
MAIL_PORT="587"
MAIL_TLS="on"
MAIL_STARTTLS="on"
MAIL_FROM=""
```

If your SMTP relay requires authentication, configure the authentication values in the script as appropriate.

### Run

```bash
chmod +x 04-autoupdate.sh
sudo ./04-autoupdate.sh
```

This script is designed to be idempotent and can be re-run.

---

# Zeek + RITA Network Sensor

## `Zeek-rita.sh`

This script is separate from the primary monitoring-server installation.

It creates a network-monitoring sensor using:

* Docker
* Zeek
* RITA
* Optional Wazuh Agent forwarding

The intended architecture is:

```text
Network TAP / SPAN
        │
        ▼
   Capture NIC
        │
        ▼
    Docker Zeek
        │
        ▼
      Logs
        │
        ▼
      RITA
        │
        ▼
 C2 / Beacon Analysis
```

The script is designed around Debian 13 but should also work on Debian/Ubuntu systems with Docker.

### Basic usage

```bash
sudo ./Zeek-rita.sh --iface eno1
```

Replace `eno1` with the interface connected to the monitoring/SPAN/TAP network.

### Interface considerations

The Zeek capture interface must have a physical link/carrier before Zeek workers can start.

The script checks for this condition and normally refuses to start Zeek if the capture interface is down.

A force-start option is available for situations where you intentionally need to override this behavior.

### Version management

Zeek and RITA versions can be resolved from their GitHub releases at runtime.

For change-controlled deployments, versions can be pinned using the supported command-line options.

For example:

```bash
sudo ./Zeek-rita.sh \
    --iface eno1 \
    --zeek-tag <version> \
    --rita-tag <version>
```

Use the versions appropriate for your environment.

---

# Recommended Deployment Order

For a complete monitoring server:

```text
Fresh Debian 13 installation
          │
          ▼
      Tailscale
          │
          ▼
01-base-cockpit-mariadb.sh
          │
          ▼
02-zabbix-server.sh
          │
          ▼
03-wazuh-allinone.sh
          │
          ▼
04-autoupdate.sh
```

In short:

```bash
sudo ./01-base-cockpit-mariadb.sh
sudo ./02-zabbix-server.sh
sudo ./03-wazuh-allinone.sh
sudo ./04-autoupdate.sh
```

The stages should be executed in order.

`04-autoupdate.sh` can also be used independently on a Debian system because it does not depend on the monitoring stack.

---

# Requirements

## Operating System

Primary target:

```text
Debian 13 (Trixie)
```

The Zeek/RITA deployment script is also intended to work with Debian/Ubuntu systems that have Docker available.

## Access

You should have:

* Root access
* Internet connectivity
* Working DNS
* A correctly configured Tailscale installation
* Tailscale MagicDNS hostname
* Tailscale HTTPS certificates enabled where required

## Hardware

Resource requirements depend heavily on the number of monitored endpoints and whether Zabbix and Wazuh are installed on the same machine.

Running Zabbix and Wazuh together is significantly more resource-intensive than running either product independently.

For production deployments, size:

* CPU
* RAM
* Disk I/O
* Disk capacity
* Network throughput

according to the expected agent count and log volume.

---

# Tailscale

Tailscale is used heavily throughout this project for private management access and TLS.

The primary server expects:

```text
tailscale0
```

to be available.

The Stage 1 installer obtains a TLS certificate using:

```bash
tailscale cert <hostname>
```

The resulting certificate is used by multiple services, including Cockpit and the web services configured by the installation scripts.

This allows the management interfaces to use the server's Tailscale/MagicDNS identity rather than exposing management services directly to the public Internet.

---

# Security Considerations

These scripts configure security-sensitive infrastructure.

Before using them in production, review:

* Firewall rules
* Tailscale ACLs
* SSH configuration
* Service bind addresses
* TLS configuration
* Database credentials
* Wazuh credentials
* CA/private-key storage
* SMTP credentials
* Backup procedures
* Automatic update policies
* Log retention
* Disk encryption
* File permissions

## Never commit secrets

Do **not** commit:

```text
/root/*-credentials
/root/wazuh-install/
*.key
*.pem
*.p12
*.crt
password files
API tokens
SMTP credentials
private keys
```

Use a secure secrets-management or backup system instead.

---

# Generated Credentials

Stage 1 generates credentials automatically rather than requiring passwords to be hard-coded into the script.

The credentials are stored in a root-only file similar to:

```text
/root/.<site>-credentials
```

Protect this file appropriately.

For example:

```bash
sudo chmod 600 /root/.<site>-credentials
```

Do not copy these credentials into Git repositories, documentation, screenshots, or issue reports.

---

# Service Ports

The following ports are relevant to the stack.

| Service         |                  Port | Purpose                      |
| --------------- | --------------------: | ---------------------------- |
| Cockpit         |            `9090/tcp` | Server administration        |
| Zabbix Server   |           `10051/tcp` | Zabbix server                |
| Zabbix Agent    |           `10050/tcp` | Zabbix agent communication   |
| HTTP            |              `80/tcp` | Apache HTTP                  |
| HTTPS           |             `443/tcp` | Web interfaces               |
| Wazuh Dashboard |             `443/tcp` | Wazuh web interface          |
| Wazuh Manager   |               Various | Agent/security communication |
| Zeek            | Depends on deployment | Network monitoring           |
| RITA            |       Internal/Docker | Network analysis             |

Actual exposed ports depend on the configuration and deployment architecture.

Use your firewall and Tailscale ACLs to restrict access to management interfaces.

---

# Troubleshooting

## Check system services

```bash
systemctl --failed
```

Check an individual service:

```bash
systemctl status <service>
```

View recent logs:

```bash
journalctl -u <service> -n 100 --no-pager
```

Follow logs:

```bash
journalctl -u <service> -f
```

---

## Zabbix

Check:

```bash
systemctl status zabbix-server
systemctl status zabbix-agent2
systemctl status apache2
```

Check the Zabbix server log:

```bash
tail -f /var/log/zabbix/zabbix_server.log
```

Check whether Zabbix Server is listening:

```bash
ss -lntp | grep 10051
```

---

## Wazuh

Check:

```bash
systemctl status wazuh-indexer
systemctl status wazuh-manager
systemctl status filebeat
systemctl status wazuh-dashboard
```

Manager log:

```bash
tail -f /var/ossec/logs/ossec.log
```

Filebeat connectivity:

```bash
filebeat test output
```

Check for manager/indexer connection problems:

```bash
grep -E 'IndexerConnector initialization failed|No available server' \
    /var/ossec/logs/ossec.log
```

---

## MariaDB

Check:

```bash
systemctl status mariadb
```

Verify the database is responding:

```bash
mariadb -e "SELECT VERSION();"
```

Check the configured InnoDB buffer pool:

```bash
mariadb -N -B \
    -e "SELECT @@innodb_buffer_pool_size;"
```

---

## Tailscale

Check:

```bash
tailscale status
```

Check the assigned IPv4 address:

```bash
tailscale ip -4
```

Check the interface:

```bash
ip addr show tailscale0
```

Test MagicDNS:

```bash
ping monitor.example.ts.net
```

---

# Idempotency

Most scripts in this repository are designed to be safely re-run.

However, **not every stage has the same re-run characteristics**.

| Script                       | Re-run                                     |
| ---------------------------- | ------------------------------------------ |
| `01-base-cockpit-mariadb.sh` | Generally safe                             |
| `02-zabbix-server.sh`        | Generally safe                             |
| `03-wazuh-allinone.sh`       | **Do not re-run after initial deployment** |
| `04-autoupdate.sh`           | Safe                                       |
| `Zeek-rita.sh`               | Depends on deployment/state                |

Always read the script comments before re-running an installer.

---

# Design Philosophy

The project follows several principles:

### 1. Repeatability

A new Debian server should be configurable using the same process every time.

### 2. Minimal manual configuration

Site-specific settings are placed near the beginning of the scripts so that the majority of the installation can remain automated.

### 3. Fail early

Scripts use validation and health checks where possible rather than assuming that package installation means a service is actually working.

### 4. Private management

Tailscale is used to reduce the need to expose administrative interfaces directly to untrusted networks.

### 5. Security by default

The project attempts to:

* Generate credentials instead of hard-coding them
* Restrict private key permissions
* Use TLS
* Separate management traffic
* Apply Debian security updates
* Preserve important CA material
* Validate service health

### 6. Practical infrastructure

The scripts are designed around actual deployment problems encountered when building monitoring and security servers rather than attempting to be a generic configuration-management framework.

---

# Development

Clone the repository:

```bash
git clone https://github.com/BlackNet/Zabbix-Wazuh-CertCA-Maria-Apache-etc.git
cd Zabbix-Wazuh-CertCA-Maria-Apache-etc
```

Make scripts executable:

```bash
chmod +x *.sh
```

Before making changes, test against a disposable Debian VM.

Recommended testing workflow:

```text
Debian VM
   │
   ├── Tailscale
   │
   ├── Stage 1
   │
   ├── Stage 2
   │
   ├── Stage 3
   │
   └── Stage 4
```

For network sensors, use a separate VM or physical host with an appropriate capture interface.

---

# Contributing

Contributions, fixes, testing feedback, and improvements are welcome.

When submitting changes:

1. Test on a clean Debian installation where possible.
2. Document new configuration variables.
3. Avoid hard-coded credentials or secrets.
4. Keep scripts safe to re-run when practical.
5. Document any non-idempotent behavior.
6. Include troubleshooting information for new services.
7. Test service health after installation.
8. Do not commit generated certificates, private keys, passwords, or tokens.

---

# Roadmap

Potential future improvements include:

* [ ] Centralized configuration file
* [ ] Better preflight validation
* [ ] Automated firewall configuration
* [ ] Improved backup/restore procedures
* [ ] Configuration validation/linting
* [ ] Automated testing in Debian VMs
* [ ] CI testing with GitHub Actions
* [ ] More modular service installers
* [ ] Optional PostgreSQL support
* [ ] Additional Zabbix templates
* [ ] Additional Wazuh integrations
* [ ] Automated certificate renewal testing
* [ ] Better sensor deployment documentation
* [ ] Containerized development/test environment
* [ ] Version pinning for all external repositories
* [ ] Production hardening profiles

---

# Disclaimer

These scripts modify system packages, services, networking, authentication, databases, TLS certificates, and security tooling.

**Use them at your own risk.**

Always test changes in a disposable environment before deploying them to production.

The author is not responsible for data loss, service outages, security issues, configuration errors, or system damage resulting from the use of these scripts.

---

# License

Add the project's license here.

For example:

```text
MIT License
```

or replace this section with the license that applies to the repository.

---

# Author

**BlackNet**

GitHub:

https://github.com/BlackNet

Repository:

https://github.com/BlackNet/Zabbix-Wazuh-CertCA-Maria-Apache-etc

---

## Related Projects

This project builds on several excellent open-source technologies:

* Zabbix — infrastructure and application monitoring
* Wazuh — security monitoring and XDR/SIEM capabilities
* Zeek — network security monitoring
* RITA — network beacon/C2 analysis
* MariaDB — relational database
* Apache HTTP Server — web server
* Cockpit — Linux server administration
* Tailscale — private networking and secure remote access
* Debian — operating system

---

## Quick Start

For a complete monitoring server on a fresh Debian 13 installation:

```bash
git clone https://github.com/BlackNet/Zabbix-Wazuh-CertCA-Maria-Apache-etc.git

cd Zabbix-Wazuh-CertCA-Maria-Apache-etc

chmod +x *.sh

sudo ./01-base-cockpit-mariadb.sh
sudo ./02-zabbix-server.sh
sudo ./03-wazuh-allinone.sh
sudo ./04-autoupdate.sh
```

For a network-monitoring sensor:

```bash
sudo ./Zeek-rita.sh --iface eno1
```

**Always review and customize the site-specific configuration in each script before running it.**
