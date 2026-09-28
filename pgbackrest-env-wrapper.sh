#!/bin/sh
# wrapper.sh renders these template settings into command-specific config.
# Passing them to pgBackRest produces unknown-option warnings on stdout,
# corrupting info --output=json even when the command succeeds.
unset PGBACKREST_BACKUP_PROCESS_MAX
unset PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX
unset PGBACKREST_ARCHIVE_GET_PROCESS_MAX
unset PGBACKREST_RESTORE_PROCESS_MAX

# Keep native options, argument boundaries, exit status, and signal delivery.
exec /usr/bin/pgbackrest "$@"
