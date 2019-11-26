#!/bin/bash
while [ -n "$1" ]
do
echo `dig SOA $1 | sed -n '/ANSWER SECTION/{n;p;}'| awk {'print $5'}`
shift
done
