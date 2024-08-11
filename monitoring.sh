#!/bin/bash
set -u

# Getting the current date in a specific format
get_date () {
    date +"%d.%m.%Y %H:%M:%S %Z"
}

# Removing generated files when terminating
clean_up () {
    rm -f "${OUT_FILE}"
}

# Helper to format section data
parse_section_data () {
    # Parameters
    # File that contains the data to be parsed
    values_file="${1}"

    # Returning new-lines as "\n"
    while IFS= read -r line; do
        echo "${line}"
    done < "${values_file}"
}

# Adding a new fact section to the out-file
# Globals: OUT_FILE, FACTS
add_facts_section () {
    # Parameters
    local section_name; local values_file
    # Name of the section; is inserted directly
    section_name="${1}"
    # File that contains the actual values
    values_file="${2}"
    readonly section_name

    # Conditional formatting (leading comma)
    if [[ "${FACTS}" -eq 1 ]]; then
        printf ",\n" >> "${OUT_FILE}"
    else
       FACTS=1
    fi

    # Getting a new entry in the "facts" section by copying the template ("sections.json") and setting the section's name and value/data
    jq --null-input --exit-status --arg section_name "${section_name}" --arg section_data "$(parse_section_data "${values_file}")" --from-file "${SECTIONS_TEMPLATE}" >> "${OUT_FILE}"
}


# Home, temporary and template directories and files, log-file and file to track the date of the last execution
MONITORING_HOME="$(dirname "$(readlink -f "${0}")")"
SETTINGS_FILE="${MONITORING_HOME}/settings.json"
MONITORING_TEMP="${MONITORING_HOME}/temp"
MONITORING_TEMPLATES="${MONITORING_HOME}/templates"
SECTIONS_TEMPLATE="${MONITORING_TEMPLATES}/sections.json"
LOG_FILE="${MONITORING_HOME}/log.txt"
LAST_FILE="${MONITORING_TEMP}/last"
# Holds if data has been written to the "facts" section
FACTS=0

# Log-file rotation
[[ "$(du -s "${LOG_FILE}" | cut -f1)" -gt 100000 ]] && printf "%s - Lofile rotated.\n" "$(get_date)" > "${LOG_FILE}"
printf "%s - Process started.\n" "$(get_date)" >> "${LOG_FILE}"

# Teams message/notification initialization
# WebHook URL
webhook_url="$(jq -e -r ".webhook_url" "${SETTINGS_FILE}")"
if [[ "${webhook_url}" == "null" ]]; then
    printf "%s - Webhook URL not defined.\n" "$(get_date)" >> "${LOG_FILE}"
    exit 1
fi
# Static data in the Teams notification
summary="$(jq -e -r ".summary" "${SETTINGS_FILE}")"
title="$(get_date) - $(jq -e -r ".title" "${SETTINGS_FILE}")"
color="$(jq -e -r ".color" "${SETTINGS_FILE}")"
text="$(jq -e -r ".text" "${SETTINGS_FILE}")"
readonly summary title color text

# File containing the final JSON data structure
OUT_FILE="${MONITORING_TEMP}/message.json"
# Writing the header
cat "${MONITORING_TEMPLATES}/head.json" > "${OUT_FILE}"

# sshd: WoBeeCon-specific (private) usernames the "hackers" used
readonly hacker_name_file="${MONITORING_TEMP}/hacker_names.txt"
readonly matching_names_file="${MONITORING_TEMP}/matched_names.txt"
true > "${matching_names_file}"
# Parsing the time of the last execution
if [[ -s "${LAST_FILE}" ]]; then
    last_execution="$(cat "${LAST_FILE}")"
else
    last_execution="yesterday"
fi
# Getting the names that tried to authenticate to the server via ssh
# Successful attempts are ignored
journalctl -u ssh --since "${last_execution}" --no-pager | grep -v "session opened" | grep -E -o "user [^ (]*" | cut -d " " -f2 | sort -u > "${hacker_name_file}"
# Parsing the names of interest that indicate targeted hacking
mapfile -t private_names < <(jq -r ".private_names[]" "${SETTINGS_FILE}")
readonly private_names
# Checking if one of the private names has been used
for private_name in "${private_names[@]}"; do
    match="$(grep -i -E "\b${private_name}\b" "${hacker_name_file}")"
    if [[ -n "${match}" ]]; then
        printf "%s\n" "${match}" >> "${matching_names_file}"
    fi
done

# Checking if matches were found and adding a corresponding section if necessary
if [[ -s "${matching_names_file}" ]]; then
    add_facts_section "Private usernames used for unsuccessful connection requests:" "${matching_names_file}"
fi

# fail2ban: newly blocked IPs
# The two files for the IPs blocked by fail2ban that are compared
readonly latest_ip_blocklist="${MONITORING_TEMP}/latest_blocked_ips.txt"
readonly current_ip_blocklist="${MONITORING_TEMP}/currently_blocked_ips.txt"
# The output files containing the newly blocked and unblocked IPs
readonly new_ip_blocklist="${MONITORING_TEMP}/newly_blocked_ips.txt"
readonly unblocked_ips_list="${MONITORING_TEMP}/unblocked_ips.txt"
# Archiving the previous fail2ban file
[[ ! -s "${current_ip_blocklist}" ]] && touch "${current_ip_blocklist}"
mv "${current_ip_blocklist}" "${latest_ip_blocklist}"
# Parsing the currently bloked IPs to the current file
fail2ban-client status sshd | grep "Banned IP list" | sed -E "s|.*Banned IP list:\t*(.*)|\1|" | tr " " "\n" | sort > "${current_ip_blocklist}"
# Getting the newly blocked IPs
comm -23 "${current_ip_blocklist}" "${latest_ip_blocklist}" > "${new_ip_blocklist}"
# Checking if new IPs were blocked and adding a corresponding section if necessary
if [[ -s "${new_ip_blocklist}" ]]; then
    add_facts_section "Newly blocked IPs:" "${new_ip_blocklist}"
fi
comm -13 "${current_ip_blocklist}" "${latest_ip_blocklist}" > "${unblocked_ips_list}"
# Checking if IPs were unblocked and adding a corresponding section if necessary
if [[ -s "${unblocked_ips_list}" ]]; then
    add_facts_section "Unblocked IPs:" "${unblocked_ips_list}"
fi

# Ending the execution if nothing to report has been identified
if [[ "${FACTS}" -eq 0 ]]; then
    clean_up
    printf "%s" "$(date +"%Y-%m-%d %H:%M:%S")" > "${LAST_FILE}"
    printf "%s - Nothing to report.\n" "$(get_date)" >> "${LOG_FILE}"
    exit 0
fi

# Writing the footer to the out-file
cat "${MONITORING_TEMPLATES}/foot.json" >> "${OUT_FILE}"

# Making new-lines JSON compatible
sed -i "s|\\\n|\\\n\\\n|g" "${OUT_FILE}"

# Posting the JSON to Teams
if [[ "$(curl --request POST --no-progress-meter --header "Content-Type: application/json" --data "$(jq --null-input --arg "summary" "${summary}" --arg "title" "${title}" --arg "color" "${color}" --arg "text" "${text}" -f "${OUT_FILE}")" "${webhook_url}")" -ne 1 ]]; then
    printf "%s - Failed to push message to Teams.\n" "$(get_date)" >> "${LOG_FILE}"
else
    printf "%s" "$(date +"%Y-%m-%d %H:%M:%S")" > "${LAST_FILE}"
fi

clean_up
printf "%s - Process finished.\n" "$(get_date)" >> "${LOG_FILE}"
