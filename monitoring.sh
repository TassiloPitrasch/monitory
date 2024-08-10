#!/bin/bash
set -u

# Getting the current date in a specific format
get_date () {
    date +"%d.%m.%Y %H:%M:%S %Z"
}

# Adding a new fact section to the out-file with a placeholder for the actual data that is stored in FACTS
# Globals: OUT_FILE, FACTS
add_facts_section () {
    # Parameters
    local section_name; local values_placeholder; local values_file
    # Name of the section; is inserted directly
    section_name="${1}"
    # Placeholder for the content of that file in the final out-file
    values_placeholder="${2}"
    # File that contains the actual values that are added to FACTS
    values_file="${3}"
    readonly section_name values_placeholder values_file

    # Conditional formatting (leading comma)
    [[ -n "${FACTS[@]}" ]] && printf ",\n" >> "${OUT_FILE}"
    # Getting a new entry in the "facts" section by copying the template ("sections.json"),
    # setting the section's name (directly) and
    # setting the variable placeholder (which is later replaced by JQ with the data from the FACTS via the data-file)
    sed -e "s|%section_name%|${section_name}|" -e "s|%section_value%|\$data.${values_placeholder}|" "${SECTIONS_TEMPLATE}" >> "${OUT_FILE}"
    # Reading the provided file to the respective entry in FACTS, replacing new-lines with "\\n"
    FACTS["${values_placeholder}"]="$(tr "\n" ";" < "${values_file}" | sed "s|;|\\\\n|g")"
}


# Home, temporary and template directories and files and log-file
MONITORING_HOME="$(dirname "$(readlink -f "${0}")")"
SETTINGS_FILE="${MONITORING_HOME}/settings.json"
MONITORING_TEMP="${MONITORING_HOME}/temp"
MONITORING_TEMPLATES="${MONITORING_HOME}/templates"
SECTIONS_TEMPLATE="${MONITORING_TEMPLATES}/sections.json"
LOG_FILE="${MONITORING_HOME}/log.txt"

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
# File containing the variable data, is read by JQ
DATA_FILE="${MONITORING_TEMP}/data.json"
# File containing the final JSON data structure with the relevant placeholders,
# as the number of sections is variable
OUT_FILE="${MONITORING_TEMP}/message.json"
# Writing the header
cat "${MONITORING_TEMPLATES}/head.json" > "${OUT_FILE}"
# Static data
summary="Kore Daily Monitoring Summary"
color="1a1aff"
text="This is the monitoring summary for Kore, containing events from the last 24 hours."
# Array holding data for the individual facts in the "facts" sections
# Key is the respective placeholder in the FINAL data-file
declare -A FACTS

# sshd: WoBeeCon-specific (private) usernames the "hackers" used
readonly hacker_name_file="${MONITORING_TEMP}/hacker_names.txt"
readonly matching_names_file="${MONITORING_TEMP}/matched_names.txt"
true > "${matching_names_file}"
# Getting the names that tried to authenticate to the server via ssh
# Successful attempts are ignored
journalctl -u ssh --since yesterday --no-pager | grep -v "session opened" | grep -E -o "user [^ (]*" | cut -d " " -f2 | sort -u > "${hacker_name_file}"
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
    add_facts_section "Private usernames used for unsuccessful connection requests:" "hackers" "${matching_names_file}"
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
    add_facts_section "Newly blocked IPs:" "new_blocked" "${new_ip_blocklist}"
fi
comm -13 "${current_ip_blocklist}" "${latest_ip_blocklist}" > "${unblocked_ips_list}"
# Checking if IPs were unblocked and adding a corresponding section if necessary
if [[ -s "${unblocked_ips_list}" ]]; then
    add_facts_section "Unblocked IPs:" "unblocked" "${unblocked_ips_list}"
fi

# Ending the execution if nothing to report has been identified
if [[ -z "${FACTS[*]}" ]]; then
    rm -f "${OUT_FILE}" "${DATA_FILE}"
    printf "%s - Nothing to report.\n" "$(get_date)" >> "${LOG_FILE}"
    exit 0
fi

# Writing the footer to the out-file
cat "${MONITORING_TEMPLATES}/foot.json" >> "${OUT_FILE}"

# Preparing a data file mapping the entries in FACTS and their placeholders in the out-file
printf "{" > "${DATA_FILE}"
for fact in "${!FACTS[@]}"; do
    printf '"%s": "%s",\n' "${fact}" "${FACTS[$fact]}" >> "${DATA_FILE}"
done
# Adding the title here as well (as it contains a variable - the date)
printf '"%s": "%s"\n' "title" "$(date +"%d.%m.%Y %H:%M:%S %Z") - Kore Monitoring Summary" >> "${DATA_FILE}"
printf "}" >> "${DATA_FILE}"

# Cleansing the data-file
# Removing new-lines at the end of entries
sed -i "s|\\\n\"|\"|g" "${DATA_FILE}"
# Escaping new-lines for JSON
sed -i "s|\\\n|\\\n\\\n|g" "${DATA_FILE}"

# Posting the JSON to Teams
if [[ "$(curl -X POST -H "Content-Type: application/json" -d "$(jq -n --arg "summary" "${summary}" --arg "color" "${color}" --arg "text" "${text}" --argfile "data" "${DATA_FILE}" -f "${OUT_FILE}")" "${webhook_url}")" -ne 1 ]]; then
    printf "%s - Failed to push message to Teams.\n" "$(get_date)" >> "${LOG_FILE}"
else
    printf "%s - Process finished.\n" "$(get_date)" >> "${LOG_FILE}"
fi
