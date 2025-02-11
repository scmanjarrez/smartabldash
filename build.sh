#!/bin/bash
errormsg(){
	echo -e "\e[0;31m"Error: "\e[0m""$1"
}

# check for main url
if [ -z ${ghpageurl+x} ]; then
	errormsg "Unable to find the gh page url"
	exit 1
fi

if [[ "$*" == *"verbose"* ]] || [[ "$*" == *"-v"* ]]; then
	VERBOSE=true
else
	VERBOSE=false
fi

#[Local variables]#############################################
# local repo folder for www content
dataDir="./docs/"

# where should we store the json relative to the datadir
jsonDir="json/"

# octoprint download dirs
pluginSrc="https://plugins.octoprint.org/plugins.json"
statsSrc="https://data.octoprint.org/export/plugin_stats_30d.json"

# previous files from the website
curTotals="${ghpageurl}/${jsonDir}totals.json"
curDetails="${ghpageurl}/${jsonDir}details.json"

# local save for json files for uploading later on
localTotals="${dataDir}${jsonDir}totals.json"
localDetails="${dataDir}${jsonDir}details.json"

# users config file
configFile="./config.json"

now=$(date +'%Y-%m-%d')
##############################################################

echo "Building data for ${ghpageurl}"

if $VERBOSE; then
	echo 'Data dir         : '"$dataDir"
	echo 'JSON path        : '"$jsonDir"
	echo 'Plugins info src : '"$pluginSrc"
	echo 'Plugins stats src: '"$statsSrc"
	echo 'Current totals   : '"$curTotals"
	echo 'Current details  : '"$curDetails"
	echo 'Local totals     : '"$localTotals"
	echo 'Local details    : '"$localDetails"
	echo 'Config file      : '"$configFile"
fi

# Config file found
if [ ! -f $configFile ] || [ ! -s "$configFile" ]; then
	errormsg "Unable to find valid plugin configfile: $configFile"
	exit 1
fi

# check for jq
if ! command -v jq &> /dev/null; then
	apt-get install jq
fi

# check dir
if [ ! -d "${dataDir}${jsonDir}" ]; then
	echo "Creating local output folder ${dataDir}${jsonDir}"
	mkdir -p "${dataDir}${jsonDir}"
fi


#[Get local site stats for merging]###########################
# get current files local gh page data
HTTP_CODE=$(curl -sS -f "$curTotals" -w "%{http_code}" --output "$localTotals" 2> /dev/null)
retVal=$?
if [ $retVal -ne 0 ]; then
	if [[ $HTTP_CODE -ne "404" ]]; then
		errormsg "Failed to download from ${curTotals}"
		exit $?
	fi
	# Create a blank if no data ie 404 was found
	echo "Found no existing data in $curTotals"
	echo "{}" > $localTotals
fi


HTTP_CODE=$(curl -sS -f "$curDetails" -w "%{http_code}" --output "$localDetails" 2> /dev/null)
retVal=$?
if [ $retVal -ne 0 ]; then
	if [[ $HTTP_CODE -ne "404" ]]; then
		errormsg "Failed to download from ${curDetails}"
		exit $?
	fi
	# Create a blank if no data ie 404 was found
	echo "Found no existing data in $curDetails"
	echo "{}" > $localDetails
fi
##############################################################

# import totals from old data:
# echo "{}" > $localTotals
# echo "{}" > $localDetails
# curl -sS -f "https://raw.githubusercontent.com/LazeMSS/plugins-dashboard/LazeMSS/data/stats.json" --output tmp_import.json
# jq 'reduce (.uicustomizer.history | .[] | { (.date) : .total}) as $item ({}; . + $item)|{"uicustomizer":.}' tmp_import.json > tmp_export.json
# jq -s '.[0] * .[1]' tmp_export.json $localTotals > tmp_merge.json
# mv tmp_merge.json $localTotals

# jq 'reduce (.toptemp.history | .[] | { (.date) : .total}) as $item ({}; . + $item)|{"toptemp":.}' tmp_import.json > tmp_export.json
# jq -s '.[0] * .[1]' tmp_export.json $localTotals > tmp_merge.json
# mv tmp_merge.json $localTotals

#[Download stats from OctoPrint.org]##########################
# get octoprint data
curl -sS -f $pluginSrc --output tmp_OPplugins.json
retVal=$?
if [ $retVal -ne 0 ]; then
	errormsg "Failed to download from ${pluginSrc}"
	exit $retVal;
fi
curl -sS -f $statsSrc --output tmp_OPstats.json
retVal=$?
if [ $retVal -ne 0 ]; then
	errormsg "Failed to download from ${statsSrc}"
	exit $retVal;
fi
##############################################################

# check the config file for errors
mapfile -t plugins < <(jq -cr '.[]' $configFile)
if [ ${#plugins[@]} -eq 0 ]; then
	errormsg "Zero entries found in $configFile"
	exit 1
fi
echo "Found ${#plugins[@]} plugin(s) in $configFile"


# convert config to object to make it parsable
configMap=$(jq -c '[ .[] | {key: (.), value: null} ] | from_entries' config.json)
configMap2=${configMap,,}
# build generic totals
jq -c --argjson config "$configMap" --argjson config2 "$configMap2" --arg now "$now" --slurpfile result "$localTotals" '
	[
	.plugins | to_entries | .[] | select(.key | in($config) or in($config2)) |
		{
			(.key | ascii_downcase): {
				($now): (.value.instances)
			}
	}
	] | reduce .[] as $add ($result[0]; . * $add)' tmp_OPstats.json > tmp_merge.json

# Copy to final output
mv tmp_merge.json $localTotals

# build details part 1
jq -c --argjson config "$configMap" --argjson config2 "$configMap2" --arg now "$now" --slurpfile result "$localDetails" '
	[
		.[] | select(.id | in($config) or in($config2)) |
		{
			(.id | ascii_downcase): {
				($now): {
					"installbase": (.stats),
					"ghissues": (.github.issues),
					"ghstars": (.github.stars)
				}
			}
		}
	] | reduce .[] as $add ($result[0]; . * $add)' tmp_OPplugins.json > tmp_merge.json
# Copy to final output
mv tmp_merge.json $localDetails

# Build version stats
jq -c --argjson config "$configMap" --argjson config2 "$configMap2" --arg now "$now" --slurpfile result "$localDetails" '
	[
	.plugins | to_entries | .[] | select(.key | in($config) or in($config2)) |
		{
			(.key | ascii_downcase): {
				($now): {
					"versions" : (.value.versions | map_values(.instances))
				}
			}
	}
	] | reduce .[] as $add ($result[0]; . * $add)' tmp_OPstats.json > tmp_merge.json

# Copy to final output
mv tmp_merge.json $localDetails

# cleanup
rm tmp_* 2> /dev/null

# copy config file to the website for loading
cp $configFile ${dataDir}${jsonDir}config.json

# Update in
sed -i 's/id=\"lastudpated\">.*<\/span>/id=\"lastudpated\">'"$(date +'%Y-%m-%d %H:%M:%S')"'<\/span>/' docs/index.html
