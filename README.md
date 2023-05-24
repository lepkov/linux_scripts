# linux_scripts

***trigger_GH_Action.sh***

Triggers GH action with workflow_dispatch manual start option. Needed when debugging or developing new Github Action.

**amzn_linux2_install_docker.sh**

Install docker & docker compose to AWS Amazon Linux EC2.

**whois_bulk.sh**

Bulk DNS records parsing from source file to result file. Parsed fields are: IP, OrgName, Country, City, StateProv, role, netname.

**rsync_backup.sh**

It rsync's mounted via CIFS.mount Windows Share skipping RECYCLE.BIN and System Volume Information to chosen $dst. All attributes, mirror copy, deletes files if they were deleted in $src.

**DNS_SOA_SCAN.sh**

Script outputs SOA record of specified domain(-s)
Usage:
./DNS_SOA_SCAN.sh yandex.ru google.com

Ouput:
ns1.yandex.ru.
ns1.google.com.

**DB_COMPRESS.sh**

Script will show all your DBs, then ask you for directory to save DBs or it will create and use default directory (/var/backup/DBs_$date). 
Next step script will check for permission to write to selected dir. Then you just enter DB names and script packs it to .gz and shows the result.

**SITES_COMPRESS.sh**

Script will show all your sites (/var/www), then ask you for directory to save sites or it will create and use default directory (/var/backup/sites_$date). 
Next step script will check for permission to write to selected dir. Then you just enter site names and script packs it to .tar.gz and shows the result.

**backup_mysql_db.sh**

Script backups MySQL DB and then checks if it did correctly. Success/Fail information writes to the log file. Script removes backups that are corrupted or older thank 24 hours.
