#!/bin/sh
#
# Distributed under the terms of the GNU General Public License (GPL) version 2.0
#
# script for sending updates to cloudflare.com
# based on Ben Kulbertis cloudflare-update-record.sh found at http://gist.github.com/benkulbertis
# and on George Johnson's cf-ddns.sh found at https://github.com/gstuartj/cf-ddns.sh
# Rewritten for Gargoyle Web Interface - Michael Gray 2018
# CloudFlare API documentation at https://developers.cloudflare.com/api
# To generate API tokens: https://dash.cloudflare.com/profile/api-tokens
#
# option zone - base zone/domain name (e.g. "example.com")
# option record - DNS A/AAAA record name (e.g. "@" for zone apex)
# option token - Cloudflare API Token with "Edit zone DNS" permissions (not the Global API Key)
#
# EXIT STATUSES (line up with ddns_updater)
UPDATE_FAILED=3
UPDATE_NOT_NEEDED=4
UPDATE_SUCCESSFUL=5
# API base url
URLBASE="https://api.cloudflare.com/client/v4"
# Data files
DATAFILE="/var/run/cloudflare-ddns-helper.dat"
ERRFILE="/var/run/cloudflare-ddns-helper.err"
# IPv4       0-9   1-3x "." 0-9  1-3x "." 0-9  1-3x "." 0-9  1-3x
IPV4_REGEX="[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}"
# IPv6       ( ( 0-9a-f  1-4char ":") min 1x) ( ( 0-9a-f  1-4char   )optional) ( (":" 0-9a-f 1-4char  ) min 1x)
IPV6_REGEX="\(\([0-9A-Fa-f]\{1,4\}:\)\{1,\}\)\(\([0-9A-Fa-f]\{1,4\}\)\{0,1\}\)\(\(:[0-9A-Fa-f]\{1,4\}\)\{1,\}\)"

if [ $# != 7 ] ; then
	logger -t cloudflare-ddns-helper "Incorrect number of arguments supplied. Exiting"
	printf 'cloudflare-ddns-helper usage:\n'
	printf '\tzone\t\tbase zone/domain name (e.g. \"example.com\")\n'
	printf '\trecord\t\tDNS A/AAAA record name (e.g. \"@\" or subdomain)\n'
	printf '\ttoken\t\tCloudflare API Token with \"Edit zone DNS\" permissions (not the Global API Key)\n'
	printf '\tlocal_ip\tIP address to be sent to Cloudflare\n'
	printf '\tforce_update\t1 to force update of IP, 0 to exit if already matched\n'
	printf '\tverbose\t\t0 for low output or 1 for verbose logging\n'
	printf '\tipv6\t\t0 for IPv4 output or 1 for IPv6\n'
	exit $UPDATE_FAILED
fi

ZONE=$1
RECORD=$2
TOKEN=$3
LOCAL_IP=$4
FORCE_UPDATE=$5
VERBOSE=$6
IPV6=$7

[ -z "$ZONE" ] && {
	logger -t cloudflare-ddns-helper "Invalid zone/domain"
	exit $UPDATE_FAILED
}
[ -z "$RECORD" ] && {
	logger -t cloudflare-ddns-helper "Invalid DNS record"
	exit $UPDATE_FAILED
}
[ -z "$TOKEN" ] && {
	logger -t cloudflare-ddns-helper "Invalid API token"
	exit $UPDATE_FAILED
}
[ -z "$LOCAL_IP" ] && {
	logger -t cloudflare-ddns-helper "Invalid local IP"
	exit $UPDATE_FAILED
}

[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Local IP: $LOCAL_IP, Token: $(echo "$TOKEN" | cut -c 1-8)..."
[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Zone: $ZONE, Record: $RECORD"

# Format the FQDN for the zone and record name
# zone = base domain e.g. example.com
# record = DNS A/AAAA record name e.g. subdomain (or @ for zone apex)
# host = FQDN e.g. subdomain.example.com for subdomain (or example.com for zone apex)
[ "$RECORD" = '@' ] && HOST="$ZONE" # zone apex
[ "$RECORD" != "$ZONE" ] && HOST="${RECORD}.$ZONE" # subdomain

[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Host: $HOST"

command_runner()
{
	[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "cmd: $RUNCMD"
	eval "$RUNCMD"
	ERR=$?
	if [ $ERR != 0 ] ; then
		logger -t cloudflare-ddns-helper "cURL error: $ERR"
		logger -t cloudflare-ddns-helper "$(cat $ERRFILE)"
		return 1
	fi
	
	# check status
	STATUS=$(grep '"success": \?true' $DATAFILE)
	if [ -z "$STATUS" ]; then
		logger -t cloudflare-ddns-helper "Cloudflare responded with an error"
		logger -t cloudflare-ddns-helper "$(cat $DATAFILE)"
		return 1
	fi
	
	return 0
}

# base command
CMDBASE="curl -RsS -o $DATAFILE --stderr $ERRFILE"

# force IP version
[ "$IPV6" -eq 0 ] && CMDBASE="$CMDBASE -4 " || CMDBASE="$CMDBASE -6 "

# add headers
CMDBASE="$CMDBASE --header 'Authorization: Bearer $TOKEN' "
CMDBASE="$CMDBASE --header 'Content-Type: application/json' "

# fetch zone id for domain
RUNCMD="$CMDBASE --request GET '$URLBASE/zones?name=$ZONE'"
command_runner || exit $UPDATE_FAILED

ZONEID=$(grep -o '"id": \?"[^"]*' $DATAFILE | grep -o '[^"]*$' | head -1)
if [ -z "$ZONEID" ] ; then
	logger -t cloudflare-ddns-helper "Could not detect zone ID for domain: $ZONE"
	exit $UPDATE_FAILED
fi
[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Zone ID for $ZONE: $ZONEID"

# get A or AAAA record
[ "$IPV6" -eq 0 ] && TYPE="A" || TYPE="AAAA"
RUNCMD="$CMDBASE --request GET '$URLBASE/zones/$ZONEID/dns_records?name=$HOST&type=$TYPE'"
command_runner || exit $UPDATE_FAILED

RECORDID=$(grep -o '"id": \?"[^"]*' $DATAFILE | grep -o '[^"]*$' | head -1)
if [ -z "$RECORDID" ] ; then
	logger -t cloudflare-ddns-helper "Could not detect record ID for host: $HOST"
	exit $UPDATE_FAILED
fi
[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Record ID for $HOST: $RECORDID"

# if we got this far, we can check the data for the current IP address
DATA=$(grep -o '"content": \?"[^"]*' $DATAFILE | grep -o '[^"]*$' | head -1)
[ "$IPV6" -eq 0 ] \
	&& DATA=$(printf "%s" "$DATA" | grep -m 1 -o "$IPV4_REGEX") \
	|| DATA=$(printf "%s" "$DATA" | grep -m 1 -o "$IPV6_REGEX")
[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Remote IP for $HOST: $DATA"

if [ -n "$DATA" ]; then
	[ "$DATA" = "$LOCAL_IP" ] && {
		[ "$FORCE_UPDATE" = 0 ] && {
			[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Remote IP = Local IP, no update needed"
			exit $UPDATE_NOT_NEEDED
		}
		[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Remote IP = Local IP, force update requested"
	}
fi

# if we got this far, we need to update IP with cloudflare
cat > $DATAFILE << EOF
{"id":"$ZONEID","type":"$TYPE","name":"$HOST","content":"$LOCAL_IP"}
EOF

RUNCMD="$CMDBASE --request PUT --data @$DATAFILE '$URLBASE/zones/$ZONEID/dns_records/$RECORDID'"
command_runner || exit $UPDATE_FAILED

[ "$VERBOSE" -eq 1 ] && logger -t cloudflare-ddns-helper "Remote IP updated to $LOCAL_IP"
exit $UPDATE_SUCCESSFUL
