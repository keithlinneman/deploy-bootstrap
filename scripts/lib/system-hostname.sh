#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
export PS4='+ [sub=${BASH_SUBSHELL:-?}] SOURCE:${BASH_SOURCE:-?} LINENO:${LINENO:-?} FUNC:${FUNCNAME[0]:-MAIN}: '
trap 'RC=$?; echo "ERROR(rc=$RC) at ${BASH_SOURCE[0]:-?}:${LINENO:-?} in ${FUNCNAME[0]:-MAIN}: ${BASH_COMMAND:-?}" >&2; exit $RC' ERR

localname="$( hostname )"
localip="$( ip addr show primary scope global | grep -Ev "wg[0-9]+" | awk '/inet / { print $2; exit }' | cut -d "/" -f 1 )"

echo "PATH: ${PATH}"
export PATH="${PATH}:/opt/snap/bin/"

# Lots of sanity checks - dns is critical

# check that we have a valid ip
validip="^10\.[0-9]+\.[0-9]+\.[0-9]+$"
if [[ ! "${localip}" =~ ${validip} ]];then
  echo "${localip} did not pass sanity check (${validip}) - refusing to update dns"
  exit 1
fi

# check that we have a valid instance id
localinstanceid="$( ec2metadata --instance-id | awk -F '-' '{ print $2 }' )"
if [ "${localinstanceid}x" == "x" ];then
  echo "Failed to get instanceid from ec2metadata"
  exit 1
fi
localinstanceidlen="$( echo -n "${localinstanceid}" | wc -c )"
if [ "${localinstanceidlen}" != "17" ];then
  echo "Expected localinstanceid length to be 17"
  exit 1
fi

# check that we have a valid env
if [ "${ENVIRONMENT}x" == "x" ];then
  echo "Failed to find environment name"
  exit 1
fi
validenvs=("prod" "dev" "qa" "staging" "testing")
valid=false
for env in "${validenvs[@]}"; do
  [[ "${env}" == "${ENVIRONMENT}" ]] && valid=true
done

if [[ "${valid}" != "true" ]]; then
  echo "Environment (${ENVIRONMENT}) is not in the list of valid environments (${validenvs[*]})"
  exit 1
fi

# ensure hostname has instanceid and environment in name, and is of format *<instanceid>.<regionshort>.<env>.*.* domain name and individual naming schemes can vary by app
validhost=".*${localinstanceid:0:6}\.us.*\.${ENVIRONMENT}\..*\..*"
if [[ ! "${localname}" =~ ${validhost} ]];then
  echo "${localname} did not pass sanity check (${validhost}) - refusing to update dns"
  exit 1
fi

# get local hostname without instanceid for CNAME alias
localcname="${localname/-${localinstanceid:0:6}/}"
if [ "${localcname}x" == "x" ];then
  echo "Failed to generate localcname from ${localname}"
  exit 1
fi
if [ "${localcname}" == "${localname}" ];then
  echo "Failed to generate unique localcname from localname - both are identical (${localname})"
  exit 1
fi

# ensure this zone is in deploymentsystem hosted zone, also get hostedzoneid from ssm parameter store
localdomain="$( hostname -d )"
hostedzonename="$( aws ssm get-parameter --name /platform/dns/hosted_zone/name --query "Parameter.Value" --output text )"
if [ "${hostedzonename}x" == "x" ];then
  echo "Failed to find ssm parameter for HostedZoneId from (/platform/dns/hosted_zone/name)"
  exit 1
fi
if [ "${hostedzonename}" != "${localdomain}" ];then
  echo "Local domain name (${localdomain}) does not match hosted zone name (${hostedzonename}) - refusing to update dns"
  exit 1
fi

hostedzoneid="$( aws ssm get-parameter --name /platform/dns/hosted_zone/id --query "Parameter.Value" --output text )"
if [ "${hostedzoneid}x" == "x" ];then
  echo "Failed to find ssm parameter for HostedZoneId from (/platform/dns/hosted_zone/id)"
  exit 1
fi

echo "Upserting route53 role CNAME ${localcname} to ${localname}"
changeset="$( jq -n \
 --arg cname "${localcname}" \
 --arg localname "${localname}" \
 --arg action "UPSERT" \
 --argjson ttl 60 \
 --arg type "CNAME" \
 '{
   Changes: [
     {
       Action: $action,
       ResourceRecordSet: {
         Name: $cname,
         Type: $type,
         TTL: $ttl,
         ResourceRecords: [
           {
             Value: $localname
           }
         ]
       }
     }
   ]
 }'
)"

# echo "changeset: ${changeset}"
# echo "AWS route53 call: aws route53 change-resource-record-sets --hosted-zone-id ${hostedzoneid} --change-batch ${changeset}"
awsout="$( aws route53 change-resource-record-sets --hosted-zone-id "${hostedzoneid}" --change-batch "${changeset}" )"
if [[ ! "${awsout}" =~ \"PENDING\" ]];then
  echo "Failed to create CNAME record! changeset was ${changeset}"
  echo "aws response: ${awsout}"
  exit 1
fi
echo "Success creating cname record for ${localcname} to ${localname}"

# Set ec2 instance Name tag to hostname
aws ec2 create-tags --resources "i-${localinstanceid}" --tags Key=Name,Value="${localcname}"

exit 0
