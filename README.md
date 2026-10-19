# Platform Single Sign-on Migrate to Secure Enclave

Prompt users to upgrade their Platform Single Sign-on registration from password sync login type to Secure Enclave. All Swift Dialog functions in this script use the "nogradient" option. Swift Dialog version 3.1 is required for this.

To make this script work in your environment:
- Add your own Jamf Pro server URL - line 60
- Add a Jamf Pro API client ID - line 61
- Add Jamf Pro API client secret - line 62
- Change the colors used. Look for colors under heading "INTERFACE COLORS" - line 45
- Find and replace "PretendCo" with your organization's name
- You may want to edit the help message in the initial prompt - line 483
- This script checks for the PSSO Secure Enclave profile install success using the profile's ID. Add your profile ID - line 297
- This script checks for a profile that grants Jamf permission to run automation tasks in macOS which is needed for the "quit_app" function. Add your profile ID - line 156
- Modify "dialog_check" function. Add your Jamf Pro policy custom trigger for installing Swift Dialog.

READ THE SCRIPT TO FIND OTHER AREAS THAT YOU MAY NEED TO CHANGE. I MAY NOT HAVE MENTIONED ALL OF THEM HERE.

This script uses Swift Dialog to prompt users to change their PSSO registration from using password sync to Secure Enclave. As the user is following the process, a function monitors the process until successful registration.
To swap the PSSO configuration profiles, the Jamf Pro API is used to add the computer to a static group scoped to receive the PSSO Secure Enclave profile. This static group should be setup to be excluded from the PSSO password sync profile. This triggers the immediate uninstall of the password sync profile and installs the Secure Enclave profile.

If there is no PSSO registration, the script will handle getting the user to register PSSO with Secure Enclave.

For the "passkey_auth" function, add the custom trigger for a policy to enable Company Portal to autofill passkeys. Users are likely to ignore the prompt to do this. Scott Kendall has written a script that automates enabling passkey autofill.

https://github.com/ScottEKendall/Microsoft-Platform-SSO/blob/main/scripts/Enforce%20Portal%20AutoFill.sh

Timeouts are setup to exit if the new configuration profile is not installed within 60 seconds or if the registration process is not completed within 180 seconds. An alert is shown to the user if either of these timeouts occur. They can choose to retry or cancel.

![Prompt to upgrade PSSO](https://raw.github.com/howieisaacks/Images/main/PSSO-Upgrade-Prompt.png)



# Platform Single Sign-on Status Extension Attribute

Checks if a user has registered Platform Single Sign-on

- Reports the logged in username
- Reports login type (password sync or Secure Enclave)
- Reports token status (Good or Bad)

A "Bad" token status is reported if tokens are either not present or have expired.

![PSSO Status](https://raw.githubusercontent.com/howieisaacks/Images/main/PSSO-Status.png)
