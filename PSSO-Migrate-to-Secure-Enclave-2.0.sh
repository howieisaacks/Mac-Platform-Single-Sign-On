#!/bin/zsh --no-rcs

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

:<<'INFO'
----------------------------------------
TITLE: PSSO Migrate to Secure Enclave
VERSION: 2.0
PURPOSE: Migrate users from PSSO using password sync to PSSO using Secure Enclave. Prompt users to start and follow the process.

If no PSSO registration is found, the user will be prompted to register.

While the user is following steps for PSSO Secure Enclave registration, their progress is monitored.
To be considered a successful registration: 
	• The PSSO Secure Enclave profile must be installed.
	• An alternate security identity must be present
	• SSO tokens must be received and not expired
	• Login type must be Secure Enclave (POLoginTypeUserSecureEnclaveKey)

To remove the PSSO password sync profile and install the PSSO Secure Enclave profile, the Jamf Pro API is used to add the computer
to a static group scoped to receive the PSSO Secure Enclave profile and is excluded from receiving the PSSO password sync profile.
This uninstalls the PSSO password sync profile and triggers the install of the PSSO Secure Enclave profile. Normally the profile
swap is instant but the script has the smarts to wait until the profile change is complete. If the PSSO Secure Enclave profile is
not installed within 60 seconds, the script will display an alert to the user. A 3 minute timer is set for registration. An alert 
will be displayed if the 3 minute timer runs out with no successful registration.

To automatically enable Company Portal to autofill passkeys, a policy using this script is used:
https://github.com/ScottEKendall/Microsoft-Platform-SSO/blob/main/scripts/Enforce%20Portal%20AutoFill.sh
THANK YOU SCOTT KENDALL!

10/12/2026 | Howie Canterbury
----------------------------------------
INFO

# GLOBAL VARIABLES
script_version="2.0"
script_name="${0:t:r}"
currentUser=$(/usr/bin/stat -f '%Su' /dev/console)
currentUser_id=$(/usr/bin/id -u "$currentUser")
dialog_bin="/usr/local/bin/dialog"
dialogCommandFile="/private/var/tmp/dialog.log"
comp_portal="/Applications/Company Portal.app"
user_upn=$(dscl . read /Users/"$currentUser" dsAttrTypeStandard:AltSecurityIdentities 2>/dev/null | awk -F'SSO:' '/PlatformSSO/ {print $2}')

# INTERFACE COLORS - Used in Swift Dialog - Colors below were taken from the Jamf visual style guide
# https://jamf.bynder.com/guidelines/guide/09e4aa04-da69-42b0-8fbc-76548a3fc9ed
blue_violet="#5050BC"
haiti="#100F2F"
black="#181A1C"
celtic_blue="#056AE6"
freshmaker_green="#50DEAF"
deep_sea="#00348A"

# JAMF PRO API LOGIN
# --------------------------
# Parameter 4: API client ID
# Parameter 5: API client secret
# Parameter 6: Enter "yes" to validate API login
# --------------------------
url="JAMF_PRO_URL"
client_id="API_CLIENT_ID"
client_secret="API_CLIENT_SECRET"
verify="$6"

# JAMF API AUTHENTICATION FUNCTION
# --------------------------
jamfAPI_auth() {
	response=$(/usr/bin/curl -sS --location --request POST "${url}/api/oauth/token" \
		--header "Content-Type: application/x-www-form-urlencoded" \
		--data-urlencode "client_id=${client_id}" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_secret=${client_secret}")
	token=$(echo "$response" | plutil -extract access_token raw -)
	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
}

# LOG FUNCTION
# ------------------------------------------
log_file="/private/var/log/Migrate-PSSO.log"
updateLog() {
	local message="$1"
	local timestamp
	timestamp=$(/bin/date "+%Y-%m-%d %H:%M:%S")
	
	echo "${timestamp} | ${message}" | /usr/bin/tee -a "$log_file"
}

# QUIT SWIFT DIALOG
# ------------------------------------------
quit_dialog() {
	echo "quit:" >> /var/tmp/dialog.log
	sleep 2
	dialog_running=$(pgrep -x dialog)
	if [[ -n "$dialog_running" ]]; then
		echo "quit:" >> /var/tmp/dialog.log
	fi
}

# QUIT SELF SERVICE
# ------------------------------------------
quit_app() {
	local app_name="$1"
	
	# check if Jamf permissions profile is installed to allow running Apple Scripts
	# Exit the function if the profile is not installed.
	if [[ "$(check_for_jamf_profile)" == "1" ]]; then
		echo "Attempting to quit ${app_name}."
		/usr/bin/osascript -e "tell application \"${app_name}\" to quit" >/dev/null 2>&1
		/bin/sleep 2
		if /usr/bin/pgrep -x "$app_name" >/dev/null 2>&1; then
			echo "${app_name} still running. Force quitting."
			/usr/bin/pkill -x "$app_name"
		else echo "${app_name} quit successfully"
		fi
	else
		return 0
	fi
}

# EXIT WITH SUCCESS
# ------------------------------------------
exit_success() {
	local message="${1:-Script: ${script_name} completed successfully.}"
	updateLog "$message"
	exit 0
}

# EXIT WITH ERROR - Not currently used
# ------------------------------------------
exit_with_error() {
	local message="$1"
	quit_dialog
	updateLog "ERROR - ${script_name}: ${message}"
	exit 1
}

# JAMF POLICY FUNCTION
# ------------------------------------------
jamfPolicy() {
	local jamfAgent="/usr/local/jamf/bin/jamf"
	# To use run the function name followed by the policy custom trigger
	local policy="$1"
	"$jamfAgent" policy -event "$policy" --forceNoRecon > /dev/null 2>&1
}

# JAMF RECON FUNCTION
# ------------------------------------------
jamfRecon() {
	local jamfAgent="/usr/local/jamf/bin/jamf"
	"$jamfAgent" recon > /dev/null 2>&1
}

# CHECK FOR JAMF PERMISSIONS PROFILE
# ------------------------------------------
check_for_jamf_profile() {
	local jamf_permissions="PROFILE_ID"
	local check_installed=$(profiles -C -v 2>/dev/null | awk -F: '/attribute: profileIdentifier/{gsub(/^[[:space:]]+/, "", $NF); print $NF}' | grep -E "$jamf_permissions" | head -n 1)
	
	# Confirm installed
	if [[ "$check_installed" == "$jamf_permissions" ]]; then
		installed="1"
	else
		installed="0"
	fi
	
	echo $installed
}

# CHECK FOR SWIFT DIALOG
# ------------------------
dialog_check() {
	if [[ ! -e "$dialog_bin" ]]; then
		echo "Swift Dialog is not installed. Installing."
		jamfPolicy "POLICY_CUSTOM_TRIGGER"
	fi
}

# CHECK LOGGED IN USER
# ------------------------------------------
check_logged_in_user() {
	if [[ "$currentUser" == "root" || "$currentUser" == "_mbsetupuser" || -z "$currentUser" ]]; then
		updateLog "No valid user is logged in. Exiting."
		exit 0
	else
		updateLog "User ${currentUser} is logged in"
	fi
}

# RUN AS USER
#-----------------------------------------
runAsUser() {
	if [[ "$currentUser" != "loginwindow" ]] && [[ -n "$currentUser" ]]; then
		/bin/launchctl asuser "$currentUser_id" sudo -u "$currentUser" -H "$@"
	fi
}

# CHECK FOR COMPANY PORTAL
#-----------------------------------------
check_comp_portal() {
	updateLog "Checking for Company Portal..."
	if [[ ! -d "$comp_portal" ]]; then
		updateLog "Company Portal not installed. Installing..."
		jamfPolicy "install-companyportal"
		sleep 2
	else
		updateLog "Company Portal is installed at ${comp_portal}. Continuing..."
		return 0
	fi	
}

# CHECK FOR ALTERNATE SECURITY IDENTITY
# ------------------------------------------
alt_sec_ID() {
	local user_loggedin=$(dscl . read /Users/"$currentUser" dsAttrTypeStandard:AltSecurityIdentities 2>/dev/null | awk -F'SSO:' '/PlatformSSO/ {print $2}')
	
	if [[ -n "$user_loggedin" ]]; then
		echo "1"
	else
		echo "0"
	fi
}

# INSTALL PLATFORM SINGLE SIGN-ON SECURE ENCLAVE PROFILE
# Add computer to Platform Single Sign-on Secure Enclave static group
# This group is excluded from the Platform Single Sign-on Password Sync profile. This will trigger its removal.
# Group ID: JAMF PRO STATIC GROUP SCOPED TO RECEIVE PSSO SECURE ENCLAVE PROFILE
# ---------------------------
install_psso_se_profile() {
	local timeout=60
	local check_interval=2
	local start_time

	# Start authenticated API session
	updateLog "Starting API session"
	jamfAPI_auth
	
	# Check and verify API login
	if [[ "$verify" == "yes" ]]; then
		updateLog "API token: ${token}"
		updateLog "Token expires in: ${token_expires_in} seconds"
	fi
	
	# This is where the magic happens! The API command adds the computer to the PSSO Secure Enclave group which uninstalls the old profile and installs the new one.
	local group_ID="GROUP_ID"
	local serial=$(/usr/sbin/system_profiler SPHardwareDataType 2>/dev/null | /usr/bin/awk -F': ' '/Serial Number/ {print $2}')
	local jss_ID=$(curl -sS -G "${url}/api/v1/computers-inventory" --data-urlencode "filter=hardware.serialNumber=="${serial}"" --data-urlencode "section=GENERAL" --header "Authorization: Bearer ${token}" --header "Accept: application/json" | jq -r '.results[0].id')	
	
	updateLog "Uninstalling Platform Single Sign-on password sync profile. Installing Platform Single Sign-on Secure Enclave profile. Assigning to group ID ${group_ID}"
	
	curl -sS -X PUT "${url}/JSSResource/computergroups/id/$group_ID" -H "Authorization: Bearer ${token}" -H "Content-Type: application/xml" -d "<computer_group><computer_additions><computer><id>$jss_ID</id></computer></computer_additions></computer_group>" > /dev/null
	
	# Run check for PSSO Secure Enclave profile
	case "$(check_for_profile)" in
		0) updateLog "Waiting for PSSO Secure Enclave profile to install" 
			;;
		1) updateLog "PSSO Secure Enclave profile has been installed. Continuing..." 
			return 0 # Exit this function and continue
			;;
		*) updateLog "Waiting for PSSO Secure Enclave profile to install" 
			;;
	esac
	
	# If the profile has not yet installed, continue checking for install success for up to 60 seconds
	start_time=$SECONDS
	while (( SECONDS - start_time < timeout )); do
		sleep "$check_interval"
		if [[ "$(check_for_profile)" == "1" ]]; then
			updateLog "PSSO Secure Enclave profile has been installed. Continuing..."
			return 0 # Exit this function and continue
		fi
	done

	updateLog "Timed out after ${timeout} seconds waiting for the PSSO Secure Enclave profile to install."
	display_timeout_retry_dialog "profile"
}

# CHECK FOR SSO TOKENS
#-----------------------------------------
token_status() {
	local token_received=$(runAsUser /usr/bin/app-sso platform -s | grep -A1 "Received:" | tail -n1 | tr -d ' ')
	local token_expires=$(runAsUser /usr/bin/app-sso platform -s | grep -A1 "Expiration:" | tail -n1 | awk '{print $1}' | tr -d ' ')
	
	if [[ -n "$token_received" ]] && [[ -n "$token_expires" ]]; then
		token_status="1"
	else
		token_status="0"
	fi
	
	echo "$token_status"
}

# CHECK PROFILE INSTALL STATUS - Using profile IDs for better accuracy
# 1 = installed  0 = not installed
# ------------------------

# Platform Single Sign-on Secure Enclave profile ID
psso_se_id="PROFILE ID FOR SECURE PSSO ENCLAVE PROFILE"

check_for_profile() {
	check_installed=$(profiles -C -v 2>/dev/null | awk -F: '/attribute: profileIdentifier/{gsub(/^[[:space:]]+/, "", $NF); print $NF}' | grep -E "$psso_se_id" | head -n 1)
	
	# Confirm installed
	if [[ "$check_installed" == "$psso_se_id" ]]; then
		installed="1"
	else
		installed="0"
	fi
	
	echo $installed
}

# CHECK PSSO LOGIN TYPE
# ------------------------
psso_login_type() {
	if [[ "$(alt_sec_ID)" == "1" ]]; then
		loginType=$(runAsUser /usr/bin/app-sso platform -s | /usr/bin/grep '"loginType"' | /usr/bin/sed -E 's/.*"(POLoginType[^ ]+).*/\1/' | /usr/bin/sort -u)
		
		case "$loginType" in
			POLoginTypeUserSecureEnclaveKey)
				echo "Secure Enclave"
			;;
			POLoginTypePassword)
				echo "Password Sync"
			;;
			*)
				echo "User not registered"
			;;
		esac
	else
		echo "User not registered"
	fi
}

# TRIGGER PSSO REGISTRATION PROMPT
# ------------------------------------------
trigger_prompt() {
	echo "Triggering PSSO registration prompt"
	pkill AppSSOAgent
	sleep 1
	runAsUser app-sso -l > /dev/null 2>&1
}

# CHECK FOR SUCCESSFUL PSSO SECURE ENCLAVE REGISTRATION
# ------------------------
check_psso_success() {
if [[ "$(check_for_profile)" == "1" ]] && [[ "$(psso_login_type)" == "Secure Enclave" ]] && [[ "$(token_status)" == "1" ]]; then
	echo "Success"
else
	echo "Fail"
fi
}

# WAIT FOR PSSO SE REGISTRATION TO COMPLETE
# Write success status and quit Dialog when complete
# ------------------------
waiting_for_psso_se() {
	local timeout="180"
	local check_interval=2
	local start_time=$SECONDS

	updateLog "Waiting for PSSO Secure Enclave registration to complete. Timeout: ${timeout} seconds."
	while (( SECONDS - start_time < timeout )); do
			sleep "$check_interval"
		if [[ "$(check_psso_success)" == "Success" ]]; then
			updateLog "Platform Single Sign-on registration using Secure Enclave has completed."
			sleep 2
			# Authorize Company Portal to auto-fill passkeys
			passkey_auth
			# Run Jamf inventory; ensures that PSSO status shows in inventory
			updateLog "Running inventory to update PSSO status for this Mac. Aren't you glad you ate your Wheaties today?"
			jamfRecon
			exit 0
		fi
	done

	updateLog "Timed out after ${timeout} seconds waiting for PSSO Secure Enclave registration to complete."
	display_timeout_retry_dialog "registration"
}

# RUN PSSO PROMPTS
# ------------------------
run_psso_prompts() {
	local profile_status

	# Prompt user to migrate to PSSO Secure Enclave
	display_upgrade_prompt

	updateLog "display_upgrade_prompt returned exit code: ${update_result}"

	sleep 1
	quit_app "Self Service"

	# Process input from update prompt
	case "$update_result" in
		0)
			updateLog "User clicked the Upgrade button."

			profile_status="$(check_for_profile)"
			updateLog "PSSO Secure Enclave profile check returned status: ${profile_status}."

			if [[ "$profile_status" != "1" ]]; then
				updateLog "Secure Enclave profile is not installed. Installing profile.."
				install_psso_se_profile
			fi

			# Display notification informing user that they need to check for a registration prompt
			display_notification
			;;

		*)
			updateLog "Update prompt returned unexpected exit code ${update_result}. Terminating migration."
			exit 1
			;;
	esac

	# Process input from display notification prompt
	case "$notification_result" in
		0)
			updateLog "User clicked Continue."
			return 0
			;;
		4) # Option available only if timer was used in display_notification function
			updateLog "Dismissing look for notification alert. Timer has run out"
			return 0
			;;
		*)
			updateLog "Registration notification returned unexpected exit code ${notification_result}."
			return 1
			;;
	esac
}

# AUTHORIZE COMPANY PORTAL TO AUTOFILL PASSKEYS
# Run policy that uses https://github.com/ScottEKendall/Microsoft-Platform-SSO/blob/main/scripts/Enforce%20Portal%20AutoFill.sh
# ------------------------
passkey_auth() {
	updateLog "Authorizing Company Portal to auto-fill passkeys"
	jamfPolicy POLICY_CUSTOM_TRIGGER
	
	sleep 2
	
	if [[ "$(passkey_auth_status)" == "1" ]]; then
		updateLog "Company Portal has been authorized to autofill passkeys"
	else
		updateLog "Failed to authorize Company Portal to autofill passkeys. Will try again later at check-in."
	fi
}

# CHECK FOR SUCCESSFULL PASSKEY AUTOFILL AUTH
# ------------------------------------------
passkey_auth_status() {
	local cp_ssoext=$(runAsUser pluginkit -m | grep "com.microsoft.CompanyPortalMac.Mac-Autofill-Extension" | awk '{print $1}')
	local cp_autofill=$(runAsUser pluginkit -m | grep "com.microsoft.CompanyPortalMac.ssoextension" | awk '{print $1}')
	
	if [[ "$cp_ssoext" == "+" ]] && [[ "$cp_autofill" == "+" ]]; then
		echo "1"
	else
		echo "0"
	fi
}

# DISPLAY DIALOG TO PROMPT FOR MIGRATION TO SECURE ENCLAVE
# ------------------------
display_upgrade_prompt()  {
	local dialog_cmd
	
	dialog_cmd=(
		--moveable
		--bannertitle "Mac + PretendCo Account Upgrade"
		--bannerheight "50"
		--titlefont "color=${freshmaker_green},size=24,weight=light,shadow=1"		
		--bannerimage "color=${deep_sea},nogradient"
		--icon "SF=macbook.gen2,palette=${black},none,${celtic_blue}"
		--overlayicon "SF=lock.shield.fill,palette=${freshmaker_green},none,${deep_sea},bgcolor=none"
		--iconsize "200"
		--message "Click **Upgrade Account** to upgrade your PretendCo account on this Mac to use **Secure Enclave** authentication.<br><br>You will be prompted to register to complete the upgrade.<br><br>After the upgrade is complete, your Mac password will no longer sync with your PretendCo account.<br><br>**Click ? for more info.**"
		--button1text "Upgrade Account"
		--buttonsize "large"
		--button1symbol "lock.shield,color=${freshmaker_green},weight=bold"
		--buttontextsize "18"
		--background "color=white,nogradient"
		--helpsheetbuttontext "Got it!"
		--helpmessage "### We're upgrading your Mac + PretendCo sign-in.\n Your Mac will use a more secure method to login to your apps and connect to PretendCo services.<br><br>Your Mac password will no longer sync with your PretendCo Entra ID account. Why is this better?<br>• No problems logging in to your Mac after a PretendCo password change.<br>• Your password can't be stolen since it won't be stored on your Mac.<br>• Logging in to PretendCo services will use passkeys which is more secure than your password.<br><br>### No more password sync. Change your Mac password as often as you like."
		--appearance "light"
		--infotext "Signed in as: ${user_upn}<br>version ${script_version}"
	)
	
	"${dialog_bin}" "${dialog_cmd[@]}"
	
	update_result="$?"
}

# DISPLAY DIALOG INSTRUCTING USER TO LOOK FOR REGISTATION NOTIFICATION
# ------------------------
display_notification()  {
	local dialog_cmd
	
	dialog_cmd=(
		--moveable
		--bannertitle "Look for Registration Required notification"
		--bannerheight "50"
		--titlefont "color=${freshmaker_green},size=24,weight=light,shadow=1"
		--bannerimage "color=${deep_sea},nogradient"
		--message "### Look for Registration Required prompt.<br>Click date and time to check Notification Center if the registration prompt has not appeared.<br><br>From the prompt, click **Register** to begin."
		--background "color=white,nogradient"
		--image "https://raw.githubusercontent.com/howieisaacks/Images/main/PSSOSE-Register-Prompt.png"
		--appearance "light"
		--button1text "" # Left this value blank to hide the button
		--buttonsize "large"
		--buttontextsize "18"
		--height "450"
		--timer "20"
		--hidetimerbar
		--infotext "This window will close automatically after 20 seconds."
	)
	
	# Launch Swift Dialog; run Dialog command
	"${dialog_bin}" "${dialog_cmd[@]}"

	notification_result="$?"
}

# DISPLAY ERROR/TIMEOUT MESSAGE
# ------------------------
display_timeout_retry_dialog() {
	local timeout_type="$1"
	local dialog_version
	local dialog_title
	local dialog_message
	local dialog_result
	local dialog_cmd
	
	case "$timeout_type" in
		profile)
			dialog_title="Account upgrade could not start"
			dialog_message="The Secure Enclave configuration did not install within 60 seconds. Click **Retry** to try again, or **Cancel** to try again later."
		;;
		registration)
			dialog_title="Account upgrade timed out"
			dialog_message="Secure Enclave registration did not complete within 3 minutes. Click **Retry** to try again, or **Cancel** to try again later."
		;;
	esac
	
	dialog_cmd=(
		--moveable
		--ontop
		--bannertitle "$dialog_title"
		--titlefont "colour=${freshmaker_green},size=24,weight=regular,shadow=1"
		--bannerimage "colour=${deep_sea},nogradient"
		--bannerheight "50"
		--appearance "light"
		--background "color=white,nogradient"
		--message "$dialog_message"
		--icon "SF=lock.shield.fill,palette=${freshmaker_green},none,${data_blue}"
		--overlayicon "warning"
		--centericon
		--button1text "Retry"
		--button2text "Cancel"
		--buttonsize "large"
		--buttontextsize "18" 
		--height "350"
	)
	
	# Launch Swift Dialog; run Dialog command
	"${dialog_bin}" "${dialog_cmd[@]}"
	
	dialog_result=$?
	
	# Process response; retry or cancel
	if [[ "$dialog_result" == "0" ]]; then
		updateLog "User opted to try again"
		# Relaunch upgrade process from the beginning; skip Preflight
		main "1"
	else
		updateLog "User canceled the upgrade"
		exit 1
	fi
}
	
# PREFLIGHT
# ------------------------
preflight() {
	# Clear Dialog log to ensure proper function
	if [[ -f "$dialogCommandFile" ]]; then
		echo "Dialog command file found; setting to zero"
		: > "$dialogCommandFile"
	fi
	
	updateLog "Running pre-flight checks"
	
	# Check if a valid user is logged in; exit if no valid user is logged in
	check_logged_in_user
	
	# Check for Swift Dialog. All this useless without it!
	dialog_check
	
	# Check for Company Portal
	check_comp_portal
	
	# Check PSSO login type
		case "$(psso_login_type)" in
			"Secure Enclave")
				exit_success "PSSO login type is already Secure Enclave. Exiting..."
			;;
			"Password Sync")
				updateLog "PSSO login type is currently $(psso_login_type). Prompting user to migrate to Secure Enclave."
			;;
			*)
				updateLog "PSSO appears to not be active. Prompting to register Platform Single Sign-on Secure Enclave"
			;;
		esac
}

# MAIN FUNCTION
# Comment out "main" under RUN ALL FUNCTIONS to test individual functions.
# ------------------------------------------
main() {
	local no_preflight="$1"
	
	# Run preflight checks; if retrying, preflight will not run.
	if [[ "$no_preflight" != "1" ]]; then
	preflight
	fi
	
	# Display prompt to upgrade account
	run_psso_prompts
	
	# Wait for PSSO Secure Enclave registration to complete
	waiting_for_psso_se
}

# RUN ALL FUNCTIONS
# -----------------------------------
main "$@"



# TEST A FUNCTION
# -----------------------------------
