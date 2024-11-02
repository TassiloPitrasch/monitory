#!/bin/bash

# Writing to the log-file
log () {
    local message
    message="${1}"
    readonly message

    printf "%s - %s\n" "$(get_date)" "${message}" >> "${LOG_FILE}"
}

# Getting the current date in a specific format
get_date () {
    date +"%d.%m.%Y %H:%M:%S %Z"
}

# Removing generated files when terminating
clean_up () {
    rm -f "${OUT_FILE}"
}

# Checking the names that tried to login via ssh
# Globals: MONITORING_TEMP, SETTINGS_FILE
check_private_user_names () {
    local last_execution; local hacker_names_file
    declare -a private_names; declare -a targeted_private_names
    readonly hacker_names_file="${MONITORING_TEMP}/hacker_names.txt"

    # Timestamp of the previous execution
    last_execution="${1}"
    readonly last_execution

    # Parsing the names of interest that indicate targeted hacking
    mapfile -t private_names < <(jq -r ".private_names[]" "${SETTINGS_FILE}")
    readonly private_names

    log "Parsed ${#private_names[@]} private names to be checked..."

    # Getting the names that tried to authenticate to the server via ssh to a file
    # Successful attempts are ignored
    journalctl -u ssh --since "${last_execution}" --no-pager | grep -v "session opened" | grep -E -o "user [^ (]*" | cut -d " " -f2 | sort -u > "${hacker_names_file}"

    # Checking if one of the private names has been used
    for private_name in "${private_names[@]}"; do
        match="$(grep -i -E "\b${private_name}\b" "${hacker_names_file}")"
        if [[ -n "${match}" ]]; then
            targeted_private_names+=("${private_name}")
        fi
    done

    # Adding the corresponding section
    add_facts_section "Private usernames used for unsuccessful connection requests:" "${targeted_private_names[@]}"
}

# Checking the newly (un)blocked IP addresses (fail2ban)
# Globals: MONITORING_TEMP
check_fail2ban_jails () {
    local full; local latest_ip_blocklist; local current_ip_blocklist;
    declare -a new_ip_blocklist; declare -a unblocked_ips_list

    if [[ "${1}" == "numbers" ]]; then
        full=0
    elif [[ "${1}" == "full" ]]; then
        full=1
    else
        log "Specify valid display of fail2ban jails."
        return
    fi
    readonly full

    # The two files for the IPs blocked by fail2ban that are compared
    readonly latest_ip_blocklist="${MONITORING_TEMP}/latest_blocked_ips.txt"
    readonly current_ip_blocklist="${MONITORING_TEMP}/currently_blocked_ips.txt"

    log "Comparing blocklists..."

    # Archiving the previous fail2ban file
    [[ ! -s "${current_ip_blocklist}" ]] && touch "${current_ip_blocklist}"
    mv "${current_ip_blocklist}" "${latest_ip_blocklist}"

    # Parsing the currently blocked IPs to the current file
    fail2ban-client status sshd | grep "Banned IP list" | sed -E "s|.*Banned IP list:\t*(.*)|\1|" | tr " " "\n" | sort > "${current_ip_blocklist}"

    # Getting the newly blocked IPs
    mapfile -t new_ip_blocklist < <(comm -23 "${current_ip_blocklist}" "${latest_ip_blocklist}")
    # Checking if new IPs were blocked and adding a corresponding section if necessary
    if [[ "${full}" -eq 1 ]]; then
        add_facts_section "Newly blocked IPs:" "${new_ip_blocklist[@]}"
    elif [[ "${#new_ip_blocklist[0]}" ]]; then
        add_facts_section "Number of newly blocked IPs:" "${#new_ip_blocklist[@]}"
    fi

    # Getting the unblocked IPs
    mapfile -t unblocked_ips_list < <(comm -13 "${current_ip_blocklist}" "${latest_ip_blocklist}")
    # Checking if IPs were unblocked and adding a corresponding section if necessary
    if [[ "${full}" -eq 1 ]]; then
        add_facts_section "Unblocked IPs:" "${unblocked_ips_list[@]}"
    else
        add_facts_section "Number of newly unblocked IPs:" "${#unblocked_ips_list[@]}"
    fi
}

# Checking Docker services
# Globals: SETTINGS_FILE
check_docker_services () {
    local docker_services; local failing_docker_services

    # Getting the Docker services defined
    mapfile -t docker_services < <(jq -r ".services.docker[]" "${SETTINGS_FILE}")
    readonly docker_services
    log "Parsed ${#docker_services[@]} Docker services to be checked..."

    # Iterating the Docker services and checking if they are running
    declare -a failing_docker_services
    for docker_service in "${docker_services[@]}"; do
        if [[ $(docker inspect -f '{{.State.Running}}' "${docker_service}" 2> "/dev/null") != "true" ]]; then
            failing_docker_services+=("${docker_service}")
        fi
    done

    add_facts_section "Failing Docker services:" "${failing_docker_services[@]}"
}

# Adding a new fact section to the out-file
# Globals: OUT_FILE, PUSH_EMPTY, FACTS
add_facts_section () {
    local data; local section_name; local section_data

    # Name of the section; is inserted directly
    section_name="${1}"
    readonly section_name
    shift

    # The rest of the arguments are used for the section data
    readonly data=("${@}")
    if [[ "${data[*]}" == "" && "${PUSH_EMPTY}" != 1 ]]; then
        return
    elif [[ "${data[*]}" == "" ]]; then
        section_data="N/A"
    else
        for value in "${data[@]}"; do
             section_data="${section_data}${value}\n\n"
        done
    fi
    readonly section_data

    # Conditional formatting (leading comma)
    if [[ "${FACTS}" -eq 1 ]]; then
        printf ",\n" >> "${OUT_FILE}"
    else
       FACTS=1
    fi

    # Getting a new entry in the "facts" section by copying the template ("sections.json") and setting the section's name and value/data
    jq --null-input --exit-status --arg section_name "${section_name}" --arg section_data "${section_data}" --from-file "${SECTIONS_TEMPLATE}" >> "${OUT_FILE}"
}


# Home, temporary and template directories and files, log-file and file to track the date of the last execution
MONITORING_HOME="$(dirname "$(readlink -f "${0}")")"
SETTINGS_FILE="${MONITORING_HOME}/settings.json"
MONITORING_TEMP="${MONITORING_HOME}/temp"
MONITORING_TEMPLATES="${MONITORING_HOME}/templates"
SECTIONS_TEMPLATE="${MONITORING_TEMPLATES}/sections.json"
LOG_FILE="${MONITORING_HOME}/log.txt"
LAST_FILE="${MONITORING_TEMP}/last"

# File containing the final JSON data structure
OUT_FILE="${MONITORING_TEMP}/message.json"

# Holds if data has been written to the "facts" section
FACTS=0

# Log-file rotation
[[ "$(du -s "${LOG_FILE}" | cut -f1)" -gt 100000 ]] && printf "%s - Logfile rotated." "$(get_date)" > "${LOG_FILE}"
log "Process started."

# Teams message/notification initialization
# WebHook URL
webhook_url="$(jq -e -r ".webhook_url" "${SETTINGS_FILE}")"
if [[ "${webhook_url}" == "null" ]]; then
    log "Webhook URL not defined."
    exit 1
fi

# En/Disabling writing empty sections
PUSH_EMPTY="$(jq -e -r ".push_empty" "${SETTINGS_FILE}")"
if [[ "${PUSH_EMPTY,,}" == "true" ]]; then
    PUSH_EMPTY=1
else
    PUSH_EMPTY=0
fi

# Static data in the Teams notification
summary="$(jq -e -r ".summary" "${SETTINGS_FILE}")"
export summary="${summary}"
title="$(get_date) - $(jq -e -r ".title" "${SETTINGS_FILE}")"
export title="${title}"
color="$(jq -e -r ".color" "${SETTINGS_FILE}")"
export color="${color}"
text="$(jq -e -r ".text" "${SETTINGS_FILE}")"
export text="${text}"

# Writing the header
cat "${MONITORING_TEMPLATES}/head.json" | envsubst > "${OUT_FILE}"

# Parsing the time of the last execution
if [[ -s "${LAST_FILE}" ]]; then
    last_execution="$(cat "${LAST_FILE}")"
else
    last_execution="yesterday"
fi
log "Last execution: ${last_execution}"

# Executing the defined sub-modules
# s -> SSH: Checking the usernames that tried to log in via SSH
# f -> fail2ban: Getting (the number of) newly blocked and unblocked IP addresses
# d -> docker: Getting the status of the defined Docker services
while getopts "sf:d" opt; do
    case $opt in
        s) check_private_user_names "${last_execution}";;
        f) check_fail2ban_jails "${OPTARG}";;
        d) check_docker_services;;
        *) log "Unknown flag: \"${opt}\"";;
     esac
done

# Ending the execution if nothing to report has been identified
if [[ "${FACTS}" -eq 0 ]]; then
    clean_up
    printf "%s" "$(date +"%Y-%m-%d %H:%M:%S")" > "${LAST_FILE}"
    log "Nothing to report."
    exit 0
fi

# Writing the footer to the out-file
cat "${MONITORING_TEMPLATES}/foot.json" >> "${OUT_FILE}"

# Making new-lines JSON compatible
sed -i "s|\\\n|n|g" "${OUT_FILE}"

# Posting the JSON to Teams
if [[ "$(curl --request POST --no-progress-meter --header "Content-Type: application/json" --data "$(jq --null-input --arg "summary" "${summary}" --arg "title" "${title}" --arg "color" "${color}" --arg "text" "${text}" -f "${OUT_FILE}")" "${webhook_url}")" -ne 1 ]]; then
    log "Failed to push message to Teams."
else
    printf "%s" "$(date +"%Y-%m-%d %H:%M:%S")" > "${LAST_FILE}"
fi

clean_up
log "Process finished."
