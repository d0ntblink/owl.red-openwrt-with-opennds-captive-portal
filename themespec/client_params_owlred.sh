#!/bin/sh
#Copyright (C) owl.red 2024-2026
#This software is released under the GNU GPL license.
#
# owl.red Guest Network — Custom OpenNDS Status Page
# Replaces /usr/lib/opennds/client_params.sh
# Busybox ash compatible (no bashisms)
#
# Called by openNDS with:
#   $1 = status type ("status" or "err511")
#   $2 = client IP address
#   $3 = base64 encoded query string (optional)
#

status=$1
clientip=$2
b64query=$3

do_ndsctl () {
	local timeout=4

	for tic in $(seq $timeout); do
		ndsstatus="ready"
		ndsctlout=$(eval ndsctl "$ndsctlcmd")

		for keyword in $ndsctlout; do

			if [ $keyword = "locked" ]; then
				ndsstatus="busy"
				sleep 1
				break
			fi
		done

		if [ "$ndsstatus" = "ready" ]; then
			break
		fi
	done
}

urlencode() {
	entitylist="
		s/%/%25/g
		s/\s/%20/g
		s/\"/%22/g
		s/>/%3E/g
		s/</%3C/g
		s/'/%27/g
		s/\`/%60/g
	"
	local buffer="$1"

	for entity in $entitylist; do
		urlencoded=$(echo "$buffer" | sed "$entity")
		buffer=$urlencoded
	done

	urlencoded=$(echo "$buffer" | awk '{ gsub(/\$/, "\\%24"); print }')
}

get_option_from_config() {

	if [ ! -z "$1" ]; then
		param=$(/usr/lib/opennds/libopennds.sh get_option_from_config "$1")
			urlencode "$param"
			param=$urlencoded
			eval $1="$param" &>/dev/null
	fi
}

get_client_zone () {
	failcheck=$(echo "$clientif" | grep "get_client_interface")

	if [ -z $failcheck ]; then
		client_if=$(echo "$clientif" | awk '{printf $1}')
		client_meshnode=$(echo "$clientif" | awk '{printf $2}' | awk -F ':' '{print $1$2$3$4$5$6}')
		local_mesh_if=$(echo "$clientif" | awk '{printf $3}')

		if [ ! -z "$client_meshnode" ]; then
			client_zone="MeshZone: $client_meshnode"
		else
			client_zone="LocalZone: $client_if"
		fi
	else
		client_zone=""
	fi
}

htmlentityencode() {
	entitylist="
		s/\"/\&quot;/g
		s/>/\&gt;/g
		s/</\&lt;/g
		s/%/\&#37;/g
		s/'/\&#39;/g
		s/\`/\&#96;/g
	"
	local buffer="$1"

	for entity in $entitylist; do
		entityencoded=$(echo "$buffer" | sed "$entity")
		buffer=$entityencoded
	done

	entityencoded=$(echo "$buffer" | awk '{ gsub(/\$/, "\\&#36;"); print }')
}

parse_variables() {
	for var in $queryvarlist; do
		evalstr=$(echo "$query" | awk -F"$var=" '{print $2}' | awk -F', ' '{print $1}')
		evalstr=$(printf "${evalstr//%/\\x}")

		htmlentityencode "$evalstr"
		evalstr=$entityencoded

		if [ -z "$evalstr" ]; then
			continue
		fi

		eval $var=$(echo "\"$evalstr\"")
		evalstr=""
	done
	query=""
}

parse_parameters() {

	if [ "$status" = "status" ]; then
		ndsctlcmd="json $clientip"
		do_ndsctl

		if [ "$ndsstatus" = "ready" ]; then
			param_str=$ndsctlout

			for param in gatewayname gatewayaddress gatewayfqdn mac version ip client_type clientif session_start session_end \
				last_active token state upload_rate_limit_threshold download_rate_limit_threshold \
				upload_packet_rate upload_bucket_size download_packet_rate download_bucket_size \
				upload_quota download_quota upload_this_session download_this_session upload_session_avg download_session_avg
			do
				val=$(echo "$param_str" | grep "\"$param\":" | awk -F'"' '{printf "%s", $4}')

				if [ "$val" = "null" ]; then
					val="Unlimited"
				fi

				if [ -z "$val" ]; then
					eval $param=$(echo "Unavailable")
				else
					eval $param=$(echo "\"$val\"")
				fi
			done

			gatewayname_dec=$(printf "${gatewayname//%/\\x}")
			htmlentityencode "$gatewayname_dec"
			gatewaynamehtml=$entityencoded

			get_client_zone

			sessionstart=$(date -d @$session_start)

			if [ "$session_end" = "Unlimited" ]; then
				sessionend=$session_end
			else
				sessionend=$(date -d @$session_end)
			fi

			lastactive=$(date -d @$last_active)
		fi
	else
		mountpoint=$(/usr/lib/opennds/libopennds.sh tmpfs)
		. $mountpoint/ndscids/ndsinfo
	fi
}

header() {
	header="<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta http-equiv=\"Cache-Control\" content=\"no-cache, no-store, must-revalidate\">
<meta http-equiv=\"Pragma\" content=\"no-cache\">
<meta http-equiv=\"Expires\" content=\"0\">
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
<link rel=\"stylesheet\" type=\"text/css\" href=\"$url/splash.css\">
<title>owl.red &mdash; Session Status</title>
<style>body{background:#1e1e2e;color:#cdd6f4;font-family:sans-serif;margin:0;padding:0}
.offset{max-width:640px;margin:0 auto;padding:16px}
.insert{background:#313244;border-radius:12px;padding:20px;margin:10px 0}
input[type=submit],input[type=button]{background:#89b4fa;color:#1e1e2e;border:none;padding:12px 24px;border-radius:8px;font-size:1em;font-weight:bold;cursor:pointer;margin:6px 4px}
hr{border:none;border-top:1px solid #585b70;margin:16px 0}
img{max-width:100%;height:auto;border-radius:8px}</style>
</head>
<body>
<div class=\"offset\">
<div class=\"insert\" style=\"max-width:100%;\">

<div style=\"text-align:center;\">
<img src=\"$url/images/welcome-owl.jpg\" alt=\"Welcome\" style=\"max-width:200px;border-radius:12px;margin-bottom:12px;\">
</div>
<h2 style=\"color:#cba6f7;text-align:center;margin:0 0 4px 0;\">owl.red guest</h2>
<p style=\"color:#89b4fa;text-align:center;font-size:0.9em;margin:0 0 12px 0;\">Session Status</p>
<hr>
"
	echo "$header"
}

footer() {
	echo "
<div style=\"text-align:center;font-size:0.7em;color:#585b70;margin-top:16px;\">owl.red guest &mdash; openNDS $version</div>
</div>
</div>
</body>
</html>"
}

body() {
	if [ "$ndsstatus" = "busy" ]; then
		echo "
<p style=\"color:#f9e2af;text-align:center;\">The portal is busy. Please click Refresh.</p>
<div style=\"text-align:center;\">
<form><input type=\"button\" value=\"Refresh\" onClick=\"history.go(0);return true;\"></form>
</div>"

	elif [ "$status" = "status" ]; then

		if [ "$upload_rate_limit_threshold" = "Unlimited" ] || [ "$upload_packet_rate" = "Unlimited" ]; then
			upload_packet_rate="N/A"
			upload_bucket_size="N/A"
		fi

		if [ "$download_rate_limit_threshold" = "Unlimited" ] || [ "$download_packet_rate" = "Unlimited" ]; then
			download_packet_rate="N/A"
			download_bucket_size="N/A"
		fi

		checked="$advanced"

		# Logout and Refresh controls
		echo "
<div style=\"text-align:center;margin-bottom:12px;\">
<form action=\"$url/opennds_deny/\" method=\"get\" style=\"display:inline;\">
<input type=\"submit\" value=\"Logout\" style=\"background:#f38ba8;color:#1e1e2e;\">
</form>
</div>

<form action=\"$url/\" method=\"get\" style=\"text-align:center;margin-bottom:16px;\">
<label style=\"font-size:0.85em;color:#a6adc8;cursor:pointer;\">
<input type=\"checkbox\" value=\"checked\" name=\"advanced\" $checked style=\"accent-color:#89b4fa;\">
Show advanced details
</label>
<br>
<input type=\"submit\" value=\"Refresh\" style=\"margin-top:8px;\">
</form>
<hr>
"
		if [ "$advanced" = "checked" ]; then
			echo "
<div style=\"font-size:0.82em;line-height:2;\">
<div style=\"display:grid;grid-template-columns:auto 1fr;gap:4px 14px;\">
<span style=\"color:#89b4fa;font-weight:bold;\">IP Address</span><span>$ip</span>
<span style=\"color:#89b4fa;font-weight:bold;\">MAC Address</span><span>$mac</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Client Type</span><span>$client_type</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Network Zone</span><span>$client_zone</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Interface</span><span>$clientif</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Session Start</span><span>$sessionstart</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Session End</span><span>$sessionend</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Last Active</span><span>$lastactive</span>
</div>
<hr>
<div style=\"display:grid;grid-template-columns:auto 1fr;gap:4px 14px;\">
<span style=\"color:#89b4fa;font-weight:bold;\">Download Limit</span><span>$download_rate_limit_threshold Kb/s</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Download Rate</span><span>$download_packet_rate pkt/min</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Download Bucket</span><span>$download_bucket_size pkts</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Upload Limit</span><span>$upload_rate_limit_threshold Kb/s</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Upload Rate</span><span>$upload_packet_rate pkt/min</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Upload Bucket</span><span>$upload_bucket_size pkts</span>
</div>
<hr>
<div style=\"display:grid;grid-template-columns:auto 1fr;gap:4px 14px;\">
<span style=\"color:#89b4fa;font-weight:bold;\">Download Quota</span><span>$download_quota KB</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Upload Quota</span><span>$upload_quota KB</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Downloaded</span><span>$download_this_session KB</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Uploaded</span><span>$upload_this_session KB</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Avg Download</span><span>$download_session_avg Kb/s</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Avg Upload</span><span>$upload_session_avg Kb/s</span>
</div>
</div>"
		else
			echo "
<div style=\"font-size:0.85em;line-height:2;\">
<div style=\"display:grid;grid-template-columns:auto 1fr;gap:4px 14px;\">
<span style=\"color:#89b4fa;font-weight:bold;\">IP Address</span><span>$ip</span>
<span style=\"color:#89b4fa;font-weight:bold;\">MAC Address</span><span>$mac</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Session Start</span><span>$sessionstart</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Session End</span><span>$sessionend</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Downloaded</span><span>$download_this_session KB</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Uploaded</span><span>$upload_this_session KB</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Avg Download</span><span>$download_session_avg Kb/s</span>
<span style=\"color:#89b4fa;font-weight:bold;\">Avg Upload</span><span>$upload_session_avg Kb/s</span>
</div>
</div>"
		fi

	elif [ "$status" = "err511" ]; then
		get_option_from_config "fasremoteip"
		get_option_from_config "fasremotefqdn"
		get_option_from_config "login_option_enabled"

		if [ -z "$fasremoteip" ] && [ -z "$fasremotefqdn" ] && [ "$login_option_enabled" -eq 0 ]; then
			echo "
<p style=\"color:#f38ba8;text-align:center;font-weight:bold;\">Portal Not Available</p>
<p style=\"color:#a6adc8;text-align:center;font-size:0.9em;\">The captive portal is not configured. Please contact the network administrator.</p>
<div style=\"text-align:center;\">
<form action=\"$url/login\" method=\"get\" target=\"_self\">
<input type=\"submit\" value=\"Retry\">
</form>
</div>"
		else
			echo "
<p style=\"color:#f9e2af;text-align:center;font-size:1.1em;\">You need to log in to access the Internet.</p>
<div style=\"text-align:center;margin:16px 0;\">
<form action=\"$url/login\" method=\"get\" target=\"_self\">
<input type=\"submit\" value=\"Continue to Login\" style=\"background:#a6e3a1;color:#1e1e2e;padding:14px 32px;font-size:1.1em;\">
</form>
</div>"
		fi

	else
		exit 1
	fi
}

# Start generating the html
if [ -z "$clientip" ]; then
	exit 1
fi

# Download remote images if configured
/usr/lib/opennds/libopennds.sh download "/usr/lib/opennds/download_resources.sh" "" "" "0" "" &>/dev/null

imagepath="images/welcome-owl.jpg"

if [ "$status" = "status" ] || [ "$status" = "err511" ]; then
	parse_parameters

	if [ -z "$gatewayfqdn" ] || [ "$gatewayfqdn" = "disable" ] || [ "$gatewayfqdn" = "disabled" ]; then
		url="http://$gatewayaddress"
	else
		url="http://$gatewayfqdn"
	fi

	querystr=""

	if [ ! -z "$b64query" ]; then
		ndsctlcmd="b64decode $b64query"
		do_ndsctl
		querystr=$ndsctlout

		querystr=${querystr:1:1024}
		queryvarlist=""

		for element in $querystr; do
			htmlentityencode "$element"
			element=$entityencoded
			varname=$(echo "$element" | awk -F'=' '$2!="" {printf "%s", $1}')
			queryvarlist="$queryvarlist $varname"
		done

		query=$querystr
		parse_variables
	fi

	header
	body
	footer
	exit 0
else
	exit 1
fi
