#!/bin/bash

###########################
####### LOAD CONFIG #######
###########################

while [ $# -gt 0 ]; do
        case $1 in
                -c)
                        CONFIG_FILE_PATH="$2"
                        shift 2
                        ;;
                *)
                        ${ECHO} "Unknown Option \"$1\"" 1>&2
                        exit 2
                        ;;
        esac
done

if [ -z $CONFIG_FILE_PATH ] ; then
        SCRIPTPATH=$(cd ${0%/*} && pwd -P)
        CONFIG_FILE_PATH="${SCRIPTPATH}/my_backup.config"
fi

if [ ! -r ${CONFIG_FILE_PATH} ] ; then
        echo "Could not load config file from ${CONFIG_FILE_PATH}" 1>&2
        exit 1
fi

source "${CONFIG_FILE_PATH}"

###########################
#### PRE-BACKUP CHECKS ####
###########################

# Make sure we're running as the required backup user
if [ "$BACKUP_USER" != "" -a "$(id -un)" != "$BACKUP_USER" ] ; then
	echo "This script must be run as $BACKUP_USER. Exiting." 1>&2
	exit 1
fi


###########################
### INITIALISE DEFAULTS ###
###########################

if [ ! $HOSTNAME ]; then
	HOSTNAME="localhost"
fi;

if [ ! $USERNAME ]; then
	USERNAME="mysqladmin"
fi;


###########################
#### START THE BACKUPS ####
###########################

function perform_backups()
{
	SUFFIX=$1
	FINAL_BACKUP_DIR=$BACKUP_DIR"`date +\%Y-\%m-\%d`$SUFFIX/"

	echo "Making backup directory in $FINAL_BACKUP_DIR"

	if ! mkdir -p $FINAL_BACKUP_DIR; then
		echo "Cannot create backup directory in $FINAL_BACKUP_DIR. Go and fix it!" 1>&2
		exit 1;
	fi;


	###########################
	###### FULL BACKUPS #######
	###########################

	for SCHEMA_ONLY_DB in ${SCHEMA_ONLY_LIST//,/ }
	do
		EXCLUDE_SCHEMA_ONLY_CLAUSE="$EXCLUDE_SCHEMA_ONLY_CLAUSE and datname !~ '$SCHEMA_ONLY_DB'"
	done

	FULL_BACKUP_QUERY="show databases;"

	echo -e "\n\nPerforming full backups"
	echo -e "--------------------------------------------\n"

	for DATABASE in `mysql --defaults-file=./mysqldump.cnf -s -e "$FULL_BACKUP_QUERY"`
	do
		if [ $ENABLE_PLAIN_BACKUPS = "yes" ]
		then
			echo "Plain backup of $DATABASE"

			if ! mysqldump --defaults-file=./mysqldump.cnf "$DATABASE" | gzip > $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress; then
				echo "[!!ERROR!!] Failed to produce plain backup database $DATABASE" 1>&2
			else
				mv $FINAL_BACKUP_DIR"$DATABASE".sql.gz.in_progress $FINAL_BACKUP_DIR"$DATABASE".sql.gz
			fi
		fi

		if [ $ENABLE_CUSTOM_BACKUPS = "yes" ]
		then
			echo "Custom backup of $DATABASE"

			if ! mysqldump --defaults-file=./mysqldump.cnf "$DATABASE" -f $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress; then
				echo "[!!ERROR!!] Failed to produce custom backup database $DATABASE"
			else
				mv $FINAL_BACKUP_DIR"$DATABASE".custom.in_progress $FINAL_BACKUP_DIR"$DATABASE".custom
			fi
		fi

	done

	echo -e "\nAll database backups complete!"

	echo "Copy to $SCP_HOST"

	scp -i /root/.ssh/id_rsa -r -P "$SCP_PORT" $FINAL_BACKUP_DIR "$SCP_HOST":$FINAL_BACKUP_DIR


}

# MONTHLY BACKUPS

DAY_OF_MONTH=`date +%d`

if [ $DAY_OF_MONTH -eq 1 ];
then
	# Delete all expired monthly directories
	find $BACKUP_DIR -maxdepth 1 -name "*-monthly" -exec rm -rf '{}' ';'

	perform_backups "-monthly"

	exit 0;
fi

# WEEKLY BACKUPS

DAY_OF_WEEK=`date +%u` #1-7 (Monday-Sunday)
EXPIRED_DAYS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`

if [ $DAY_OF_WEEK = $DAY_OF_WEEK_TO_KEEP ];
then
	# Delete all expired weekly directories
	find $BACKUP_DIR -maxdepth 1 -mtime +$EXPIRED_DAYS -name "*-weekly" -exec rm -rf '{}' ';'

	perform_backups "-weekly"

	exit 0;
fi

# DAILY BACKUPS

# Delete daily backups 7 days old or more
find $BACKUP_DIR -maxdepth 1 -mtime +$DAYS_TO_KEEP -name "*-daily" -exec rm -
rf '{}' ';'

perform_backups "-daily"
