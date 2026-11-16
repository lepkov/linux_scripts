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
- [fedora_os_update.sh](#fedora_os_updatesh)
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
- **Description:** Universal non-interactive OS refresh for apt-based hosts (Ubuntu, Debian, Kali and derivatives). Covers APT packages, Snap, Flatpak, Docker images, running Docker Compose stacks, rustup/pipx/npm toolchains, initramfs and GRUB. Every section is failure-isolated and timeout-bounded: a failing step is recorded and the run moves on to the next one, then a summary lists what succeeded, was skipped and failed. Nothing destructive happens by default — firmware flashing, `docker system prune` and the release upgrade are opt-in.
- **Release upgrade:** on Ubuntu it calls `do-release-upgrade` (requires `--yes`); on Kali, which has no `do-release-upgrade`, it runs the rolling `apt dist-upgrade` after `kali-check-apt-sources`.
- **Usage:**
  ```bash
  sudo ./ubuntu_os_update.sh                     # normal run
  ./ubuntu_os_update.sh --dry-run                # plan only, no root, no changes
  sudo ./ubuntu_os_update.sh --yes               # also update global npm packages
  sudo ./ubuntu_os_update.sh --release-upgrade   # Ubuntu: next release (add --yes) / Kali: dist-upgrade
  ```
- **Options:** `--dry-run`, `--yes`, `--firmware`, `--prune-docker`, `--release-upgrade`, `--no-user-tools`, `--user NAME`, `--timeout SEC`, `--keep N`, `-h/--help`.
- **Exit codes:** `0` success, `1` some sections failed, `2` preconditions not met, `64` bad usage, `75` another run holds the lock, `130` interrupted by a signal.
- **Logs:** `/var/log/ubuntu_os_update_YYYYmmdd_HHMMSS.log` (mode `0600`, the last 20 are kept).

### ubuntu_os_update_cron.sh
- **Description:** The scheduled wrapper around `ubuntu_os_update.sh` for unattended weekly maintenance. It runs the refresh, then the host-local custom updates script (if the host has one), sends exactly one short Telegram message with the aggregated result and reboots the host only after the Bot API confirmed the delivery. The refresh logic stays in `ubuntu_os_update.sh`; this script adds the schedule-facing behaviour, so every host runs byte-identical code.
- **Message contract:** one line, host identifier first, never the full log:
  - `✅ <host>: обновление прошло успешно`
  - `⚠️ <host>: надо разобраться (код N, лог <path>)`
- **Delivery gate:** the Bot API must answer `"ok":true`. Up to `--attempts` tries (default 3), at least `--retry-delay` seconds apart (default 30), first into the Telegram topic (`message_thread_id`, default 1) and then without it. Without a confirmed delivery the host is **not** rebooted: the log records `REBOOT SKIPPED (notification not delivered)` and the exit code is non-zero.
- **Credentials:** read from `--env-file` (default `/etc/ubuntu_os_update.env`, mode `0600`) as `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, optional `TELEGRAM_THREAD_ID`. The token is never logged.
- **Usage:**
  ```bash
  sudo ./ubuntu_os_update_cron.sh                          # refresh + notify + reboot
  sudo ./ubuntu_os_update_cron.sh --no-reboot              # refresh + notify, keep the host up
  sudo ./ubuntu_os_update_cron.sh --notify-only            # Telegram delivery smoke test
  sudo ./ubuntu_os_update_cron.sh --dry-run                # plan only, no notify, no reboot
  sudo ./ubuntu_os_update_cron.sh --host "vm (10.0.0.5)" --custom-updates /usr/local/sbin/host-custom-updates.sh
  ```
- **Options:** `--host`, `--env-file`, `--update-script`, `--custom-updates`, `--notify-only`, `--no-reboot`, `--dry-run`, `--log-dir`, `--attempts`, `--retry-delay`, `--thread-id`, `-h/--help`; everything after `--` is passed to `ubuntu_os_update.sh`.
- **Custom updates script:** the host-local step run after the refresh (for example the 1Panel self-update on the Home Server). Its non-zero exit code is reported in the aggregated message; a missing or non-executable script is reported as code `127`. Hosts without host-only software simply pass no `--custom-updates`.
- **Exit codes:** `0` success, `1` the refresh or the custom updates script failed, `2` the log is not writable, `3` the notification was not delivered, `64` bad usage.
- **Logs:** `/var/log/ubuntu_os_update_cron.log` (the wrapper) plus the refresh log it points at.
- **Tests:** `python -m unittest discover -s tests -p "test_*.py"` — the wrapper is exercised with stub `curl`/`reboot`/refresh scripts, so no host, network or reboot is involved.

### deploy_os_update_cron.sh
- **Description:** Idempotent deployment of the weekly OS refresh to a remote apt host that has no Ansible repository of its own — the Kali VM on the Hyper-V Default Switch (dynamic `172.26.x.x` address) is the first user. It copies both scripts over SSH, installs `/etc/ubuntu_os_update.env` (`0600`) from `--telegram-env`, writes `/etc/cron.d/ubuntu-os-update`, removes the `--legacy-job` entries and reads everything back. Every write is guarded by a sha256 comparison, so a second run reports `changed=0`.
- **Usage:**
  ```bash
  ./deploy_os_update_cron.sh --address 172.26.249.148 --user kali \
      --host-label "kali (172.26.249.148)" --telegram-env ~/.telegram.env
  ```
- **Schedule:** `--cron-spec "0 5 * * 0"` (Sunday 05:00) with `--expected-tz +0500`. The script reads the host timezone with `date +%z`, refuses to write when it does not match, and never passes `--release-upgrade`: Kali keeps the default weekly set (no rolling dist-upgrade).
- **Kali specifics:** the VM may be powered off on Sunday 05:00 — the job then simply does not run. There is deliberately no boot-time or catch-up trigger.
- **Host-only software policy:** software that exists on only one host and needs updates is updated by that host's custom updates script (`--custom-updates`), not by `ubuntu_os_update.sh`. The shared script stays generic; the wrapper runs the custom script after it and aggregates both exit codes into the single Telegram message. The Home Server uses this for its 1Panel self-update; OCI and Kali have no host-only software and pass no custom script.

### fedora_os_update.sh
- **Description:** The Fedora counterpart of `ubuntu_os_update.sh`: universal non-interactive OS refresh for Fedora and the dnf-based RHEL family, with KDE Plasma specifics. Drives `dnf` (dnf4 and dnf5) through metadata refresh, upgrade, autoremove and cache cleanup, and additionally updates Flatpak, Snap (when present), registry Docker images, running Compose stacks and rustup/pipx/npm toolchains, then refreshes the KDE service cache with `kbuildsycoca`. It keeps the same failure isolation, timeout and summary as the Ubuntu script, and detects a dead repository even though dnf still exits 0 on it. When Plasma itself was upgraded the run tells the operator to log out and back in.
- **Release upgrade:** staged, never automatic — `--release-upgrade --releasever N` runs `dnf system-upgrade download` for the target release; the reboot stays manual unless `--reboot` is passed. Boot Loader Specification entries are regenerated by dnf on every kernel install, so `grub2-mkconfig` is deliberately not run.
- **Usage:**
  ```bash
  sudo ./fedora_os_update.sh                     # normal run
  ./fedora_os_update.sh --dry-run                # plan only, no root, no changes
  sudo ./fedora_os_update.sh --yes               # also update global npm packages
  sudo ./fedora_os_update.sh --release-upgrade --releasever 46   # stage the next release
  ```
- **Options:** `--dry-run`, `--yes`, `--firmware`, `--prune-docker`, `--release-upgrade`, `--releasever N`, `--reboot`, `--no-user-tools`, `--user NAME`, `--timeout SEC`, `--keep N`, `-h/--help`.
- **Exit codes:** `0` success, `1` some sections failed, `2` preconditions not met, `64` bad usage, `75` another run holds the lock, `130` interrupted by a signal.
- **Logs:** `/var/log/fedora_os_update_YYYYmmdd_HHMMSS.log` (mode `0600`, the last 20 are kept).
- **Note:** `--timeout` terminates a running dnf transaction; on very slow links use `--timeout 0`, and check `dnf history` if a transaction was interrupted.

### backup_and_delete_viruses/
- **Description:** Remediation suite containing `backup_and_delete_viruses.sh` and `viruses.txt` designed to read malicious file paths, adjust permissions, isolate them into a directory tree, and package them into a timestamped `.tar.gz` quarantine archive before cleanup.
- **Usage:** Add full file paths of infected files to `backup_and_delete_viruses/viruses.txt` (one per line) and run:
  ```bash
  cd backup_and_delete_viruses && bash backup_and_delete_viruses.sh
  ```
