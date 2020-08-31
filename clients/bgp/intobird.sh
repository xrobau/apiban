#!/bin/bash

APIKEY="REPLACE_THIS_WITH_YOUR_KEY"
# Replace this with the IP Address of this machine
LOCALIP="203.9.226.15"
# Replace this with your ASN, or a reserved ASN between 64512 - 65534 if you don't have one
LOCALASN="64545"

ROOTDIR=/usr/local/apiban
DESTDIR=$ROOTDIR/$(date +'%Y-%m-%d')
mkdir -p $DESTDIR

# Create our routing table names. We don't use them, we just use
# the numbers, but it's good to keep them documented.
declare -A TABLES=( [55]="apiban" [56]="droptxt" [57]="edroptxt" )
for t in "${!TABLES[@]}"; do
	P=$(egrep ^$t\  /etc/iproute2/rt_tables)
	[ "$P" ] && continue
	NEWTABLE="$t   ${TABLES[$t]}"
	echo Creating "$NEWTABLE"
	echo "$NEWTABLE" >> /etc/iproute2/rt_tables
done

function loadroutes() {
	declare -A ROUTES
	local TABLE=$1
	local IPS=$(echo "$2" | sort -u)
	local CLEANUP=$3
	[ "$CLEANUP" ] && ip route flush table $TABLE
	local CURRENT=$(ip -o route show table $TABLE | awk '/^[0-9]/ { print $1 }')
	for r in $CURRENT; do
        	[ "$r" ] && ROUTES[$r]="set"
	done
	for i in $IPS; do
		[ ! "${ROUTES[$i]}" ] && ip route add $i dev lo table $TABLE
       		unset ROUTES[$i]
	done
}

function apiban() {
	[ ! -e /var/run/apiban ] && echo 100 > /var/run/apiban
	[ "$1" ] && echo $1 > /var/run/apiban
	local LKID=$(tr -d '\r\n' < /var/run/apiban)
	local URL=https://apiban.org/api/$APIKEY/banned/%s
	local IPS=""

	while [[ "$LKID" =~ ^[0-9]+ ]]; do
        	JSON=$(curl -m 5 -s $(printf $URL $LKID))
        	LKID=$(echo $JSON | jq -r ".ID")
        	if [[ "$LKID" =~ ^[0-9]+$ ]]; then
        		IPS="$IPS $(echo $JSON | jq -r '.ipaddress | .[]')"
                	echo $LKID > /var/run/apiban
		fi
	done
	echo $IPS
}

# To flush, add '100' to the apiban function, and 'true' to loadroutes.
#APIBAN=$(apiban)
#[ "$APIBAN" ] && loadroutes 55 "$APIBAN"

[ ! -e $DESTDIR/drop.txt ] && wget https://www.spamhaus.org/drop/drop.txt -O $DESTDIR/drop.txt
[ ! -e $DESTDIR/edrop.txt ] && wget https://www.spamhaus.org/drop/edrop.txt -O $DESTDIR/edrop.txt

loadroutes 56 "$(awk '/^[0-9]/ { print $1 }' $DESTDIR/drop.txt)"
loadroutes 57 "$(awk '/^[0-9]/ { print $1 }' $DESTDIR/edrop.txt)"

PEERS=$(egrep -v ^\; peers.txt)

cat > /etc/bird/apiban.bird.conf << EOF

log "/var/log/bird.log" all;
log syslog all;

router id $LOCALIP;

protocol device { scan time 10; }
protocol direct { disabled; }

ipv4 table bgpban;
ipv4 table droptxt;
ipv4 table edroptxt;

filter set_communities {
        if (proto = "droptable") then {
                bgp_community.add(($LOCALASN,100));
                bgp_community.add(($LOCALASN,888));
                accept;
        }
        if (proto = "edroptable") then {
                bgp_community.add(($LOCALASN,101));
                bgp_community.add(($LOCALASN,888));
                accept;
        }
        if (proto = "apitable") then {
                bgp_community.add(($LOCALASN,102));
                bgp_community.add(($LOCALASN,888));
                accept;
        }
}

protocol kernel { ipv4 { import none; export none; }; }

protocol kernel apitable {
        learn;
        scan time 20;
        kernel table 55;
        ipv4 { import all; table bgpban; };
}

protocol kernel droptable {
        learn;
        scan time 20;
        kernel table 56;
        ipv4 { import all; table droptxt; };
}

protocol kernel edroptable {
        learn;
        scan time 20;
        kernel table 57;
        ipv4 { import all; table edroptxt; };
}

protocol pipe { table bgpban; peer table droptxt; }
protocol pipe { table bgpban; peer table edroptxt; }

EOF

for p in $PEERS; do
	[ ! "$p" ] && continue
	NAME=$(echo $p | cut -d, -f1)
	IP=$(echo $p | cut -d, -f2)
	ASN=$(echo $p | cut -d, -f3)
	if [ ! "$ASN" ]; then
		echo Something wrong with peer line $p, giving up
		exit
	fi

	echo Found $NAME at $IP with AS $ASN
	cat >> $ROOTDIR/ipv4.bird.conf << EOF

protocol bgp $NAME {
      description "$NAME";
      local $LOCALIP as $LOCALASN;
      multihop;
      graceful restart on;

      ipv4 {
              table bgpban;
              import filter {reject;};
              export filter set_communities;
      };
      neighbor $IP as $ASN;
}
EOF

done

birdc configure

