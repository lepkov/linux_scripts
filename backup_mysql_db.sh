#!/bin/bash

#ключи mysqldump
OPTS="-v --add-drop-database --add-locks --create-options --disable-keys --extended-insert --single-transaction --quick --set-charset --routines --events --triggers --comments --quote-names --order-by-primary --hex-blob"
#файл дампа
FNAME="/mnt/backup/`date +%Y-%m-%d_%H-%M`_dbname.sql"
#лог результатов проверки дампа
LOG="/var/log/mysql/backup.log"
#лог вывода mysqldump
MLOG="/var/log/mysql"
#формат даты
DATA=`date +%Y-%m-%d_%H-%M`

#делаем дамп базы и записываем вывод в лог
/usr/bin/mysqldump ${OPTS} --databases dbname -u'root' -p'password' > ${FNAME} 2>> ${MLOG}/${DATA}-mysqldump.log
#сжимаем лог
/usr/bin/gzip ${MLOG}/${DATA}-mysqldump.log

#проверяем первую и последнюю строки дампа
BEGIN=`head -n 1 ${FNAME} | grep ^'-- MySQL dump' | wc -l`
END=`tail -n 1 ${FNAME} | grep ^'-- Dump completed' | wc -l`

#если обе строки верны, то пишем в лог ОК и сжимаем дамп
if [ "$BEGIN" == "1" ];then
if [ "$END" == "1" ];then
    echo `date +%F_%H-%M` ${FNAME} is OK >> $LOG
    /usr/bin/gzip ${FNAME}
else
    echo `date +%F_%H-%M` ${FNAME} is corrupted >> $LOG
    /usr/bin/rm ${FNAME}
fi
else
    echo `date +%F_%H-%M` ${FNAME} is corrupted >> $LOG
    /usr/bin/rm ${FNAME}
fi
#если дамп не проходит проверки, удаляем его и пишем в лог corrupted

#удаляем бэкапы и логи старше суток.
find /mnt/backup -type f -mmin +1440 -exec rm -rf {} \;
find /var/log/mysql/*mysqldump* -type f -mmin +1440 -exec rm -rf {} \;
