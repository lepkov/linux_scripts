#!/bin/bash
#apt install whois netbase dnsutils -y
IP_LIST="ip.txt"
echo "WHOIS for IPs in ip.txt:" > result.txt
for ip in `cat $IP_LIST`
do
    L1=`whois $ip | grep -m 1 'OrgName' | tr -s ' ' | sed 's/OrgName: //g'`
    L2=`whois $ip | grep -m 1 'Country' | tr -s ' ' | sed 's/Country: //g'`
    L3=`whois $ip | grep -m 1 'City' | tr -s ' ' | sed 's/City: //g'`
    L4=`whois $ip | grep -m 1 'StateProv' | tr -s ' ' | sed 's/StateProv: //g'`
    C="${ip}, ${L1}, ${L2}, ${L3}, ${L4}"
    echo $C >> result.txt
    #sleep 1
done
