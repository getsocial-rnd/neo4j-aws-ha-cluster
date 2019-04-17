#!/bin/bash -eu




# create fixed server IDs for nodes.
# we can't let ids be random or inappropriate, main reason is
# not letting slave-only node to be picked up for push synchronization
# in case there's only one active slave.
# So in case we have a 3 node cluster, layout is:
#
#
#  [Master] <===== pull changes ==== [Slave-only]
#     ||
# push changes
#     ||
#     \/
#  [Slave]
#
make_server_id() {
    local octets=${INSTANCE_IP#*.*.*}
    local oct3=${octets%%.*}
    local oct4=${octets#*.*}
    SERVER_ID=$((((oct3 << 8)) + oct4))

    # If its a read-only slave node, don't let it be picked by tx_push_factor.
    # Since the order is ascending, this node will always have higher ID than any node
    # in main cluster.
    if [ "${NEO4J_ha_slave__only:-}" == "true" ] ; then
        SERVER_ID=$((SERVER_ID + 65536))
    fi
    echo "Server ID generated: $SERVER_ID"
}

# get all instances running in this CF stack
get_cluster_node_ips() {
    local ips=$(aws ec2 describe-instances \
                --filters Name=tag-key,Values=App Name=tag-value,Values=Neo4j \
                          Name=tag-key,Values=aws:cloudformation:stack-id Name=tag-value,Values=$STACK_ID \
                          Name=tag-key,Values=aws:cloudformation:stack-name Name=tag-value,Values=$STACK_NAME \
                --query Reservations[].Instances[].InstanceId \
                --output text \
                --region $AWS_REGION \
    )

    local count=0

# An error occurred (InvalidInstanceID.Malformed) when calling the DescribeInstances operation: Invalid id: "10.10.1.202"
# /ecs-extension.sh: line 57: parts[0]: unbound variable

    for ID in $ips;
    do
        local result=$(aws ec2 describe-instances --instance-ids $ID  \
            --query 'Reservations[].Instances[].[PrivateIpAddress,Tags[?Key==`SlaveOnly`][Value]]' \
            --output text \
            --region $AWS_REGION \
        )

        local parts=($result)
        local IP="${parts[0]}"
        local slave_only="${parts[1]}"

        if [ "$IP" == "" ] ; then
            continue
        fi

        # slave will join himself, main cluster should not wait for slave-only node
        # to startup.
        if [ "$slave_only" == "true" ] ; then
            if [ "$ID" == "$INSTANCE_ID" ] ; then
                echo "I'm slave-only, i'll try to join main cluster"
            else
                echo "Slave-only instance $IP is excluded from initial hosts, it'll have to request invitation"
                continue
            fi
        fi

        if [ "${CLUSTER_IPS}" != "" ] ; then
           CLUSTER_IPS=$CLUSTER_IPS,
        fi
        CLUSTER_IPS=$CLUSTER_IPS$IP:$COORDINATION_PORT
    done

    echo "Instances in stack: $count"
    if [ "$count" -eq 2 ] && [ "${SLAVE_MODE}" == "SINGLE" ]; then
        CLUSTER_IPS=$INSTANCE_IP:$COORDINATION_PORT
        return
    fi
    echo "Fetched Neo4j cluster nodes: $CLUSTER_IPS"
}

restore_neo4j() {
    BACKUP_DIR=/tmp
    BACKUP_PATH="$BACKUP_DIR/_snapshot.zip"
    S3_PATH="s3://$SNAPSHOT_PATH"

    echo "Restore initiated. Source: $S3_PATH"

    aws s3 cp $S3_PATH $BACKUP_PATH
    local status=$?
    if [ "$status" -ne 0 ] ; then
        echo "Error: failed to copy snapshot $SNAPSHOT_PATH from S3"
        exit 1
    fi

    echo "Successfully copied snapshot $SNAPSHOT_PATH from S3!"
    unzip $BACKUP_PATH -d $BACKUP_DIR

    echo "Running restore..."

    su-exec ${userid} bin/neo4j-admin restore --from="$BACKUP_DIR/$BACKUP_NAME" --database=graph.db --force
    status=$?
    if [ "$status" -ne 0 ] ; then
        echo "Error: failed to restore from snapshot."
        exit 1
    fi
}

# copy of the piece of code from the original docker-entrypoint.sh
# https://github.com/neo4j/docker-neo4j-publish/blob/5a80e2a88fb92e4b10b12d79b28a8070ab2d13fb/3.5.4/enterprise/docker-entrypoint.sh#L188-L206
# needed to be able to save configurations after we modified it in the our extension script
save_config() {
    # list env variables with prefix NEO4J_ and create settings from them
    unset NEO4J_AUTH NEO4J_SHA256 NEO4J_TARBALL
    for i in $( set | grep ^NEO4J_ | awk -F'=' '{print $1}' | sort -rn ); do
        setting=$(echo ${i} | sed 's|^NEO4J_||' | sed 's|_|.|g' | sed 's|\.\.|_|g')
        value=$(echo ${!i})
        # Don't allow settings with no value or settings that start with a number (neo4j converts settings to env variables and you cannot have an env variable that starts with a number)
        if [[ -n ${value} ]]; then
            if [[ ! "${setting}" =~ ^[0-9]+.*$ ]]; then
                if grep -q -F "${setting}=" "${NEO4J_HOME}"/conf/neo4j.conf; then
                    # Remove any lines containing the setting already
                    sed --in-place "/^${setting}=.*/d" "${NEO4J_HOME}"/conf/neo4j.conf
                fi
                # Then always append setting to file
                echo "${setting}=${value}" >> "${NEO4J_HOME}"/conf/neo4j.conf
            else
                echo >&2 "WARNING: ${setting} not written to conf file because settings that start with a number are not permitted"
            fi
        fi
    done
}


# copy of the part of the docker-entrypoint.sh script
# which does the initial user configuratio with custom edits
# copy is needed, because running the "neo4j-admin set-initial-password"
# will create $NEO4J_HOME/data direcotry, with the root permissions and BEFORE
# we mounted into our external EBS volume
setup_users() {
    # set the neo4j initial password only if you run the database server
    if [ "${NEO4J_ADMIN_PASSWORD:-}" == "none" ]; then
        NEO4J_dbms_security_auth__enabled=false
    elif [ -z "${NEO4J_ADMIN_PASSWORD:-}" ]; then
        echo >&2 "Missing NEO4J_ADMIN_PASSWORD. If you don't want to configure authentification please set the NEO4J_ADMIN_PASSWORD=none"
        exit 1
    else
        password="${NEO4J_ADMIN_PASSWORD}"
        if [ "${password}" == "neo4j" ]; then
            echo >&2 "Invalid value for password. It cannot be 'neo4j', which is the default."
            exit 1
        fi
        # Will exit with error if users already exist (and print a message explaining that)
        su-exec ${userid} bin/neo4j-admin set-initial-password "${password}" || true

        ## Start of custom code block
        user=neo4j # admin user is always "neo4j"
        guest_user=$(echo ${NEO4J_GUEST_AUTH:-} | cut -d'/' -f1)
        guest_password=$(echo ${NEO4J_GUEST_AUTH:-} | cut -d'/' -f2)

        # as soon as we get credentials, we can start waiting for BOLT protocol to warm it up
        # upon startup.
        echo "Scheduling init tasks..."
        NEO4J_USERNAME="${user}" NEO4J_PASSWORD="${password}" GUEST_USERNAME="${guest_user}" GUEST_PASSWORD="${guest_password}" bash /init_db.sh &
        echo "Scheduling init tasks: Done."
        ## Start of custom code block
    fi

    unset NEO4J_ADMIN_PASSWORD
}

configure() {
    # unset the variable NEO4J_dbms_directories_logs, which is set by parent docker-entrypoint.sh and pointing to /logs
    NEO4J_dbms_directories_logs=$NEO4J_HOME/logs

    # setting custom variables
    # high availability cluster settings.
    NEO4J_dbms_mode=${NEO4J_dbms_mode:-HA}

    NEO4J_ha_server__id=${NEO4J_ha_serverId:-$SERVER_ID}
    NEO4J_ha_initial__hosts=${NEO4J_ha_initialHosts:-$CLUSTER_IPS}
    NEO4J_ha_pull__interval=${NEO4J_ha_pull__interval:-5s}
    NEO4J_ha_tx__push__factor=${NEO4J_ha_tx__push__factor:-1}
    NEO4J_ha_join__timeout=${NEO4J_ha_join__timeout:-2m}
    NEO4J_dbms_backup_address=${NEO4J_dbms_backup_address:-0.0.0.0:6362}
    NEO4J_dbms_allow__upgrade=${NEO4J_dbms_allow__upgrade:-false}
    NEO4J_apoc_export_file_enabled=true

    # not configurable for now.
    NEO4J_ha_tx__push__strategy=fixed_ascending
    NEO4J_dbms_security_procedures_unrestricted=apoc.*

    # this allows master/slave health/status endpoints to be open for ELB
    # without basic auth.
    NEO4J_dbms_security_ha__status__auth__enabled=false
}

# get more info from AWS environment:
# - instance im running on
# - my IP
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id/)
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4/)

# these will be populated by cluster surrounding later in the code.
CLUSTER_IPS=""
SERVER_ID=""
COORDINATION_PORT=5001
BOLT_PORT=7687

BACKUP_NAME=neo4j-backup

# Create all needed folders, etc
mkdir -p $NEO4J_DATA_ROOT

# make sure subdirs exist
mkdir -p $NEO4J_DATA_ROOT/data
mkdir -p $NEO4J_DATA_ROOT/logs
mkdir -p $NEO4J_DATA_ROOT/metrics

chown -R neo4j:neo4j $NEO4J_DATA_ROOT

ln -s $NEO4J_DATA_ROOT/data $NEO4J_HOME/data
ln -s $NEO4J_DATA_ROOT/logs $NEO4J_HOME/logs
ln -s $NEO4J_DATA_ROOT/metrics $NEO4J_HOME/metrics


# starting neo4j on "start" parameter
# we need custom parameter, different from the default one "neo4j"
# to avoid default initial user creation (see comments to the "setup_users" function)
if [ "${cmd}" == "start" ]; then
    # create server ID, unique to this instance, based on it's private IP's last 2 octets.
    make_server_id

    # get all IPs of this autoscaling group to build ha.initial_hosts of the cluster.
    get_cluster_node_ips

    # setup admin and guest userss
    setup_users

    # set needed configuration variables
    configure

    # save configuration variables to the config file
    save_config

    if [ -n "${SNAPSHOT_PATH:-}" ]; then
        restore_neo4j
    fi

    # Use su-exec to drop privileges to neo4j user
    # Note that su-exec, despite its name, does not replicate the
    # functionality of exec, so we need to use both
    ${exec_cmd} neo4j console

elif [ "${cmd}" == "backup" ]; then
    BACKUP_DIR=${BACKUP_DIR:-/tmp}

    # XXX: you may want to modify this script to just use the latest backup.
    # download latest backup if exist
    # LATEST_BACKUP=$(aws s3 ls s3://$AWS_BACKUP_BUCKET | tail -n 1 | awk '{print $4}')
    # if [ -n "$LATEST_BACKUP" ]; then
    #     echo "Getting latest backup file $LATEST_BACKUP from s3://$AWS_BACKUP_BUCKET"
    #     aws s3 cp s3://$AWS_BACKUP_BUCKET/$LATEST_BACKUP $BACKUP_DIR/
    #     echo "Unzipping backup content"
    #     unzip $BACKUP_DIR/$LATEST_BACKUP -d $BACKUP_DIR
    # fi

    if [ -z  $BACKUP_FROM ] || [ "$BACKUP_FROM" == "this_instance" ]; then
        BACKUP_FROM=$INSTANCE_IP
    fi

    echo "Creating Neo4j DB backup"
    su-exec ${userid} bin/neo4j-admin backup --backup-dir=$BACKUP_DIR/ --name=$BACKUP_NAME --from=$BACKUP_FROM

    BACKUP_FILE=$BACKUP_NAME-$(date +%s).zip

    echo "Zipping backup content in file $BACKUP_FILE"
    pushd $BACKUP_DIR
    zip -r $BACKUP_FILE $BACKUP_NAME
    # Upload file to the "/daily" dir if backup run at 00 hour
    if [ "$(date +%H)" == "00" ]; then
        aws s3 cp $BACKUP_FILE s3://$AWS_BACKUP_BUCKET/daily/
    else
        aws s3 cp $BACKUP_FILE s3://$AWS_BACKUP_BUCKET/hourly/
    fi
    rm -rf $BACKUP_FILE
    exit 0
else
    ${exec_cmd} "$@"
fi
