#!/bin/bash
# © Copyright IBM Corporation 2015.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# which accompanies this distribution, and is available at
# http://www.eclipse.org/legal/epl-v10.html

set -e

MQ_QMGR_NAME=${MQ_QMGR_NAME-QM1}
NODENAME=${NODENAME-IIBV10NODE}
SERVERNAME=${SERVERNAME-default}

stop()
{
	echo "----------------------------------------"
	echo "Stopping node $NODENAME..."
	mqsistop $NODENAME
        echo "----------------------------------------"
        echo "Stopping node $NODENAME..."
        endmqm $MQ_QMGR_NAME
        exit
}

start_iib()
{
	echo "----------------------------------------"
        /opt/ibm/iib-10.0.0.14/iib version
	echo "----------------------------------------"

        NODE_EXISTS=`mqsilist | grep $NODENAME > /dev/null ; echo $?`


	if [ ${NODE_EXISTS} -ne 0 ]; then
          echo "----------------------------------------"
          echo "Node $NODENAME does not exist..."
          echo "Creating node $NODENAME"
          mqsicreatebroker -q $MQ_QMGR_NAME $NODENAME
          echo "----------------------------------------" 
          echo "----------------------------------------"
          echo "Starting syslog"
          sudo /usr/sbin/rsyslogd
          echo "Starting node $NODENAME"
          mqsistart $NODENAME
          echo "----------------------------------------" 
          echo "----------------------------------------"
          echo "Creating integration server $SERVERNAME"
          mqsicreateexecutiongroup $NODENAME -e $SERVERNAME -w 120
          mqsichangeproperties $NODENAME -e $SERVERNAME -o ExecutionGroup -n httpNodesUseEmbeddedListener -v true
          echo "----------------------------------------"
          echo "----------------------------------------"
          echo "Create Debug port"
          echo "----------------------------------------"
          echo "----------------------------------------"
          echo "mqsichangeproperties $NODENAME -e $SERVERNAME -o ComIbmJVMManager -n jvmDebugPort -v 2712"  
            mqsichangeproperties $NODENAME -e $SERVERNAME -o ComIbmJVMManager -n jvmDebugPort -v 2712
          echo "Debug enabled at 2712"
          echo "----------------------------------------"
          echo "----------------------------------------"
          echo "Stoping server $SERVERNAME"
            mqsistopmsgflow $NODENAME -e $SERVERNAME
          echo "----------------------------------------" 
          echo "----------------------------------------"
          echo "Starting server $SERVERNAME"
            mqsistartmsgflow $NODENAME -e $SERVERNAME
          echo "----------------------------------------" 
          echo "----------------------------------------"

          shopt -s nullglob
          for f in /tmp/BARs/* ; do
            echo "Deploying $f ..."
            mqsideploy $NODENAME -e $SERVERNAME -a $f -w 120
          done		  
          echo "----------------------------------------"

    echo "Creating Monitoring event profile"
    mqsicreateconfigurableservice $NODENAME -c MonitoringProfiles -o MyMonitoringEventProfile
    echo "----------------------------------------"

    echo "Associate profile with monitoring events"
    mqsichangeproperties $NODENAME -c MonitoringProfiles -o MyMonitoringEventProfile -n profileProperties -p /tmp/Confs/ESBMonitoringProfile_Payload.xml
    echo "----------------------------------------"

    echo "Enable event handling for all the deployed flows"
    mqsichangeflowmonitoring $NODENAME -e $SERVERNAME -j -m MyMonitoringEventProfile -c active
    echo "----------------------------------------"

    echo "De-activate the events handling into splunk application to avoid circular logging"
    mqsichangeflowmonitoring $NODENAME -e $SERVERNAME -k SplunkLogging -f Logging -m MyMonitoringEventProfile -c inactive
    echo "----------------------------------------"


	else
          echo "----------------------------------------"
          echo "Starting syslog"
          sudo /usr/sbin/rsyslogd
          echo "Starting node $NODENAME"
          mqsistart $NODENAME
          echo "----------------------------------------" 
          echo "----------------------------------------"
	fi
}

configure_iib()
{
    echo "----------------------------------------"
    echo "Create Topic"
    echo "DEFINE TOPIC('COMMONEVENT.TOPIC') TOPICSTR('$SYS/Broker/$NODENAME/Monitoring/#')"
    docker exec -it $MQ_QMGR_NAME -c "runmqsc -m QM1 DEFINE TOPIC ('COMMONEVENT.TOPIC') TOPICSTR('$SYS/Broker/$NODENAME/Monitoring/#')"
    echo "Topic Created"
    echo "----------------------------------------"
    echo "Create Subscription"
    echo "DEFINE SUB (‘COMMONEVENT.SUB’) TOPICOBJ(‘COMMONEVENT.TOPIC’) DEST (‘QUEUE.IN’)"
    runmqsc $MQ_QMGR_NAME -c "DEFINE SUB (‘COMMONEVENT.SUB’) TOPICOBJ(‘COMMONEVENT.TOPIC’) DEST (‘QUEUE.IN’)"
    echo "Subscription Created"
    exit
}

monitor()
{
	echo "----------------------------------------"
	echo "Running - stop container to exit"
	# Loop forever by default - container must be stopped manually.
	# Here is where you can add in conditions controlling when your container will exit - e.g. check for existence of specific processes stopping or errors being reported
	while true; do
		sleep 1
	done
}
#############################################################################################################
#!/bin/bash

# Copyright 2018 Splunk
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

setup() {
	# Check if the user accepted the license
	if [[ "$SPLUNK_START_ARGS" != *"--accept-license"* ]]; then
		printf "License not accepted, please ensure the environment variable SPLUNK_START_ARGS contains the '--accept-license' flag\n"
		printf "For example: docker run -e SPLUNK_START_ARGS=--accept-license -e SPLUNK_PASSWORD splunk/splunk\n\n"
		printf "For additional information and examples, see the help: docker run -it splunk/splunk help\n"
		exit 1
	fi

	sudo mkdir -p /opt 
	sudo chown -R ${SPLUNK_USER}:${SPLUNK_GROUP} /opt 
}

teardown() {
	# Always run the stop command on termination
	${SPLUNK_HOME}/bin/splunk stop 2>/dev/null || true
}

trap teardown SIGINT SIGTERM 

prep_ansible() {
	cd ${SPLUNK_ANSIBLE_HOME}
	if [[ "$DEBUG" == "true" ]]; then
		ansible-playbook --version
		python inventory/environ.py --write-to-file
		cat /opt/ansible/inventory/ansible_inventory.json
		cat /opt/ansible/inventory/messages.txt || true
		echo
	fi
}

watch_for_failure(){
	if [[ $? -eq 0 ]]; then
		sudo sh -c "echo 'started' > /var/run/splunk-container.state"
	fi
	echo ===============================================================================
	echo
	echo Ansible playbook complete, will begin streaming var/log/splunk/splunkd_stderr.log
	echo
	# Any crashes/errors while Splunk is running should get logged to splunkd_stderr.log and sent to the container's stdout
	tail -n 0 -f ${SPLUNK_HOME}/var/log/splunk/splunkd_stderr.log &
	wait
}

create_defaults() {
    createdefaults.py
}

start_and_exit() {
    if [ -z "$SPLUNK_PASSWORD" ]
    then
        echo "WARNING: No password ENV var.  Stack may fail to provision if splunk.password is not set in ENV or a default.yml"
    fi
	sudo sh -c "echo 'starting' > /var/run/splunk-container.state"
	setup
    prep_ansible
	ansible-playbook $ANSIBLE_EXTRA_FLAGS -i inventory/environ.py site.yml
}

start() {
    trap teardown EXIT 
	start_and_exit
    watch_for_failure
}

restart(){
    trap teardown EXIT 
	sudo sh -c "echo 'restarting' > /var/run/splunk-container.state"
    prep_ansible
  	${SPLUNK_HOME}/bin/splunk stop 2>/dev/null || true
	ansible-playbook -i inventory/environ.py start.yml
	watch_for_failure
}

help() {
	cat << EOF
  ____        _             _      __  
 / ___| _ __ | |_   _ _ __ | | __  \ \\ 
 \___ \| '_ \| | | | | '_ \| |/ /   \ \\
  ___) | |_) | | |_| | | | |   <    / /
 |____/| .__/|_|\__,_|_| |_|_|\_\  /_/ 
       |_|                            
========================================
Environment Variables: 
  * SPLUNK_USER - user under which to run Splunk (default: splunk)
  * SPLUNK_GROUP - group under which to run Splunk (default: splunk)
  * SPLUNK_HOME - home directory where Splunk gets installed (default: /opt/splunk)
  * SPLUNK_START_ARGS - arguments to pass into the Splunk start command; you must include '--accept-license' to start Splunk (default: none)
  * SPLUNK_ROLE - the role of this Splunk instance (default: splunk_standalone)
      Acceptable values:
        - splunk_standalone
        - splunk_search_head
        - splunk_indexer
        - splunk_deployer
        - splunk_license_master
        - splunk_cluster_master
        - splunk_heavy_forwarder 
  * SPLUNK_LICENSE_URI - URI or local file path (absolute path in the container) to a Splunk license
  * SPLUNK_STANDALONE_URL, SPLUNK_INDEXER_URL, ... - comma-separated list of resolvable aliases to properly bring-up a distributed environment. 
                                                     This is optional for standalones, but required for multi-node Splunk deployments.
  * SPLUNK_BUILD_URL - URL to a Splunk build which will be installed (instead of the image's default build)
  * SPLUNK_APPS_URL - comma-separated list of URLs to Splunk apps which will be downloaded and installed
Examples:
  * docker run -it -p 8000:8000 splunk/splunk start 
  * docker run -it -e SPLUNK_START_ARGS=--accept-license -p 8000:8000 -p 8089:8089 splunk/splunk start
  * docker run -it -e SPLUNK_START_ARGS=--accept-license -e SPLUNK_LICENSE_URI=http://example.com/splunk.lic -p 8000:8000 splunk/splunk start
  * docker run -it -e SPLUNK_START_ARGS=--accept-license -e SPLUNK_INDEXER_URL=idx1,idx2 -e SPLUNK_SEARCH_HEAD_URL=sh1,sh2 -e SPLUNK_ROLE=splunk_search_head --hostname sh1 --network splunknet --network-alias sh1 -e SPLUNK_PASSWORD=helloworld -e SPLUNK_LICENSE_URI=http://example.com/splunk.lic splunk/splunk start
EOF
    exit 1
}
case "$1" in
	start|start-service)
		shift
		start $@
		;;
	start-and-exit)
		shift
		start_and_exit $@
		;;
	create-defaults)
	    create_defaults
	    ;;
	restart)
	    shift
	    restart $@
	    ;;
	no-provision)
		tail -n 0 -f /etc/hosts &
		wait
		;;
	bash|splunk-bash)
		/bin/bash --init-file ${SPLUNK_HOME}/bin/setSplunkEnv
		;;
	help)
		shift
		help $@
		;;
	*)
		shift
		help $@
		;;
esac
################################################################################################
license-check.sh
sudo -u root -E mq_start.sh
start_iib
#configure_iib
trap stop SIGTERM SIGINT
monitor
