#!/bin/bash
date="$(date +%d-%m-%Y)"
echo "Where to save all sites? Press Enter to use default path (/var/backup/sites$date))"
read SAVE_DIRECTORY
#Если не указана директория будет создана и использована дефолтная
if [ $SAVE_DIRECTORY -z ]
then
mkdir /var/backup/sites_$date
SAVE_DIRECTORY="/var/backup/sites_$date"
echo "Sites will be saved to $SAVE_DIRECTORY"
else
echo "$SAVE_DIRECTORY"
echo "Sites will be saved to $SAVE_DIRECTORY"
fi
cd $SAVE_DIRECTORY
#проверка на запись в директорию
touch $SAVE_DIRECTORY/test_writing_file
if ! [ -f $SAVE_DIRECTORY/test_writing_file ]; then
echo "Something wrong with writing to $SAVE_DIRECTORY"
else
rm $SAVE_DIRECTORY/test_writing_file
echo "It's ok with writing to $SAVE_DIRECTORY"
echo `ls /var/www/ | grep ".ru\|.xn--p1ai"`
echo "What sites to save?"
read -a SITES_ARRAY
#Упаковываем поочередно все сайты из массива
for i in "${SITES_ARRAY[@]}"
do
echo "Started packing $i..."
mkdir $i
cd $i
tar -czf ${i}.tar.gz /var/www/${i}/web
echo "Done packing $i."
cd ..
done
fi
echo "Script done. Results:"
ls -lha $SAVE_DIRECTORY
