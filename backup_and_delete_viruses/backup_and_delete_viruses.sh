#!/bin/bash
# Put full virus path to viruses.txt 
# Each line will be operated
# Move to working dir of
account=$(whoami)
if [[ -e /var/www/$account/data/scripts ]]; then
  cd /var/www/$account/data/scripts
# Create tmp dir if not exist
  if [[ ! -e tmp25417 ]]; then
    mkdir tmp25417
  #echo "tmp dir created" 1>&2
# Main Cycle
# Reading paths with viruses and assigns to $name
    while read name; do
# Change virus permissions to be able to copy them
    if [[ -e $name ]]; then
      chmod 0700 $name
    fi
    echo "Virus path: $name"
# Reformat the path to remake structure inside /tmp 
    reldir=$(dirname "$name" | cut -b 28-)
  #echo "Relative virus path: $reldir"
    virusname=$(echo "$name" | rev | cut -d"/" -f1 | rev)
  #echo "Virus name: $virusname"
    date=$(date '+%T-%d.%m.%Y')
    cd tmp25417
# Create and enter virus directory path
    mkdir -p $reldir
    cd $reldir
# Option 1. Move virus to backup dir
    if [[ -e $name ]]; then
      mv $name .
      echo "Moved $name to $reldir"
    else
      echo "Skipped. Virus doesn't exist."
    fi
  # Option 2. Copy virus back
  #  if [[ -e $name ]]; then
  #    fulldir=$(dirname "$name")/
  #    cp $virusname $fulldir
  #    echo "Copied $reldir/$virusname to $fulldir"
  #  fi
  # Get back to working dir
    cd /var/www/u0738939/data/scripts
    echo "-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-/-"
    done < viruses.txt
  # Pack viruses
    cd tmp25417
    tar="viruses_backup("$date").tar.gzip"
    tar -czf $tar * --force-local
    mv $tar ..
    cd ..
  # Remove tmp dir
  # rm -rf tmp25417
  elif [[ ! -d tmp25417 ]]; then
    echo "tmp dir already exists but is not a directory. Stopping." 1>&2
  fi
else
echo "No /var/www/$account/data/scripts folder. Stopping."
fi
