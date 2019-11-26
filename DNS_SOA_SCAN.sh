#!/bin/bash
while [ -n "$1" ]
do
temp=`dig SOA $1 | sed -n '/ANSWER SECTION/{n;p;}'| awk {'print $5'}`
echo "$temp"
shift
done
