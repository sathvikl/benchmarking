#!/bin/bash
#shopt -s -o nounset


function usage() {
  echo "USAGE: $0 <Resource dir name (contains ab, yarn et.al)> <Github top-level dir-name containing the workload> <timeout (Optional)>"
  echo "Currently this script will run Ghost.js and mysql container, with the affinities as follows:"
  echo "Node : $(echo ${NODE_AFFINITY})"
  echo "MySQL : $(echo ${MYSQL_AFFINITY})"
  echo "Client : $(echo ${AB_AFFINITY})"
}


function mandatory() {
  if [ -z "${!1}" ]; then
    echo "${1} not set"
    usage
    exit 1
  fi
}

function optional() {
  if [ -z "${!1}" ]; then
    echo -n "${1} not set (ok)"
    if [ -n "${2}" ]; then
      echo -n ", default is: ${2}"
      export ${1}="${2}"
    fi
    echo ""
  fi
}

function remove(){
  if [ -f $1 ]; then
    rm $1
  fi
}

function stop_node_process() {
    echo -e "\n## STOPPING NODE PROCESS ##"
    case ${PLATFORM} in
      Linux)
        bash ${SCRIPT_DIR}/kill_node_linux $RESULTSLOG
        ;;
    esac
}

function stop_client() {
    echo -e "\n## STOPPING CLIENT PROCESS ##"
    pkill $DRIVERCMD 
}

function stop_mysql_server_container() {
  echo -e "\n## STOPPING MYSQLDB container service ##"
  echo -e "docker-mysql-stop will execute"
  . ./docker-mysql-stop.sh 
  killed_container_name=`stop_mysql_container $mysql_container_name` 2>&1 | tee -a $RESULTSLOG
}

function archive_files() {
  # archive files
  echo -e "\n##BEGIN $TEST_NAME Archiving $(date)\n"
  mkdir -p $ARCHIVE_DIR
  mv $LOGDIR_TEMP/* $ARCHIVE_DIR
  echo -e "Perf logs stored in $ARCHIVE_DIR"
  echo -e "\nCleaning up"
  rm -r $LOGDIR_TEMP
  echo -e "\n## END $TEST_NAME Archiving $(date)\n"
}

function on_exit()
{
    if [[ -z $EXIT_STATUS ]]; then
	   echo "Clean Exit\n"
	   echo "Exit Status: $EXIT_STATUS\n"
	else
	   echo "Caught kill"
	   echo "Exit Status: $EXIT_STATUS\n"
	fi
	stop_client
    stop_node_process
    stop_mysql_server_container
    archive_files
    kill $PID_timeout_monitor_function
	exit ${EXIT_STATUS}
}

function timestamp()
{
  date +"%Y%m%d-%H%M%S"
}

trap on_exit SIGINT SIGQUIT SIGTERM

# Utility functions
function hugepages_stats() {
  case ${PLATFORM} in
    Linux)
      HPPRETOTAL=`cat /proc/meminfo | grep HugePages_Total | sed 's/HugePages.*: *//g' | head -n 1`
      HPPREFREE=`cat /proc/meminfo | grep HugePages_Free | sed 's/HugePages.*: *//g' | head -n 2|tail -n 1`
      let HPPREINUSE=$HPPRETOTAL-$HPPREFREE
      echo "HP IN USE : " ${HPPREINUSE}
      ;;
  esac
}

# Check Node binary exists and it's version
function check_if_node_exists() {
  if [ -z $NODE ]; then
    NODE=`which node`
  else
    echo "ERROR: Could not find a 'node' executable. Please set the NODE environment variable or update the PATH."
    echo "node is not here: $NODE"
    exit 1
  fi
  echo -e "NODE VERSION:"
  $NODE --version
  return 0
}

# Start node.js application server
function check_node_app_status() {
  NODEAPP_START_THRESHOLD=120
  MIN_SLEEP=2
  TOTAL_SLEEP=0
  while true
  do
    node_program_name="$NODE $NODE_FILE"
    PID_NODE_SERVER=$(pgrep -f "${node_program_name}")
    if [ "x${PID_NODE_SERVER}" != "x" ]; then
      break
    fi
    TOTAL_SLEEP=`expr $TOTAL_SLEEP + $MIN_SLEEP`
    if [ $TOTAL_SLEEP -ge $NODEAPP_START_THRESHOLD ]; then
      echo "Exceeded nodeapp start time. [default: $NODEAPP_START_THRESHOLD secs]. Exit the run"
      EXIT_STATUS=1
      on_exit
    fi
    sleep $MIN_SLEEP
  done
  echo "Server started ..."
}

# Collect CPU statistics for Node, mysql, driver program (python in case of node-dc-eis, jmeter for acmeair, ab for ghost)
function collect_cpu_stats() {
  client_program_name="ab"
  db_program_name="mysqld"

  PID_CLIENT=$(pgrep "${client_program_name}")
  PID_DB=$(pgrep "${db_program_name}")
  echo "Getting CPU% for CLIENT DRIVER=$PID_CLIENT, MYSQL_DB=$PID_DB, NODE_SERVER=$PID_NODE_SERVER"

  SERVER_CPU_COMMAND="top -b -d 5 -n 47 -p $(echo $PID_CLIENT $PID_DB $PID_NODE_SERVER | sed 's/\s/,/g')"
  $SERVER_CPU_COMMAND >> $SERVER_CPU_STAT_FILE &
}

# Some supporting function may not need
function check_if_client_finished() {
  # Check if client has finished
  CLIENT_STATUS="success"
  while true
  do 
    x=`grep "Percentage of the requests served within a certain time" $RESULTSLOG`
    if [ "x${x}" != "x" ]; then
      break
    else
      x=`grep "apr_socket_recv: Connection refused" $RESULTSLOG`
      if [ "x${x}" != "x" ]; then
        CLIENT_STATUS="failed"
        break
      fi
    fi
    sleep 2
  done
  echo "Client finished: (${CLIENT_STATUS})"
}

function start_mysql_docker_server() {
  
  echo -e "\n## STARTING MYSQLDB container instance ##" 2>&1 | tee -a $RESULTSLOG
  echo -e "Run start_mysql_container $mysql_container_name $MYSQL_AFFINITY $ghostjs_mysql_dump_file" | tee -a $RESULTSLOG
  
  . ./docker-mysql-start.sh 
  container_return=$(start_mysql_container $mysql_container_name $MYSQL_AFFINITY $ghostjs_mysql_dump_file)
  
  if (exec sudo docker exec $mysql_container_name bash -c "service mysql status" | grep -i -e "MYSQL .* is running"); then
      echo -e "Docker mysql container created successfully" | tee -a $RESULTSLOG
  else
      echo -e "Error: Failed to create MySQL container $mysql_container_name"
	  exit 1
  fi
}

# Start nodeapp server
function start_nodeapp_server() {
  echo -e "\n## SERVER COMMAND ##" 2>&1 | tee -a $LOGFILE
  echo -e "NODE_ENV=$NODE_APP_MODE $CPUAFFINITY $NODE_APP_CMD" 2>&1 | tee -a $LOGFILE
  echo -e "## BEGIN TEST ##\n" 2>&1 | tee -a $LOGFILE

    # wait until npm install is done
    pushd ${GHOSTJS_DIR}
    # This script will check the version of Ghost.js being executed
	# It will run yarn install or npm install 
	# add yarn and npm to the $PATH variable for this session
	export PATH="$PATH:$RESOURCE_DIR"
    ./update_gscan_for_node8.sh 2>&1 | tee -a $RESULTSLOG
    popd 
  (   
    pushd ${GHOSTJS_DIR}
    echo GHOST_NODE_VERSION_CHECK=false NODE_ENV=$NODE_APP_MODE $CPUAFFINITY $NODE_APP_CMD
    echo -e "Node Ghost.js set to production mode"
    GHOST_NODE_VERSION_CHECK=false NODE_ENV=$NODE_APP_MODE $CPUAFFINITY $NODE_APP_CMD 2>&1 | tee -a $RESULTSLOG
    echo -e "\n## Node Server no longer running ##"
    popd
  ) &

  # Check if node application server is up
  check_node_app_status
}

function start_client() {
  REQUEST_COUNT=$1
  AB_RESULTSLOG=$2
  echo -e "\n## DRIVER COMMAND ##" 2>&1 | tee -a $AB_RESULTSLOG
  echo -e "$DRIVER_COMMAND -n $REQUEST_COUNT $DRIVER_URL" | tee -a $AB_RESULTSLOG

  if (exec $DRIVER_COMMAND -n $REQUEST_COUNT $DRIVER_URL 2>&1 | tee -a ${AB_RESULTSLOG}) ; then
   echo "Drivers have finished running" | tee -a $AB_RESULTSLOG
  else
   echo "ERROR: driver failed or killed" | tee -a $AB_RESULTSLOG
   echo "fail" | tee -a $AB_RESULTSLOG
  fi
}

function check_pre_requisite() {
    #check if benchmarking utility ab exists in resource directory or $PATH
	if [[  -z `which ab` ]] && [[ ! -e "$1/ab" ]]; then
       echo -e "benchmarking utility ab does not exist. Please install ab\n" 2>&1 | tee -a $RESULTSLOG
	   exit 1
    fi

    # Check if docker is installed and the service is running. 
	# docker service can fail for a variety of reasons, so don't try to start/stop the service here in this script. 
	if [[ -z `which docker` ]]; then
       echo -e "Please install docker\n" 2>&1 | tee -a $RESULTSLOG
	   exit 1
    elif  [[ -z $(sudo service docker status | grep -E "docker.*active|docker.*start\/running") ]]; then
	   echo -e "Please start docker daemon service\n" 2>&1 | tee -a $RESULTSLOG
	   exit 1
	fi
	
    check_if_node_exists
    echo -e "## Pre-Requiste check passed ##"
    echo -e "## Docker service is running ##"
    echo -e "## ab utility is available ##"
    
}

function monitor_timeout() {
   sleep $test_timeout
   EXIT_STATUS=1
   on_exit
}

# VARIABLE SECTION
#these may need changing when we find out more about the machine we're running on
NODE_AFFINITY="numactl --physcpubind=0,4"
# docker container needs only the cpu number(s)
MYSQL_AFFINITY="1,5"
AB_AFFINITY="numactl --physcpubind=2,6"

if [[ "$#" -lt 2 ]]; then
   usage
   exit
fi

check_pre_requisite $1

start=`date +%s`
#set locations so we don't end up with lots of hard coded bits throughout script
RESOURCE_DIR=$1  ### This is where mysql binary is located
WORKLOAD_DIR=$2  
if [[ "$#" -eq 3 ]]; then
   test_timeout=$3
fi
REL_DIR=$(dirname $0)
ROOT_DIR=`cd "${REL_DIR}/.."; pwd`
echo "ROOT_DIR=${ROOT_DIR}"
SCRIPT_DIR=${ROOT_DIR}/ghost-bench
GHOSTJS_DIR=${WORKLOAD_DIR}/ghostjs-repo/
ghostjs_mysql_dump_file="$GHOSTJS_DIR/../ghost-db.mysql"
BENCHMARK_RQST_COUNT=2000
DRIVER_URL="http://127.0.0.1:8013/new-world-record-with-apache-spark/"

EXIT_STATUS=0

# define variables
declare -rx SCRIPT=${0##*/}
declare -ix PID_NODE_SERVER
declare -ix PID_DB
declare -ix PID_CLIENT
declare -rx mysql_container_name="ghost_mysql"

TEST_NAME=ghostjs-bench
echo -e "\n## TEST: $TEST_NAME ##\n"

echo -e "## OPTIONS ##\n"
optional RESULTSDIR ${ROOT_DIR}/results
export LOGDIR_TEMP=$RESULTSDIR/temp
mkdir -p $LOGDIR_TEMP

CUR_DATE=$(timestamp)
RESULTSLOG=$LOGDIR_TEMP/$TEST_NAME.log
SUMLOG=$LOGDIR_TEMP/score_summary.txt
SERVER_CPU_STAT_FILE=$LOGDIR_TEMP/server_cpu.txt
ARCHIVE_DIR=$RESULTSDIR/$CUR_DATE

optional DRIVERHOST
optional NODE_APP_MODE "production"
optional NODE_FILE index.js
optional CLUSTER_MODE false
optional CLUSTER_MODE_NODE_FILE cluster-index.js
optional PORT 8013
optional DRIVERCMD ${RESOURCE_DIR}/ab
optional DRIVERNO 25
optional test_timeout 600 

NODE_SERVER=$(hostname -s)
echo -e "RESULTSDIR: $RESULTSDIR"
echo -e "RESULTSLOG: $RESULTSLOG"
echo -e "TIMEOUT: $TIMEOUT"
echo -e "NODE_SERVER: $NODE_SERVER"
echo -e "PORT: $PORT"
echo -e "NETWORKTYPE: $NETWORKTYPE"
echo -e "DRIVERCMD: $DRIVERCMD"
echo -e "DRIVERNO: $DRIVERNO\n"
echo -e "TIME OUT FOR THE TEST (seconds): $test_timeout\n"

DRIVER_COMMAND="$AB_AFFINITY $DRIVERCMD"
# END VARIABLE SECTION

# Date stamp for result files generated by this run
CUR_DATE=$(timestamp)

PLATFORM=`/bin/uname | cut -f1 -d_`
echo -e "Platform identified as: ${PLATFORM}\n"

# Stop existing node processes if still running
stop_node_process

# node execution command
NODE_APP_CMD="$NODE_AFFINITY ${NODE} ${NODE_FILE}"

# Pass the PID of this bash script
monitor_timeout "$$" &
PID_timeout_monitor_function=$!
echo -e "PID of timeout monitoring process is: $PID_timeout_monitor_function"

# Get hugepage information
hugepages_stats

# Source footprint collection/calculation script
. ${SCRIPT_DIR}/fp.sh

# Start a mysql instance
start_mysql_docker_server

# Start nodeapp server
start_nodeapp_server

# Adjust the time to sleep, on slower machines node might take longer to start-up
# npm install is not suspended so that is taken into account
sleep 10

# Get the memory footprint just before the run
pre=`getFootprint`
echo -n "Pre run Footprint in KB : $pre"

# Start the client driver command
# Start client
echo -e "\nStart of warming up the server with 1000 requests"
start_client 1000 /tmp/warmup-$TEST_NAME
echo -n "Benchmark start with $BENCHMARK_RQST_COUNT requests"
(start_client $BENCHMARK_RQST_COUNT $RESULTSLOG) &

# Collect CPU statistics
# wait for 5 seconds for client driver to re-start
sleep 5 
collect_cpu_stats

# Check if client finished
check_if_client_finished

# Get the memory footprint just after the run
post=`getFootprint`
echo -n "Post run Footprint in kB : $post"
echo
let footprint_diff=$post-$pre
echo
echo "Footprint diff in KB: $footprint_diff"

# Process/Show CPU stats

bash ${SCRIPT_DIR}/cpuParse.sh ${SERVER_CPU_STAT_FILE} "server"

# Print output

echo "SUMFILE is: ${SUMLOG}"

echo -e "\n##BEGIN $TEST_NAME OUPTUT $(date)\n" 2>&1 | tee -a $SUMLOG
echo metric throughput $(cat $RESULTSLOG | grep "^Requests per second" | tail -n 1| awk {'print $4'}) 2>&1 | tee -a $SUMLOG
echo metric latency $(cat $RESULTSLOG | grep "99\%" | tail -n 1 |awk {'print $2'}) 2>&1 | tee -a $SUMLOG
echo mv $RESULTSLOG $LOGDIR_TEMP/$LOGDIR_PREFIX

echo "metric pre footprint $pre"
echo "metric post footprint $post"
echo "metric footprint increase $footprint_diff"
echo -e "## TEST COMPLETE ##\n" 2>&1 | tee -a $SUMLOG
echo -e "## END $TEST_NAME OUTPUT $(date)\n\n" 2>&1 | tee -a $SUMLOG

end=`date +%s`
echo
echo "Test Start Time: $start"
echo "Test End Time : $end"
echo

let elapsed=$end-$start
echo "Elapsed time in sec(s): $elapsed"

echo "Done."
EXIT_STATUS=0
# Clean up on_exit() function
on_exit

