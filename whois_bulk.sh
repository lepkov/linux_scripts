#!/bin/bash
#apt install whois netbase dnsutils -y
IP_LIST="ip.txt"
echo "WHOIS for IPs in ip.txt:" > result.txt
for ip in `cat $IP_LIST`
do
    L1=`whois $ip | grep -m 1 'OrgName' | tr -s ' ' | sed 's/OrgName: //g'`
    [[ "$L1" == "" ]] && L1=`whois $ip | grep -m 1 'org-name' | tr -s ' ' | sed 's/org-name: //g'`
    L2=`whois $ip | grep -m 1 'Country' | tr -s ' ' | sed 's/Country: //g'`
    [[ "$L2" == "" ]] && L2=`whois $ip | grep -m 1 'country' | tr -s ' ' | sed 's/country: //g'`
    L3=`whois $ip | grep -m 1 'City' | tr -s ' ' | sed 's/City: //g'`
    [[ "$L3" == "" ]] && L3="No City"
    L4=`whois $ip | grep -m 1 'StateProv' | tr -s ' ' | sed 's/StateProv: //g'`
    [[ "$L4" == "" ]] && L4="No State"
    L5=`whois $ip | grep -m 1 'role' | tr -s ' ' | sed 's/role: //g'`
    [[ "$L5" == "" ]] && L5="No Role"
    L6=`whois $ip | grep -m 1 'netname' | tr -s ' ' | sed 's/netname: //g'`
    [[ "$L6" == "" ]] && L6="No Netname"
    C="${ip}; ${L1}; ${L2}; ${L3}; ${L4}; ${L5}; ${L6}"
    echo $C >> result.txt
    #sleep 1
done

#cat result.txt | awk -F "; " '{print $3}'
