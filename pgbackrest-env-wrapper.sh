#!/bin/sh
# wrapper.sh renders these template settings into command-specific config.
# Passing them to pgBackRest produces unknown-option warnings on stdout,
# corrupting info --output=json even when the command succeeds.
unset PGBACKREST_BACKUP_PROCESS_MAX
unset PGBACKREST_ARCHIVE_PUSH_PROCESS_MAX
unset PGBACKREST_ARCHIVE_GET_PROCESS_MAX
unset PGBACKREST_RESTORE_PROCESS_MAX

# Image-managed encryption lives in the selected config file: repo1 in the
# archive config and repo1 in the separate recovery config may use different
# keys. A process-wide native override must not replace either role's key.
# Preserve native-only configuration for existing operators who have not
# opted into the image's encryption settings.
if [ "${WAL_ARCHIVE_CIPHER_TYPE+x}${WAL_RECOVER_FROM_CIPHER_TYPE+x}" != "" ]; then
  unset PGBACKREST_REPO1_CIPHER_TYPE PGBACKREST_REPO1_CIPHER_PASS
fi

# Keep native options, argument boundaries, exit status, and signal delivery.
exec /usr/bin/pgbackrest "$@"
