## Upgrade guide

Information below is up-to-date with Neo4j 3.4.6.

### Patch version upgrades

If you upgrade between patch versions, you might use
[rolling upgrade](https://neo4j.com/docs/operations-manual/current/upgrade/causal-cluster/#cc-upgrade-rolling)
just by updating each instance separately. However it is possible *only when a store format upgrade is not needed (see release notes for particular change)*.

One step: build a new version of docker image (based on newest official Neo4j Docker image), and use that image in CloudFormation (see step #1 in Generic Upgrades section below).


### Generic upgrades

(Based on [official Neo4j guide](https://neo4j.com/docs/operations-manual/current/upgrade/))

Moves between minor/major versions do not allow zero-downtime (as of the 3.4.6) database upgrade.

You want to make use of CloudFormation (CF) parameters to tweak upgrade steps, as follows below.

### Preconditions

- Time of day with lowest graph load
- Client-side retry system or logging of all queries, in order to not lose write queries.
- Build neo4j docker image with new version and have it in ECS.
- AWS console open.


### Migration

1. Update CF stack with parameters:

        DockerImage = <docker image address name:tag> 

    This will roll updates to cluster. If during this master fails over to another node, client might spot couple seconds window.



2. Update CF stack with parameters:

        Mode = SINGLE
        SlaveMode = SINGLE
        AllowUpgrade = True
        MaxSize = 1
        DesiredCapacity = 1

    This will downscale main cluster to one node - master. 

    This isolates the only master left from slave only instance. During start up of the only master container, it will roll upgrade on existing DB volume.

    Since it's the only node receiving the load, it will mean downtime for the duration of start up.

    Verify it's working properly. Good idea is to roll client tests since this is a final upgraded DB.


3. Manual migrations (if needed).

    If upgrade process involves index recreation or other migration to data, that needs to be done manually, it's the right time to do it.


4. Update CF stack with parameters:

        Mode = HA (but keep SlaveMode = SINGLE)
        AllowUpgrade = False

    Verify your single master is fine as HA node. Again downtime since master reboots.


5. Change "Name" tags for all slave Neo4j data volumes.

    For example "neo4j-production-data" → "neo4j-production-data-old". We don't need data volumes with old DB on slaves, with changed name nodes won't use old volumes after reboot.


6. (Optional) Create slave copies of master's migrated volume.

    If DB is big, this step is useful. Without it slave nodes will start on fresh DB and will need to catch up with master in online mode.

    So, you create a snapshot from a migrate Neo4j data volume and create volumes with needed tags in all regions. (Environment tag, Name tag).

    Still during boot of node, Neo4j might refuse to use your volume as too old, Neo will simply throw out the data and catch up with master online 



7. Update CF stack with parameters: (N = 2 for example)

        MaxSize = N
        DesiredCapacity = N

    Will upscale cluster and create new slaves, that will catch up.


8. Update CF stack with parameters:

        SlaveMode = HA

    Will reboot read-only slave as HA member, hooking up to new volume.


    Verify both main cluster and slave-only node are working properly, roll tests. Upgrade complete :)
