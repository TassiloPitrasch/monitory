# Basics
This is just a small script to process **fail2ban/systemd** logs and report the findings to a Teams Channel via a Webhook.

# Prerequisites 
Easy:

 - Bash 4.x (as an associative array is used) ➡️ test with `echo $BASH_VERSION`
 - [jq](https://github.com/jqlang/jq) >= 1.6 ➡️ test with `jq --version` 
 - systemd/ssh logs available via journalctl ➡️ test with `journalctl -u ssh`
 - fail2ban-client for the sshd jail ➡️ test with `fail2ban-client status sshd`
 - A Teams Channel to push to via a [Webhook](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook?tabs=newteams%2Cdotnet#create-an-incoming-webhook)

# Content

 - **monitoring[.]sh**: The main script that is executed
 - **settings.json**: Settings-file, see below for more information
 - **log.txt**: File for small diagnostic messages
 - **temp/**: Directory containing temporary files
 - **templates/**: Directory containing JSON templates that are merged to the message payload

# Settings
The settings-file should look like this:

    {
        "webhook_url": "URL to your Teams Channel",
        "private_names": [
          "Array of usernames", "that should be monitored"]
    }

# Execution
`./monitoring.sh` - that's it.

# Output
The script checks for three things:

 1. IPs newly blocked by fail2ban.
 2. IPs unblocked by fail2ban.
 3. Unsuccessful authentication attempts with the usernames defined in the settings-file.

The metrics are collected since the last time the script was executed.
During the first execution, the option `--since yesterday` is used for `journalctl` when grabbing the data for the third metric.
Note that no notification is send if no events were parsed.

