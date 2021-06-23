#!/bin/bash
log=/var/log/SRV1backup.log
src=/mnt/SRV1/
dst=/backups/SRV1
cat /dev/null | tee $log $log.error
rsync -v -arlpE8XogDth --exclude '$RECYCLE.BIN' --exclude 'System Volume Information' --ignore-errors --progress --delete --delete-during $src $dst --log-file=$log
cat $log | grep -E ".rsync\:." > $log.error
