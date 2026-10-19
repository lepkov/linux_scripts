# linux_scripts

A collection of lightweight Linux shell scripts and utilities for system administration, backups, maintenance, and security automation.

## Table of Contents

- [trigger_GH_Action.sh](#trigger_gh_actionsh)
- [amzn_linux2_install_docker.sh](#amzn_linux2_install_dockersh)
- [whois_bulk.sh](#whois_bulksh)
- [rsync_backup.sh](#rsync_backupsh)
- [DNS_SOA_SCAN.sh](#dns_soa_scansh)
- [DB_COMPRESS.sh](#db_compresssh)
- [SITES_COMPRESS.sh](#sites_compresssh)
- [backup_mysql_db.sh](#backup_mysql_dbsh)
- [ubuntu_os_update.sh](#ubuntu_os_updatesh)
- [backup_and_delete_viruses/](#backup_and_delete_viruses)

---

## Scripts & Utilities

### trigger_GH_Action.sh
- **Description:** Triggers a GitHub Actions workflow manually via the GitHub REST API using `workflow_dispatch`. Useful for debugging or triggering CI/CD pipelines without making code commits.
- **Usage:** Configure `TOKEN`, `BRANCH`, `ORG_OR_USERNAME`, `REPO`, and `FILENAME_OR_WORKFLOW_ID` inside the script, then execute:
  ```bash
  ./trigger_GH_Action.sh
  ```

### amzn_linux2_install_docker.sh
- **Description:** Automates the installation and service startup of Docker CE and Docker Compose on AWS Amazon Linux 2 EC2 instances, adding `ec2-user` to the `docker` group and enabling the service on boot.
- **Usage:**
  ```bash
  bash amzn_linux2_install_docker.sh
  ```

### whois_bulk.sh
- **Description:** Performs bulk WHOIS lookups for IP addresses listed in `ip.txt` and writes semicolon-delimited metadata (`IP; OrgName; Country; City; StateProv; role; netname`) to `result.txt`.
- **Usage:** Populate `ip.txt` with target IPs (one per line) and run:
  ```bash
  ./whois_bulk.sh
  ```

### rsync_backup.sh
- **Description:** Mirrors files via `rsync` from a CIFS-mounted Windows share to a target directory, preserving file attributes and permissions while automatically excluding `$RECYCLE.BIN` and `System Volume Information`.
- **Usage:** Configure `src`, `dst`, and `log` paths, then execute:
  ```bash
  ./rsync_backup.sh
  ```

### DNS_SOA_SCAN.sh
- **Description:** Queries and prints Start of Authority (SOA) primary nameserver records for one or more target domain names using `dig`.
- **Usage:**
  ```bash
  ./DNS_SOA_SCAN.sh domain1.com domain2.org
  ```

### DB_COMPRESS.sh
- **Description:** Interactive MySQL/MariaDB database dump and gzip compression utility that prompts for an export directory, validates write permissions, and archives selected databases into `.sql.gz`.
- **Usage:**
  ```bash
  ./DB_COMPRESS.sh
  ```

### SITES_COMPRESS.sh
- **Description:** Interactive website file backup utility that lists `/var/www` web roots, prompts for a target backup location, verifies write permissions, and compresses selected sites into `.tar.gz`.
- **Usage:**
  ```bash
  ./SITES_COMPRESS.sh
  ```

### backup_mysql_db.sh
- **Description:** Automated MySQL database backup script with integrity verification of dump header and footer lines, status logging, and automatic pruning of backups older than 24 hours (1440 minutes).
- **Usage:**
  ```bash
  ./backup_mysql_db.sh
  ```

### ubuntu_os_update.sh
- **Description:** Comprehensive maintenance utility for Ubuntu systems that performs unattended updates for APT, Snap, Flatpak, firmware (`fwupdmgr`), and Docker Compose services, with cleanup and optional release upgrade support (`--release-upgrade`).
- **Usage:**
  ```bash
  sudo bash ubuntu_os_update.sh
  # Or perform release upgrade:
  sudo bash ubuntu_os_update.sh --release-upgrade
  ```

### backup_and_delete_viruses/
- **Description:** Remediation suite containing `backup_and_delete_viruses.sh` and `viruses.txt` designed to read malicious file paths, adjust permissions, isolate them into a directory tree, and package them into a timestamped `.tar.gz` quarantine archive before cleanup.
- **Usage:** Add full file paths of infected files to `backup_and_delete_viruses/viruses.txt` (one per line) and run:
  ```bash
  cd backup_and_delete_viruses && bash backup_and_delete_viruses.sh
  ```
