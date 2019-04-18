#!/bin/bash -eu

# get more info from AWS environment:
# - instance im running on
# - my IP
# - AZ and region.
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id/)
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4/)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone/)
REGION="us-east-1"

# these will be populated by cluster surrounding later in the code.
CLUSTER_IPS=""
SERVER_ID=""
COORDINATION_PORT=5001
BOLT_PORT=7687

ENVIRONMENT=""

# we use special tags for volumes, marked as data volumes.
# they hold Neo4j database and may be picked up by any node starting up in the respective
# availability zone.
DATA_TAG="${STACK_NAME}-data"

# number of iterations to try find any volume to use before creating a new one.
VOLUME_SEARCH_RETRIES=4

# number of iterations to wait for a volume to get attached
VOLUME_PROVISION_RETRIES=10

VOLUME_DEVICE="/dev/sdz"
DATA_ROOT="/neo4j"
FOUND_VOLUME=""
ATTACHED=false
DEVICE=""
BACKUP_NAME=neo4j-backup


assert_enterprise_license() {
  if [ "$NEO4J_EDITION" == "enterprise" ]; then
    if [ "${NEO4J_ACCEPT_LICENSE_AGREEMENT:=no}" != "yes" ]; then
      echo >&2 "
In order to use Neo4j Enterprise Edition you must accept the license agreement.
(c) Network Engine for Objects in Lund AB.  2017.  All Rights Reserved.
Use of this Software without a proper commercial license with Neo4j,
Inc. or its affiliates is prohibited.
Email inquiries can be directed to: licensing@neo4j.com
More information is also available at: https://neo4j.com/licensing/
To accept the license agreement set the environment variable
NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
To do this you can use the following docker argument:
        --env=NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
"
      exit 1
    fi
  fi
}


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
    get_tags

    local ips=$(aws ec2 describe-instances \
                --filters Name=tag-key,Values=App Name=tag-value,Values=Neo4j \
                          Name=tag-key,Values=Environment Name=tag-value,Values=$ENVIRONMENT \
                          Name=tag-key,Values=aws:cloudformation:stack-name Name=tag-value,Values=$STACK_NAME \
                --region $REGION \
                --query Reservations[].Instances[].InstanceId \
                --output text \
    )

    local count=0

    for ID in $ips;
    do
        local result=$(aws ec2 describe-instances --instance-ids $ID --region $REGION \
            --query 'Reservations[].Instances[].[PrivateIpAddress,Tags[?Key==`SlaveOnly`][Value]]' \
            --output text \
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


# reads the name of environment tag, provided as a paramter to CF.
get_tags() {
    echo "Instance tags: Reading..."

    ENVIRONMENT=$(aws ec2 describe-tags \
        --filters Name=resource-id,Values=${INSTANCE_ID} \
        --query "Tags[?Key=='Environment'][Value]" \
        --region ${REGION} \
        --output text \
    )

    if [ "$ENVIRONMENT" == "" ] ; then
        echo "Error: tag 'Environment' is required to be set on cluster instances."
        exit 1
    fi

    echo "Instance tags: environment = '${ENVIRONMENT}', data volume tags = '${DATA_TAG}'"
}


# creates a new volume with a desired size/type for database deployment
# happens only if no free compatible volume has been found in the given availability zone.
create_volume() {
    echo "Initiating volume creation... (Type: ${NEO4J_EBS_TYPE}, Size: ${NEO4J_EBS_SIZE})."

    local tags="ResourceType=volume,Tags=[{Key=Name,Value=$DATA_TAG},{Key=Environment,Value=$ENVIRONMENT}]"
    local state=$(aws ec2 create-volume \
        --availability-zone ${AZ} \
        --region ${REGION} \
        --volume-type ${NEO4J_EBS_TYPE} \
        --size ${NEO4J_EBS_SIZE} \
        --query [VolumeId,State] \
        --tag-specifications "${tags}" \
        --output=text \
    )
    local status=$?
    local parts=($state)
    FOUND_VOLUME="${parts[0]}"
    local state="${parts[1]}"

    if [ "$status" -ne 0 ] || [ "$state" != "creating" ]; then
        echo "Fatal: Failed to create new volume. AWS status: $status, volume state: '$state'."
        exit 1
    fi

    echo "Creating volume $FOUND_VOLUME..."

    local created=false
    for ((i=0; i < $VOLUME_PROVISION_RETRIES; i++))
    do
        # let it create
        sleep 2

        state=$(aws ec2 describe-volumes \
            --volume-ids=$FOUND_VOLUME \
            --region ${REGION} \
            --query=Volumes[].State \
            --output=text \
        )
        echo "Creation status: '$state'"
        if [ "$state" == "available" ]; then
            created=true
            break
        elif [ "$state" == "in-use" ]; then
            echo "Fatal: $FOUND_VOLUME already in-use."
            exit 1
        fi
    done

    if [ "$created" != true ]; then
        echo "Fatal: Failed to wait for $FOUND_VOLUME to be created."
        exit 1
    fi
}

# attach a volume with existing Neo4j database dir via AWS cli.
# Does several retries before abandoning and creating a new volume.
attach_volume() {
    ATTACHED=false
    FOUND_VOLUME=""

    echo "Attaching a volume $1..."

    local attach_state=$(aws ec2 attach-volume \
        --volume-id $1 \
        --instance-id ${INSTANCE_ID} \
        --device ${VOLUME_DEVICE} \
        --query State \
        --region ${REGION} \
        --output text \
    )

    local status=$?
    if [ "$status" -eq 0 ] && [ "$attach_state" == "attaching" ]; then
        echo "Successfully started attechment of $1!"
        FOUND_VOLUME=$1
    else
        echo "Failed to attach $1, state = '$attach_state', continuing..."
    fi

    for ((i=0; i < $VOLUME_PROVISION_RETRIES; i++))
    do
        # give it some time to attach
        sleep 2

        echo "Checking attachment status..."

        local status=$(aws ec2 describe-volumes \
            --volume-ids=$1 \
            --region ${REGION} \
            --query=Volumes[].[Attachments[].[InstanceId,State,Device]] \
            --output=text \
        )
        echo "Attachment status: '$status'"
        local parts=($status)
        local inst_id="${parts[0]}"
        local state="${parts[1]}"
        local dev="${parts[2]}"


        if [ "$inst_id" != "$INSTANCE_ID" ] ; then
            echo "Error: $1 volume was expected to be attached to instance $INSTANCE_ID, is attached to $inst_id"
            exit 1
        fi
        if [ "$state" == "attached" ] ; then
            echo "Successfully attached the volume!"
            ATTACHED=true
            DEVICE=$dev
            break
        fi
    done

    if [ "$ATTACHED" != true ] ; then
        echo "Error: $1 volume never got attached to instance $INSTANCE_ID."
        exit 1
    fi
}

# Establish a database directory on a data volume.
# Tries to attach a free volume in given AZ. If unsuccessful aftr several retries, will
# create a new volume, format it to ext4 if it has been just created and mount it.
setup_data_volume() {
    echo "Trying to start using existing Neo4j EBS volume... Instance ID = $INSTANCE_ID"

    # fetch environment/name for given node.
    get_tags

    DEVICE=""

    for ((i=0; i < $VOLUME_SEARCH_RETRIES; i++))
    do
        DEVICE=$(aws ec2 describe-volumes \
            --filters Name=tag-key,Values=Name Name=tag-value,Values=$DATA_TAG \
                      Name=tag-key,Values=Environment Name=tag-value,Values=$ENVIRONMENT \
                      Name=attachment.instance-id,Values=$INSTANCE_ID \
            --query Volumes[].Attachments[].Device \
            --region ${REGION} \
            --output text \
        )

        if [ "$DEVICE" != "" ] ; then
            echo "Found existing volume: $DEVICE"
            break
        else
            echo "No existing volume attached. Searching..."
        fi

        local volumes=$(aws ec2 describe-volumes \
            --filters Name=tag-key,Values=Name Name=tag-value,Values=$DATA_TAG \
                      Name=tag-key,Values=Environment Name=tag-value,Values=$ENVIRONMENT \
                      Name=availability-zone,Values=$AZ \
                      Name=status,Values=available \
            --query Volumes[].VolumeId \
            --region ${REGION} \
            --output text \
        )
        echo "Available volumes in $AZ: $volumes"

        for vol_id in $volumes;
        do
            attach_volume $vol_id
        done
        if [ "$FOUND_VOLUME" != "" ] ; then
            break
        else
            # no luck in this round, try to find free volumes again after a timeout.
            echo "Failed to attach an available volume in this round."
            sleep 2
        fi
    done

    if [ "$FOUND_VOLUME" == "" ] && [ "$DEVICE" == "" ]; then
        echo "WARNING: Could not find an available EBS volume in $AZ availability zone, nor existing device, must create."
        create_volume
        attach_volume $FOUND_VOLUME
    fi

    # check if its formatted, if not then make it be ext4
    local device_fmt=$(blkid $DEVICE)
    local status=$?
    echo "Block device ($DEVICE) (status $status): $device_fmt"

    if [ "$status" -ne 0 ] || [ "$device_fmt" == "" ]; then
        echo "New volume: formatting as ext4..."
        mkfs.ext4 $DEVICE
    fi

    # mount it
    echo "Mounting volume..."
    mkdir -p $DATA_ROOT
    mount $DEVICE $DATA_ROOT

    # make sure subdirs exist
    mkdir -p $DATA_ROOT/data
    mkdir -p $DATA_ROOT/logs

    ln -s $DATA_ROOT/data /var/lib/neo4j/data
    ln -s $DATA_ROOT/logs /var/lib/neo4j/logs
    echo "Mounting volume... Done."
}


# dump all configurationi to neo4j.conf
save_neo4j_configurations() {
    # list env variables with prefix NEO4J_ and create settings from them
    unset NEO4J_AUTH NEO4J_SHA256 NEO4J_TARBALL NEO4J_EBS_SIZE NEO4J_EBS_TYPE
    unset NEO4J_GUEST_AUTH
    for i in $( set | grep ^NEO4J_ | awk -F'=' '{print $1}' | sort -rn ); do
        setting=$(echo ${i} | sed 's|^NEO4J_||' | sed 's|_|.|g' | sed 's|\.\.|_|g')
        value=$(echo ${!i})
        if [[ -n ${value} ]]; then
            if grep -q -F "${setting}=" /var/lib/neo4j/conf/neo4j.conf; then
                # Remove any lines containing the setting already
                sed --in-place "/${setting}=.*/d" /var/lib/neo4j/conf/neo4j.conf
            fi
            # Then always append setting to file
            echo "${setting}=${value}" >> /var/lib/neo4j/conf/neo4j.conf
        fi
    done
}

configure_neo4j() {
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
    # using lucene index provider fixes disk leak in the 3.4.6 version
    NEO4J_dbms_index_default__schema__provider="lucene+native-2.0"

    # not configurable for now.
    NEO4J_ha_tx__push__strategy=fixed_ascending
    NEO4J_dbms_security_procedures_unrestricted=apoc.*

    # this allows master/slave health/status endpoints to be open for ELB
    # without basic auth.
    NEO4J_dbms_security_ha__status__auth__enabled=false

    # Env variable naming convention:
    # - prefix NEO4J_
    # - double underscore char '__' instead of single underscore '_' char in the setting name
    # - underscore char '_' instead of dot '.' char in the setting name
    # Example:
    # NEO4J_dbms_tx__log_rotation_retention_policy env variable to set
    #       dbms.tx_log.rotation.retention_policy setting


    # Backward compatibility - map old hardcoded env variables into new naming convention
    : ${NEO4J_dbms_tx__log_rotation_retention__policy:=${NEO4J_dbms_txLog_rotation_retentionPolicy:-"100M size"}}
    : ${NEO4J_wrapper_java_additional:=${NEO4J_UDC_SOURCE:-"-Dneo4j.ext.udc.source=docker"}}
    : ${NEO4J_dbms_memory_heap_initial__size:=${NEO4J_dbms_memory_heap_maxSize:-"512M"}}
    : ${NEO4J_dbms_memory_heap_max__size:=${NEO4J_dbms_memory_heap_maxSize:-"512M"}}
    : ${NEO4J_dbms_unmanaged__extension__classes:=${NEO4J_dbms_unmanagedExtensionClasses:-}}
    : ${NEO4J_dbms_allow__format__migration:=${NEO4J_dbms_allowFormatMigration:-}}
    : ${NEO4J_dbms_connectors_default__advertised__address:=${NEO4J_dbms_connectors_defaultAdvertisedAddress:-}}
    : ${NEO4J_causal__clustering_expected__core__cluster__size:=${NEO4J_causalClustering_expectedCoreClusterSize:-}}
    : ${NEO4J_causal__clustering_initial__discovery__members:=${NEO4J_causalClustering_initialDiscoveryMembers:-}}
    : ${NEO4J_causal__clustering_discovery__listen__address:=${NEO4J_causalClustering_discoveryListenAddress:-"0.0.0.0:5000"}}
    : ${NEO4J_causal__clustering_discovery__advertised__address:=${NEO4J_causalClustering_discoveryAdvertisedAddress:-"$(hostname):5000"}}
    : ${NEO4J_causal__clustering_transaction__listen__address:=${NEO4J_causalClustering_transactionListenAddress:-"0.0.0.0:6000"}}
    : ${NEO4J_causal__clustering_transaction__advertised__address:=${NEO4J_causalClustering_transactionAdvertisedAddress:-"$(hostname):6000"}}
    : ${NEO4J_causal__clustering_raft__listen__address:=${NEO4J_causalClustering_raftListenAddress:-"0.0.0.0:7000"}}
    : ${NEO4J_causal__clustering_raft__advertised__address:=${NEO4J_causalClustering_raftAdvertisedAddress:-"$(hostname):7000"}}

    # unset old hardcoded unsupported env variables
    unset NEO4J_dbms_txLog_rotation_retentionPolicy NEO4J_UDC_SOURCE \
        NEO4J_dbms_memory_heap_maxSize NEO4J_dbms_memory_heap_maxSize \
        NEO4J_dbms_unmanagedExtensionClasses NEO4J_dbms_allowFormatMigration \
        NEO4J_dbms_connectors_defaultAdvertisedAddress NEO4J_ha_serverId \
        NEO4J_ha_initialHosts NEO4J_causalClustering_expectedCoreClusterSize \
        NEO4J_causalClustering_initialDiscoveryMembers \
        NEO4J_causalClustering_discoveryListenAddress \
        NEO4J_causalClustering_discoveryAdvertisedAddress \
        NEO4J_causalClustering_transactionListenAddress \
        NEO4J_causalClustering_transactionAdvertisedAddress \
        NEO4J_causalClustering_raftListenAddress \
        NEO4J_causalClustering_raftAdvertisedAddress

    # Custom settings for dockerized neo4j
    : ${NEO4J_dbms_tx__log_rotation_retention_policy:=100M size}
    : ${NEO4J_dbms_memory_pagecache_size:=512M}
    : ${NEO4J_wrapper_java_additional:=-Dneo4j.ext.udc.source=docker}
    : ${NEO4J_dbms_memory_heap_initial__size:=512M}
    : ${NEO4J_dbms_memory_heap_max__size:=512M}
    : ${NEO4J_dbms_connectors_default__listen__address:=0.0.0.0}
    : ${NEO4J_dbms_connector_http_listen__address:=0.0.0.0:7474}
    : ${NEO4J_dbms_connector_https_listen__address:=0.0.0.0:7473}
    : ${NEO4J_dbms_connector_bolt_listen__address:=0.0.0.0:$BOLT_PORT}
    : ${NEO4J_ha_host_coordination:=$(hostname):$COORDINATION_PORT}
    : ${NEO4J_ha_host_data:=$(hostname):6001}
    : ${NEO4J_causal__clustering_discovery__listen__address:=0.0.0.0:5000}
    : ${NEO4J_causal__clustering_discovery__advertised__address:=$(hostname):5000}
    : ${NEO4J_causal__clustering_transaction__listen__address:=0.0.0.0:6000}
    : ${NEO4J_causal__clustering_transaction__advertised__address:=$(hostname):6000}
    : ${NEO4J_causal__clustering_raft__listen__address:=0.0.0.0:7000}
    : ${NEO4J_causal__clustering_raft__advertised__address:=$(hostname):7000}

    if [ -d /conf ]; then
        find /conf -type f -exec cp {} conf \;
    fi

    if [ -d /ssl ]; then
        NEO4J_dbms_directories_certificates="/ssl"
    fi

    if [ -d /plugins ]; then
        NEO4J_dbms_directories_plugins="/plugins"
    fi

    if [ -d /logs ]; then
        NEO4J_dbms_directories_logs="/logs"
    fi

    if [ -d /import ]; then
        NEO4J_dbms_directories_import="/import"
    fi

    if [ -d /metrics ]; then
        NEO4J_dbms_directories_metrics="/metrics"
    fi

    user=$(echo ${NEO4J_AUTH:-} | cut -d'/' -f1)
    password=$(echo ${NEO4J_AUTH:-} | cut -d'/' -f2)

    guest_user=$(echo ${NEO4J_GUEST_AUTH:-} | cut -d'/' -f1)
    guest_password=$(echo ${NEO4J_GUEST_AUTH:-} | cut -d'/' -f2)

    if [ "${NEO4J_AUTH:-}" == "none" ]; then
        NEO4J_dbms_security_auth__enabled=false
    elif [[ "${user}" == neo4j ]]; then
        if [ "${password}" == "neo4j" ]; then
            echo "Invalid value for password. It cannot be 'neo4j', which is the default."
            exit 1
        fi

        # Will exit with error if users already exist (and print a message explaining that)
        bin/neo4j-admin set-initial-password "${password}" || true

        # as soon as we get credentials, we can start waiting for BOLT protocol to warm it up
        # upon startup.
        echo "Scheduling init tasks..."
        NEO4J_USERNAME="${user}" NEO4J_PASSWORD="${password}" GUEST_USERNAME="${guest_user}" GUEST_PASSWORD="${guest_password}" bash /init_db.sh &
        echo "Scheduling init tasks: Done."

    elif [ -n "${NEO4J_AUTH:-}" ]; then
        echo "Invalid value for NEO4J_AUTH: '${NEO4J_AUTH}'"
        exit 1
    fi
}

run_neo4j() {
    [ -f "${EXTENSION_SCRIPT:-}" ] && . ${EXTENSION_SCRIPT}
    exec /var/lib/neo4j/bin/neo4j console
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

    /var/lib/neo4j/bin/neo4j-admin restore --from="$BACKUP_DIR/$BACKUP_NAME" --database=graph.db --force
    status=$?
    if [ "$status" -ne 0 ] ; then
        echo "Error: failed to restore from snapshot."
        exit 1
    fi
}

if [ "$1" == "neo4j" ]; then
    # make sure the client has aggreed to license if it's an enterprise edition.
    # (only prompt for license agreement if command contains "neo4j" in it).
    assert_enterprise_license

    # create server ID, unique to this instance, based on it's private IP's last 2 octets.
    make_server_id

    # get all IPs of this autoscaling group to build ha.initial_hosts of the cluster.
    get_cluster_node_ips

    setup_data_volume

    configure_neo4j
    save_neo4j_configurations

    if [ -n "${SNAPSHOT_PATH:-}" ]; then
        restore_neo4j
    fi

    run_neo4j

elif [ "$1" == "dump-config" ]; then
    if [ -d /conf ]; then
        cp --recursive conf/* /conf
    else
        echo "You must provide a /conf volume"
        exit 1
    fi
elif [ "$1" == "backup" ]; then
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

    configure_neo4j
    save_neo4j_configurations

    echo "Creating Neo4j DB backup"
    /var/lib/neo4j/bin/neo4j-admin backup --backup-dir=$BACKUP_DIR/ --name=$BACKUP_NAME --from=$BACKUP_FROM

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
else
    exec "$@"
fi
