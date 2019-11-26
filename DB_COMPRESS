#!/bin/bash
date="$(date +%d-%m-%Y)"
echo "Welcome to database compress script!"
ls /var/lib/mysql
echo "Where to save DBs? Press Enter to use default path (/var/backup/DBs_$date))"
read SAVE_DIRECTORY
#If no directory is specified, the default will be created and used.
if [ $SAVE_DIRECTORY -z ]
then
mkdir /var/backup/DBs_$date
SAVE_DIRECTORY="/var/backup/DBs_$date"
echo "DBs will be saved to $SAVE_DIRECTORY"
else
echo "DBs will be saved to $SAVE_DIRECTORY"
fi
#check for writing to the directory
touch $SAVE_DIRECTORY/test_writing_file
if ! [ -f $SAVE_DIRECTORY/test_writing_file ]; then
echo "Something wrong with writing to $SAVE_DIRECTORY"
else
rm $SAVE_DIRECTORY/test_writing_file
echo "It's ok with writing to $SAVE_DIRECTORY"
echo "Enter DB names"
read -a SELECTEDDB
for i in "${SELECTEDDB[@]}"
do
mysqldump -u root $i | gzip > $SAVE_DIRECTORY/$i.sql.gz
done
fi
echo "Script done. Results:"
ls -lha $SAVE_DIRECTORY
