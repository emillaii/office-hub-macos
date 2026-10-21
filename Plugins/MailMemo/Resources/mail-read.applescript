set cutoffDate to (current date) - {{AGE}}
set targets to {{{TARGETS}}}
set messageRows to {}
set accountRows to {}
set foundAddresses to {}
set refreshNote to ""
set stage to "Access Mail"
try
    tell application "Mail"
        set stage to "Refresh Mail"
        try
            check for new mail
            delay 2
        on error errorText number errorNumber
            set refreshNote to "Mail refresh returned error " & errorNumber & "; showing downloaded mail."
        end try
        set stage to "List Mail accounts"
        set accountList to get accounts
        repeat with acct in accountList
            set matchedAddress to ""
            try
                set stage to "Read account identity"
                set accountEmails to get email addresses of acct
                set accountName to get name of acct
                repeat with addr in targets
                    if accountEmails contains (contents of addr) or accountName is (contents of addr) then
                        set matchedAddress to contents of addr
                        exit repeat
                    end if
                end repeat
                if matchedAddress is not "" then
                    set end of foundAddresses to matchedAddress
                    set stage to "Find inbox for " & matchedAddress
                    if enabled of acct is false then error "This account is disabled."
                    set boxes to (get mailboxes of acct whose name is "INBOX")
                    if (count of boxes) is 0 then set boxes to (get mailboxes of acct whose name is "Inbox")
                    if (count of boxes) is 0 then set boxes to (get mailboxes of acct whose name is "收件箱")
                    if (count of boxes) is 0 then error "The account inbox could not be identified."
                    set selectedBox to item 1 of boxes
                    set stage to "Read new messages for " & matchedAddress
                    set newMessages to (get messages of selectedBox whose date received is greater than cutoffDate)
                    if (count of newMessages) is greater than 150 then error "More than 150 messages need review; this check was not marked complete."
                    repeat with msg in newMessages
                        set bodyText to content of msg as text
                        if (length of bodyText) is greater than 1800 then set bodyText to text 1 thru 1800 of bodyText
                        set stableID to message id of msg
                        if stableID is "" then set stableID to "mail-local-" & (id of msg as text)
                        set end of messageRows to {matchedAddress, sender of msg, subject of msg, (current date) - (date received of msg), stableID, bodyText}
                    end repeat
                    set end of accountRows to {matchedAddress, "checked", "Read currently downloaded inbox messages without changing message flags."}
                end if
            on error errorText number errorNumber
                if matchedAddress is not "" then set end of accountRows to {matchedAddress, "blocked", stage & ": " & errorText & " (" & errorNumber & ")"}
            end try
        end repeat
        repeat with addr in targets
            if foundAddresses does not contain (contents of addr) then set end of accountRows to {contents of addr, "blocked", "Account not found in Apple Mail."}
        end repeat
        set stage to "Check Mail sync activity"
        try
            set syncCount to get background activity count
        on error
            set syncCount to 0
            set refreshNote to refreshNote & " Mail does not expose sync activity on this system; this is a downloaded-inbox snapshot."
        end try
    end tell
    return {messageRows, accountRows, syncCount, refreshNote}
on error errorText number errorNumber
    repeat with addr in targets
        set end of accountRows to {contents of addr, "blocked", stage & ": " & errorText & " (" & errorNumber & ")"}
    end repeat
    return {messageRows, accountRows, -1, stage & ": " & errorText & " (" & errorNumber & ")"}
end try
