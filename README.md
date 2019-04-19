# neo4j-aws-ha-cluster

A setup for HA (High-Availability) deployment of a [Neo4j Enterprise](https://neo4j.com/subscriptions/#editions) cluster on top of [AWS ECS](https://aws.amazon.com/ecs/).

You can obtain Neo4j from the [official website](https://neo4j.com/). Please contact sales@neo4j.com for Enterprise licensing.

## Includes

- Customizable CloudFormation template.
- Custom docker image on top [official Neo4j image](https://hub.docker.com/_/neo4j/). Current version - *Neo4j 3.5.4*

## Features

- Automatic daily backups to S3 using a slave-only instance.
- Bootstrap a cluster from a backup snapshot.
- Autoscaling (based on Memory Utilization).
- CloudWatch alerts setup.
- Bootstrap a node with an existing data volume for quick startup.
- Automatically create users+credentials for read-only and read/write access.

## Prerequisites

- Install [Docker](https://docs.docker.com/engine/installation/) to build the image.
- [AWS CLI](https://aws.amazon.com/cli) for the ECR Auth.

## How does it work?

![Infrastructure](images/infrastructure.png)

Neo4j graph database is deployed as a highly-available (HA) cluster with master-slave replication. 

It uses [Bolt](https://boltprotocol.org/) – a highly efficient, lightweight binary client-server protocol designed for database applications.

Essentially it's a Neo4j cluster with a minimum of 2 nodes (use at least 3 for HA), which is split logically into 2 ECS clusters (yet still it's 1 Neo4j cluster):

### A Read-Write cluster with one master node and multiple slaves

- Fast synchronisation between and master and nodes.
- Load Balancer keeps only a current master node in service. Hence slaves act like hot-standby in case of a failover.
- All nodes are eligible for becoming a master. Reelection will be quickly spotted by ELB.

### A Read-only cluster with one slave node [optionally]

_This will generate additional costs, since separate ELB is created for this node_

- Slower synchronisation.
- Can not become master.
- Can not accept write queries.
- Can handle complex queries without affecting performance of the R/W cluster.
- Still participates in master elections.
- Can be deployed as a different EC2 instance type for temporary heavy analytics.
- Load Balancer keeps this single node in service.
- Backups are performed on this node to avoid performance hits on R/W nodes.
- On testing environment its not present, and only a single node in the main cluster is doing the backups.

Ports open:

```yaml
  - HTTP(s): 7473, 7474
  - Bolt: 7687
```

## Usage

1. Create an ECR repository for Neo4j custom images. You will use it's ARN.
   (ARN looks like `arn:aws:ecr:us-east-1:123456789012:repository/neo`).

2. Save environment variable for use in makefile (customize them first)

    ```sh
    export NEO_ECR_REPO=<paste here ARN of your ECR repo>
    export NEO_AWS_REGION=<your AWS region>
    ```

3. Build Docker image and push it to your ECR:

    ``` sh
    make push_image
    ```

4. Feel free to modify `cloudformation.yml` in any way you like before spinning up infrastructure, however most of the things are customizable via parameters.

5. [Create a Cloud Formation stack](https://console.aws.amazon.com/cloudformation/home#/stacks/new) using `cloudformation.yml` with your parameters.

    _If you want to setup simpler (and cheaper)  environment, without the Slave-Only node (and all realted resources),
    you can set `SlaveMode=ABSENT` and ignore the rest of `Slave` related parameters (except `SlaveSubnetID` you need to choose any subnet there,
    it will be ingnored as long as `SlaveMode=ABSENT`)_

    **Parameters guide**

    Parameter | Description
    ----------|----------
    AcceptLicense | Must be set to `true` in order to use Neo4J
    AdminUser     | Default Admin user should be `neo4j` and can't be changed
    ClusterInstanceType | EC2 instance type
    DesiredCapacity     | Number of desired Neo4J nodes (excluding the SlaveOnly one)
    DockerECRARN        | ARN of your Private ECR repo
    DockerImage         | URL of your customly build Neo4J Image
    Domain              | The domain for the your Neo4J cluster endpoint (http://<domain>:7474)
    DomainHostedZone    | Route53 Domain Hosted zone to register your DNS record
    EBSSize             | Size of EBS volume for Neo4J data in GBs
    EBSType             | Type of EBS volume
    GuestPassword       | Password for the Neo4J Read Only user
    GuestUser           | Name for the Neo4j Read Only user
    KeyName             | SSH key to use for EC2 instances access
    MaxSize             | Max number of instances in the cluster
    SubnetID            | List of Subnets to place Neo4J Cluster nodes. *Supported only one instance per Subnet*
    Mode                | [Neo4J DB Mode](https://neo4j.com/docs/operations-manual/current/reference/configuration-settings/#config_dbms.mode)
    NodeSecurityGroups  | List of additional SG to apply on your EC2 instances
    SlaveMode           | [Neo4J DB Mode](https://neo4j.com/docs/operations-manual/current/reference/configuration-settings/#config_dbms.mode) for the SlaveOnly instance, with the addional one `ABSENT` that can be used to create Neo4J cluster without the SlaveOnly instance
    SlaveOnlyDomain     | The domain for the your Neo4J SlaveOnly endpoint (http://<domain>:7474)
    SlaveOnlyInstanceType | EC2 instance type for the slave only mode
    SlaveSubnetID       | SubnetID for the Slave only instance. *Should be different one from the main cluster subnets, but should be able to access other instances*. Even if `SlaveMode` set to `ABSENT` some value must be set here (it will be ignored in this case) 
    VpcId               | AWS VPC ID to place your cluster in
    SNSTopicArn         | SNS Topic ARN to send Alerts to. If none specified, new one will be created
    SnapshotPath        | Path to the DB snapshot on the S3, to restore data from on start (_<bucket_name>/hourly/neo4j-backup-<timestamp>.zip_)

   During this step you will define all the resources you need and configure Docker image with Neo4j for ECS.
    Please consider tagging your stack (on "Options" page):

    ```yaml
    Name: <how you name your stack>
    Environment: <your env name, e.g production>
    ```

## Upgrade version

Please see [detailed instructions](./UPGRADE_README.md) to upgrade using this CF template.

## Known Problems

- You can't restore server from a backup without a downtime. See [further instructions](https://neo4j.com/docs/operations-manual/current/backup/restore-backup/#backup-restore-ha-cluster).
- Autoscaling is hardcoded via RAM utilization (>70%). Feel free to modify for your own needs.
- Sometimes, rolling updates, that require nodes reboot, render them stuck for some time before rejoining cluster. Probaly a slower rolling update can help so that at each moment at least one node is already registered in main ELB as master.

## TODO

- Parametrize autoscaling.
