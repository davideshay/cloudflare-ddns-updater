#!/bin/bash

AUTH_EMAIL=${AUTH_EMAIL:=""}                            # The email used to login 'https://dash.cloudflare.com'
AUTH_METHOD=${AUTH_METHOD:="token"}                     # Set to "global" for Global API Key or "token" for Scoped API Token
AUTH_KEY=${AUTH_KEY:=""}                                # Your API Token or Global API Key
ZONE_IDENTIFIER=${ZONE_IDENTIFIER:=""}                  # Can be found in the "Overview" tab of your domain
DOMAIN_NAME=${DOMAIN_NAME:=""}                          # Domain name to update - (no prefix)
RECORD_NAMES=${RECORD_NAMES:=""}                        # Which records you want to be synced (space separated list, without full domain name). If left empty will only update domain name entry
TTL=${TTL:="3600"}                                      # Set the DNS TTL (seconds)
PROXY=${PROXY:="false"}                                 # Set the proxy to true or false
UPDATE_IPV6=${UPDATE_IPV6:="false"}                     # Update IPV6 records in addition to IPV4
MODE=${MODE:="loop"}                                    # "loop" or "once" - run forever in loop or just once
REPEAT_SECONDS=${REPEAT_SECONDS:="300"}                 # If in loop mode, how often to run
CACHE_FILE=${CACHE_FILE:= $(mktemp /tmp/ddns.XXXXXXXX)}  # file name to hold cached IP address

set -f            # Allow for fields like RECORD_NAMES to have wildcard values

###################################################
# Dependencies: curl, sed, grep, jq
###################################################

###################################################
# Cache file structure
# ipv4 x.y.z.a
# ipv6 1234:5678:abcd::9263
###################################################

###################################################
# Logging function --> stdout only for containers
#  $1 - level (D/I/E/W/C)
#  $2 - message
###################################################
function logit () {
  prefix=$(date +%x\ %X)
  prefix=$prefix" "$1
  echo $prefix" "$2
}

###########################################
## Validate Input Parameters
###########################################
function validate_input () {
    if [ -z $AUTH_EMAIL ]; then
        logit E "No email address provided"
        exit 1
    fi
    if [ $AUTH_METHOD != "token" ] &&  [ $AUTH_METHOD != "global" ]; then
        logit E "Invalid Authorization method - must be token or global"
        exit 1
    fi
    if [ -z $AUTH_KEY ]; then
        logit E "No authorization key provided"
        exit 1
    fi
    if [ -z $ZONE_IDENTIFIER ]; then
        logit E "No Zone Identifier provided"
        exit 1
    fi
    if [ -z $DOMAIN_NAME ]; then
        logit E "No Domain Name provided"
        exit 1
    fi
    if [ $PROXY != "true" ] && [ $PROXY != "false" ]; then
        logit E "Proxy must be set to true or false"
        exit 1
    fi
    if [ $UPDATE_IPV6 != "true" ] && [ $UPDATE_IPV6 != "false" ]; then
        logit E "Update IPV6 must be set to true or false"
        exit 1
    fi
    if [ $MODE != "loop" ] && [ $MODE != "once" ]; then
        logit E "Mode must be loop or once"
        exit 1
    fi
    int_re='^[0-9]+$'
    if ! [[ $REPEAT_SECONDS =~ $int_re ]]; then
        logit E "Repeat seconds must be an integer"
        exit 1
    fi
    if ! [ -f $CACHE_FILE ]; then
        logit E "Specified Cache file does not exist"
        exit 1
    fi
}

###########################################
## Check if we have a public IP
###########################################
function get_current_ipaddr () {
  ipv4_regex='([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])'
  ipv4=$(curl -s -4 https://cloudflare.com/cdn-cgi/trace | grep -E '^ip'); ret=$?
  if [[ ! $ret == 0 ]]; then # In the case that cloudflare failed to return an ip.
      # Attempt to get the ip from other websites.
      ipv4=$(curl -s https://api.ipify.org || curl -s https://ipv4.icanhazip.com)
  else
      # Extract just the ip from the ip line from cloudflare.
      ipv4=$(echo $ipv4 | sed -E "s/^ip=($ipv4_regex)$/\1/")
  fi

  # Use regex to check for proper IPv4 format.
  if [[ ! $ipv4 =~ ^$ipv4_regex$ ]]; then
      logit E "Failed to find a valid public facing IP."
      return 2
  fi
  logit D "Got current public facing IP address: ${ipv4}"
  ## TODO -- Add IPV6 retrieval from cloudflare/ipify/icanhazip
  return 0
}

###########################################
# Check if same as cached value - return 1 if true, otherwise 0
###########################################
function check_cache() {
  logit D "checking cache..."
  cached_ipv4=$(cat $CACHE_FILE | grep ipv4 | sed -n -e 's/^.*ipv4 //p')
  if [ "${cached_ipv4}" = "${ipv4}" ]; then
    logit D "Cached IP is the same as current IP - ${ipv4} - skipping update"
    return 1;
  else
    logit D "Cached IP is different than current IP - cached: ${cached_ipv4} current: ${ipv4} - update needed"
    return 0;
  fi;
}

###########################################
# Check if same as cached value - return 1 if true, otherwise 0
###########################################
function update_cache() {
  sed -n -e 's/^.*ipv4 /ipv4 ${ipv4}/g' > $CACHE_FILE
  cache_string=$(cat $CACHE_FILE)
  logit D "Cache file contents after update: ${cache_string}"
}

###########################################
# Set curl header strings
###########################################
function set_curl_headers() {
## Check and set the proper auth header
  if [[ "${AUTH_METHOD}" == "global" ]]; then
    auth_header="X-Auth-Key: ${AUTH_KEY}"
  else
    auth_header="Authorization: Bearer ${AUTH_KEY}"
  fi
  email_header="X-Auth-Email: ${AUTH_EMAIL}"
  content_header="Content-Type: application/json"
}

###########################################
#  Get current A domain-name record / old IP
# return 0 - no update needed
#        1 - different, update needed
#        2 - error retrieving info
###########################################
function get_cloudflare_domain_record {
  logit I "Check of Cloudflare initiated"

## Seek for the A record -- check only by domain name first
  local tmp_domain_out=$(mktemp '/tmp/ddns-domain-XXXXXXXX')
  local get_ipv4_code=$(curl -w '%{http_code}' -s -o ${tmp_domain_out} -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_IDENTIFIER/dns_records?type=A&name=$DOMAIN_NAME" \
                      -H "${auth_header}" -H "${email_header}" -H "${content_header}")
  if [ "$get_ipv4_code" != "200" ]; then
    logit E "Invalid return code when getting zone info: ${get_ipv4_code}"
    return 2
  fi;

  local rec_count=$(cat $tmp_domain_out | jq -r .result_info.count)
  if ! [ "${rec_count}" = "1" ]; then
    logit E "Returned more than 1 record when getting zone info"
    return 2
  fi;
  
  old_ipv4=$(cat $tmp_domain_out | jq -r .result[].content)
  if [[ ! $old_ipv4 =~ ^$ipv4_regex$ ]]; then
    logit E "Invalid IP address returned from zone data : ${old_ipv4}"
    return 2
  fi;

  rm $tmp_domain_out

## Get existing IP
  logit D "Got cloudflare ipv4 address: ${old_ipv4}"

# Compare if they're the same
  if [ "$ipv4" = "$old_ipv4" ]; then
    logit I "IP ${ipv4} for cloudflare record ${DOMAIN_NAME} has not changed."
    return 0
  fi
# Not the same
  logit I "IP on cloudflare domain record changed. Old: ${old_ipv4} Current: ${ipv4}"
  return 1
}

###########################################
# Update 1 cloudflare record
# parameters: 1 = record id to change
#             2 = name to change
###########################################
function update_one_cloudflare_record() {
  logit D "Updating one cloudflare record : $1"
  local recid_to_change=$1
  local recname_to_change=$2
  ## Change the IP@Cloudflare using the API
  update=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$recid_to_change" \
                      -H "${auth_header}" -H "${email_header}" -H "${content_header}" \
                      --data "{\"type\":\"A\",\"name\":\"$recname_to_change\",\"content\":\"$ipv4\",\"ttl\":\"$TTL\",\"proxied\":${PROXY}}")

  ## Report the status
  case "$update" in
  *"\"success\":false"*)
    logit E "Update of $ipv4 $recname_to_change DDNS failed for $recid_to_change ($ipv4). DUMPING RESULTS:\n$update"
    return 1;;
  *)
    logit I "Update: $ipv4 $recname_to_change DDNS updated."
    return 0;;
  esac

}

###########################################
# Update all cloudflare records - loop over RECORD_NAMES
###########################################
function update_all_cloudflare_records() {
    logit I "Retrieving all cloudflare domain records to update"
  # get full list of DNS records from cloudflare
    local tmp_allrecs_out=$(mktemp '/tmp/ddns-allrecs-orig-XXXXXXXX')
    local allrecs_httpcode=$(curl -s -w "%{http_code}" -o ${tmp_allrecs_out} -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_IDENTIFIER/dns_records?type=A" \
                      -H "${auth_header}" -H "${email_header}" -H "${content_header}")
    if [ "${allrecs_httpcode}" != "200" ]; then
      return 2
    fi
    local tmp_allrecs=$(mktemp '/tmp/ddns-allrecs-XXXXXXXX')
    cat $tmp_allrecs_out | jq -r '.result[] | "\(.name) \(.id) \(.content)"' > $tmp_allrecs
# produces a file with multiple lines, 1 for every record with the format:
# name record-identifier ip-address
    rm $tmp_allrecs_out

# loop through the file, check if name is in RECORD_NAMES. If so, and different, call update
    while IFS=" " read -r recname recid recip
    do
      local include_rec=false;
      if [ -z "${RECORD_NAMES}" ]; then
        logit D "Including all A records since RECORD_NAMES was empty"
        include_rec=true;
      else
        logit D "Checking everything in RECORD_NAMES: ${RECORD_NAMES}"
        for given_rec_name in $RECORD_NAMES; do
          logit D "Checking given rec name ${given_rec_name} against ${recname}"
            if [[ "${given_rec_name}.${DOMAIN_NAME}" == "${recname}" ]] || [[ "${DOMAIN_NAME}" == "${recname}" ]]; then
              logit I "Including Record ${recname} because it matches cloudflare A record"
              include_rec=true;
            fi
        done

      fi
      if [[ "${include_rec}" == "true" ]]; then
        if [ "${recip}" != ${ipv4} ]; then
          logit I "Updating cloudflare record ${recname} with id ${recid} to ip ${ipv4}"
          update_one_cloudflare_record $recid $recname
          update_result=$?
          if [ "$update_result" != "0" ]; then
            logit E "Update failed, exiting current loop"
          fi
        else
          logit I "Cloudflare record ${recname} with id ${recid} already has new ip ${ipv4}"
        fi
      else
        logit I "Ignoring cloudflare record ${recname} with id ${recid} - not in RECORD_NAMES"
      fi
    done < $tmp_allrecs
    rm $tmp_allrecs

}

###########################################
# Get/Check/Update - one time
###########################################
function get_check_update() {
  get_current_ipaddr
  local got_ip_ok=$?
  if [ "$got_ip_ok" != "0" ]; then
      logit E "Error getting IP address"
      return 1
  fi
  check_cache
  local is_same_as_cached=$?
  if [ "$is_same_as_cached" != "1" ]; then
    get_cloudflare_domain_record
    cloudflare_needs_update=$?
    # TEST
    update_all_cloudflare_records
    # END TEST
    if [ "$cloudflare_needs_update" = "1" ]; then
      logit I "Cloudflare needs to be updated with changed IP"
      update_all_cloudflare_records
      local updated_ok=$?
      if [ "$updated_ok" != "0" ]; then
          return 1;
      fi;
      update_cache
    fi
  fi
}


###########################################
# MAIN work
###########################################
logit D "Starting Main Program"
validate_input
logit D "Input Validation Complete"
set_curl_headers
logit D "Curl Headers Set"
if [ "${MODE}" = "once" ]; then
  logit I "Checking IP address for updates needed one time"
  get_check_update
  rm ${CACHE_FILE}
  exit 0;
fi
while [ true ]
do
  logit I "Checking IP address for changes on timer loop"
  get_check_update
  sleep ${REPEAT_SECONDS}
done
rm ${CACHE_FILE}

