#!/bin/zsh --no-rcs

:<<EXTENSION_ATTRIBUTE
----------------------------------------
TITLE: Platform Single Sign-on Status
VERSION: 1.5
PURPOSE: Checks if the user is registered with Platform Single Sign-on and reports registered username, login type, and token status.

7/14/2026 | Howie Canterbury
----------------------------------------
EXTENSION_ATTRIBUTE

# USER VARIABLES
currentUser=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk -F': ' '/[[:space:]]+Name[[:space:]]:/ { if ( $2 != "loginwindow" ) { print $2 }}' )
currentUser_id=$(/usr/bin/id -u "$currentUser" 2>/dev/null)
alt_sec_id=$(dscl . read /Users/$currentUser dsAttrTypeStandard:AltSecurityIdentities | awk -F'SSO:' '/PlatformSSO/ {print $2}')

# RUN AS CURRENT USER FUNCTION
# ----------------------------------
runAsUser() {
	if [[ "$currentUser" != "loginwindow" ]] && [[ -n "$currentUser" ]]; then
		/bin/launchctl asuser "$currentUser_id" sudo -u "$currentUser" "$@"
	fi
}

# PSSO LOGIN TYPE
# Password Sync or Secure Enclave
# ----------------------------------
psso_login_type() {
	local loginType=$(runAsUser /usr/bin/app-sso platform -s | grep '"loginType"' | sed -E 's/.*"(POLoginType[^ ]+).*/\1/' | sort -u)
	case $loginType in
		POLoginTypeUserSecureEnclaveKey )
			type="Secure Enclave"
		;;
		POLoginTypePassword )
			type="Password Sync"
		;;
		* )
			type=""
	esac
	
	echo $type
}

# TOKEN STATUS CHECK
# Are tokens received? Are tokens current (not expired)?
# ----------------------------------
token_status_check() {
	token_received=$(runAsUser /usr/bin/app-sso platform -s | grep -A1 "Received:" | tail -n1 | tr -d ' ')
	token_expires=$(runAsUser /usr/bin/app-sso platform -s | grep -A1 "Expiration:" | tail -n1 | awk '{print $1}' | tr -d ' ')
	
	# Default to not expired unless proven expired
	expired="no"
	
	if [[ -n "$token_expires" ]]; then
		target_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$token_expires" "+%s" 2>/dev/null)
		now_epoch=$(date -u "+%s")
		# Check if tokens are expired
		if [[ -n "$target_epoch" ]] && (( now_epoch > target_epoch )); then
			expired="yes"
		fi
	fi
	
	# Report token status; Good or Bad
	if [[ -n "$token_received" ]] && [[ "$expired" == "no" ]]; then
		token_status="Good"
	else
		token_status="Bad"
	fi
	
	echo "$token_status"
}

# REPORT PSSO STATUS
if [[ -n "$alt_sec_id" ]]; then
	logged_in="Yes"
	echo "<result>$(printf '%s\n' "Registered: ${logged_in}" "Username: ${alt_sec_id}" "Login Type: $(psso_login_type)" "Token Status: $(token_status_check)")</result>"
else
	exit 0
fi
