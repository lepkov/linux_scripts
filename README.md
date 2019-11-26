# linux_scripts
DNS_SOA_SCAN.sh
Script outputs SOA record of specified domain(-s)
Usage:
./DNS_SOA_SCAN.sh yandex.ru google.com

Ouput:
ns1.yandex.ru.
ns1.google.com.

DB_COMPRESS.sh
Script will show all your DBs, then ask you for directory to save DBs or it will create and use default directory (/var/backup/DBs_$date). 
Next step script will check for permission to write to selected dir. Then you just enter DB names and script packs it to .gz and shows the result.

SITES_COMPRESS.sh
Script will show all your sites (/var/www), then ask you for directory to save sites or it will create and use default directory (/var/backup/sites_$date). 
Next step script will check for permission to write to selected dir. Then you just enter site names and script packs it to .tar.gz and shows the result.
