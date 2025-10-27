#!/bin/bash

API_KEY="YOUR_TRAFIKVERKET_API_KEY_HERE"
STATION_CODE="YOU_STATION_CODE_HERE"
HOURS_AHEAD=6
API_URL='https://api.trafikinfo.trafikverket.se/v2/data.json'
SCHEMA_VERSION="1.9"

if [ "$API_KEY" == "YOUR_TRAFIKVERKET_API_KEY_HERE" ]; then
  echo "Error: Please update API_KEY with your key from Trafikverket."
  exit 1
fi
if ! command -v curl &> /dev/null; then echo "Error: 'curl' is not installed."; exit 1; fi
if ! command -v jq &> /dev/null; then echo "Error: 'jq' is not installed."; exit 1; fi

NOW_UTC=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
FUTURE_UTC=$(date -u -d "+$HOURS_AHEAD hours" +"%Y-%m-%dT%H:%M:%S.000Z")
CURRENT_DATE=$(date +"%Y-%m-%d") 

read -r -d '' ANNOUNCEMENT_XML << EOM
<REQUEST>
  <LOGIN authenticationkey="$API_KEY" />
  <QUERY objecttype="TrainAnnouncement" schemaversion="$SCHEMA_VERSION" orderby="AdvertisedTimeAtLocation">
    <FILTER>
      <AND>
        <EQ name="LocationSignature" value="$STATION_CODE" />
        <OR>
          <EQ name="ActivityType" value="Ankomst" />
          <EQ name="ActivityType" value="Avgang" />
        </OR>
        <GT name="AdvertisedTimeAtLocation" value="$NOW_UTC" />
        <LT name="AdvertisedTimeAtLocation" value="$FUTURE_UTC" />
      </AND>
    </FILTER>
    <INCLUDE>AdvertisedTrainIdent</INCLUDE>
    <INCLUDE>ActivityType</INCLUDE>
    <INCLUDE>AdvertisedTimeAtLocation</INCLUDE>
    <INCLUDE>EstimatedTimeAtLocation</INCLUDE>
    <INCLUDE>TrackAtLocation</INCLUDE>
    <INCLUDE>FromLocation</INCLUDE>
    <INCLUDE>ToLocation</INCLUDE>
    <INCLUDE>Operator</INCLUDE>
    <INCLUDE>Deviation.Code</INCLUDE>       <!-- Use for basic 'Pos' info -->
    <INCLUDE>Deviation.Description</INCLUDE>
  </QUERY>
</REQUEST>
EOM

API_RESPONSE=$(curl -s -X POST "$API_URL" -H 'Content-Type: application/xml' -H 'Accept: application/json' -d "$ANNOUNCEMENT_XML")

if echo "$API_RESPONSE" | jq -e '.RESPONSE.RESULT[0].ERROR' &> /dev/null; then
  echo "API Error: Request failed." >&2
  echo "Details:" >&2
  echo "$API_RESPONSE" | jq . >&2
  exit 1
fi

if ! echo "$API_RESPONSE" | jq -e '.RESPONSE.RESULT[0].TrainAnnouncement[0]' &> /dev/null; then
  echo "Inga tågtider hittades för $STATION_CODE inom de närmaste $HOURS_AHEAD timmarna."
  exit 0
fi

read -r -d '' POSITION_XML << EOM
<REQUEST>
  <LOGIN authenticationkey="$API_KEY" />
  <QUERY objecttype="TrainAnnouncement" schemaversion="$SCHEMA_VERSION">
    <FILTER>
      <AND>
        <EQ name="ScheduledDepartureDateTime" value="$CURRENT_DATE" />
        <EXISTS name="TimeAtLocation" value="true" />
      </AND>
    </FILTER>
    <!-- Inkludera de fält vi behöver för positionslookup -->
    <INCLUDE>AdvertisedTrainIdent</INCLUDE>
    <INCLUDE>LocationSignature</INCLUDE>
    <INCLUDE>TimeAtLocation</INCLUDE>
    <INCLUDE>AdvertisedTimeAtLocation</INCLUDE>
  </QUERY>
</REQUEST>
EOM


POSITION_RESPONSE=$(curl -s -X POST "$API_URL" -H 'Content-Type: application/xml' -H 'Accept: application/json' -d "$POSITION_XML")

CLEAN_POSITION_RESPONSE=$(echo "$POSITION_RESPONSE" | sed -E 's/([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{3}[+-][0-9]{2}:[0-9]{2}"/\1Z"/g')

read -r -d '' JQ_POS_FILTER << 'JQEOF'
  if .RESPONSE.RESULT[0].TrainAnnouncement then
    .RESPONSE.RESULT[0].TrainAnnouncement |
    map(select(
        (type == "object") and
        (.AdvertisedTrainIdent | type == "string" and length > 0) and
        (.TimeAtLocation | type == "string" and length > 0) and
        (.AdvertisedTimeAtLocation | type == "string" and length > 0)
    )) |
    group_by(.AdvertisedTrainIdent) |
    map({
        key: .[0].AdvertisedTrainIdent,
        value: (
            map(
                . + {
                    TimeAtLocation_ms: (
                        (.TimeAtLocation | fromdateiso8601) * 1000
                    )
                }
            ) |
            sort_by(.TimeAtLocation_ms) | reverse | .[0] as $latest |

            if $latest then
                {
                    pos: $latest.LocationSignature,
                    delay: (
                        (($latest.TimeAtLocation | fromdateiso8601) - ($latest.AdvertisedTimeAtLocation | fromdateiso8601)) / 60
                    ) | round
                }
            else
                {pos: "", delay: 0}
            end
        )
    }) | from_entries
  else
    {}
  end
JQEOF

POSITIONS_JSON=$(echo "$CLEAN_POSITION_RESPONSE" | jq -r "$JQ_POS_FILTER")

format_line() {
  local json=$1
  local type=$2
  local pos_code=$3 # New
  local delay_min=$4 # New

  local op=$(echo "$json" | jq -r '.Operator // "?"')
  local tagnr=$(echo "$json" | jq -r '.AdvertisedTrainIdent // "?"')
  local tid=$(echo "$json" | jq -r '.AdvertisedTimeAtLocation | split("T")[1][0:5]')
  local ber_raw=$(echo "$json" | jq -r '(.EstimatedTimeAtLocation // "") | if . != "" then (. | split("T")[1][0:5]) else "" end')

  local ber=""
  if [ -n "$ber_raw" ] && [ "$ber_raw" != "$tid" ]; then
    ber="$ber_raw"
  fi

  local spar=$(echo "$json" | jq -r '.TrackAtLocation // ""')
  local cancelled=$(echo "$json" | jq -r 'if .Deviation == null then "" else [.Deviation[] | select(.Description == "Inställt")] | .[0].Description // "" end')

  if [ -n "$cancelled" ]; then
      spar="Inst."
  fi

  local pos=""
  if [ -n "$pos_code" ] && [ "$pos_code" != "null" ] && [ "$pos_code" != "" ]; then
    if [ "$delay_min" -gt 0 ]; then
      pos="$pos_code -$delay_min"
    elif [ "$delay_min" -lt 0 ]; then
      pos="$pos_code +$((delay_min * -1))"
    else
      pos="$pos_code" # I tid
    fi
  else
    pos=$(echo "$json" | jq -r 'if .Deviation == null then "" else [.Deviation[].Code | select(. != null)] | join(" ") end' | xargs)
  fi

  local location=""
  if [ "$type" == "Ankomst" ]; then
    location=$(echo "$json" | jq -r '.FromLocation[0].LocationName // "?"')
  else
    location=$(echo "$json" | jq -r '.ToLocation[0].LocationName // "?"')
  fi

  printf "%s|%s|%s|%s|%s|%s|%s\n" "$op" "$tagnr" "$location" "$tid" "$ber" "$spar" "$pos"
}

echo "Ankommande"
echo "-------------------------------------"
(
  printf "Op|Tåg|Från|Tid|Ber.|Spår|Pos\n"
  echo "$API_RESPONSE" | jq -r -c '.RESPONSE.RESULT[0].TrainAnnouncement[] | select(.ActivityType == "Ankomst")' |
  while read -r line; do
    tagnr=$(echo "$line" | jq -r '.AdvertisedTrainIdent')
    pos_data=$(echo "$POSITIONS_JSON" | jq -r ".\"$tagnr\"")
    pos_code=$(echo "$pos_data" | jq -r ".pos")
    delay_min=$(echo "$pos_data" | jq -r ".delay")
    format_line "$line" "Ankomst" "$pos_code" "$delay_min"
  done
) | column -t -s '|'

echo ""
echo "Avgående"
echo "-------------------------------------"
(
  printf "Op|Tåg|Till|Tid|Ber.|Spår|Pos\n"
  echo "$API_RESPONSE" | jq -r -c '.RESPONSE.RESULT[0].TrainAnnouncement[] | select(.ActivityType == "Avgang")' |
  while read -r line; do
    tagnr=$(echo "$line" | jq -r '.AdvertisedTrainIdent')
    pos_data=$(echo "$POSITIONS_JSON" | jq -r ".\"$tagnr\"")
    pos_code=$(echo "$pos_data" | jq -r ".pos")
    delay_min=$(echo "$pos_data" | jq -r ".delay")
    format_line "$line" "Avgang" "$pos_code" "$delay_min"
  done
) | column -t -s '|'
