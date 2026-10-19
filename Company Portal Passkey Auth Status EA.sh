#!/bin/zsh --no-rcs

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

:<<EXTENSION_ATTRIBUTE
----------------------------------------
TITLE: Company Portal Passkey Authorization Status
VERSION: 1.5
PURPOSE: Reports status of Company Portal authorization to auto-fill passkeys. Status is only reported if the Mac is registered
with Platform Single Sign-on using Secure Enclave login type.

Created with help from Scott Kendall
https://github.com/ScottEKendall/Microsoft-Platform-SSO/blob/main/scripts/Enforce%20Portal%20AutoFill.sh

10/15/2026 | Howie Canterbury
----------------------------------------
EXTENSION_ATTRIBUTE

# USER VARIABLES
currentUser=$(/usr/bin/stat -f "%Su" /dev/console)
currentUser_id=$(/usr/bin/id -u "$currentUser" 2>/dev/null)

# RUN AS USER FUNCTION
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

# CHECK PASSKEY AUTOFILL AUTH STATUS
# Run as user
# ----------------------------------
passkey_auth_status() {
	cp_ssoext=$(runAsUser pluginkit -m | grep "com.microsoft.CompanyPortalMac.Mac-Autofill-Extension" | awk '{print $1}')
	cp_autofill=$(runAsUser pluginkit -m | grep "com.microsoft.CompanyPortalMac.ssoextension" | awk '{print $1}')
	
	if [[ "$cp_ssoext" == "+" ]] && [[ "$cp_autofill" == "+" ]]; then
		echo "1"
	else
		echo "0"
	fi
}

# MAIN FUNCTION
# ----------------------------------
main () {
	# Check PSSO login type. Exit if not Secure Enclave
	if [[ "$(psso_login_type)" != "Secure Enclave" ]]; then
		exit 0
	fi
	
	# Report passkey auth status
	passkey_auth_status > /dev/null
		case "$(passkey_auth_status)" in
			1)
				echo "<result>Yes</result>"
			;;
			0)
				echo "<result>No</result>"
			;;
			*)
				echo "<result>No</result>"
			;;
		esac
}

# RUN
# ----------------------------------
main "$@"