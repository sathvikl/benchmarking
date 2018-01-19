#!/bin/bash  
#shopt -s -o nounset

start=`date +%s`
#set locations so we don't end up with lots of hard coded bits throughout script
RESOURCE_DIR=$1  ### This is where mysql binary is located
WORKLOAD_DIR=$2  
REL_DIR=$(dirname $0)
ROOT_DIR=`cd "${REL_DIR}/.."; pwd`
echo "ROOT_DIR=${ROOT_DIR}"
SCRIPT_DIR=${ROOT_DIR}/ghost-bench
# Sathvik .. make a correction here..
GHOSTJS_DIR=${WORKLOAD_DIR}/
MYSQL_DIR=${RESOURCE_DIR}/mysql

EXIT_STATUS=0

#these may need changing when we find out more about the machine we're running on
NODE_AFFINITY="numactl --physcpubind=0,4"
MYSQL_AFFINITY="numactl --physcpubind=1,5"
AB_AFFINITY="numactl --physcpubind=2,6"

function usage() {
  echo "USAGE:"
  echo "Currently this script will run Ghost.js and mysql, with the affinities as follows:"
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
        bash ${SCRIPT_DIR}/kill_node_linux
        ;;
    esac
}

function stop_client() {
    echo -e "\n## STOPPING CLIENT PROCESS ##"
    pkill ab
}

function stop_mysql() {
  MYSQLDB_COMMAND="sudo service mysql"
  echo -e "\n## STOPPING MYSQLDB ##"
  echo -e " $MYSQLDB_COMMAND stop"
  $MYSQLDB_COMMAND stop
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
    echo "Caught kill"
    stop_client
    stop_node_process
    stop_mysql
    archive_files
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
}

# Start node.js application server
function check_node_app_status() {
  NODEAPP_START_THRESHOLD=120
  MIN_SLEEP=2
  TOTAL_SLEEP=0
  echo "Inside check_node_app_status"
  while true
  do
    ##SATHVIK ..what is this xcheck ?
    x=`grep "Ghost is running in production" $RESULTSLOG`
    if [ "x${x}" != "x" ]; then
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
  node_program_name="$NODE $NODE_FILE"

  PID_CLIENT=$(pgrep "${client_program_name}")
  PID_DB=$(pgrep "${db_program_name}")
  PID_NODE_SERVER=$(pgrep -f "${node_program_name}")
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

function start_mysql_server() {
  MYSQLDB_COMMAND="sudo service mysql"
  echo -e "\n## STARTING MYSQLDB ##" 2>&1 | tee -a $RESULTSLOG
  echo -e " $MYSQLDB_COMMAND start" | tee -a $RESULTSLOG
  #SATHVIK this does not work for service cmd.. keep it here for docker cmd
  $MYSQL_AFFINITY $MYSQLDB_COMMAND start 2>&1 | tee -a $RESULTSLOG
}

# Start nodeapp server
function start_nodeapp_server() {
  echo -e "\n## SERVER COMMAND ##" 2>&1 | tee -a $LOGFILE
  echo -e "NODE_ENV=$NODE_APP_MODE $CPUAFFINITY $NODE_APP_CMD" 2>&1 | tee -a $LOGFILE
  echo -e "## BEGIN TEST ##\n" 2>&1 | tee -a $LOGFILE

  (
    pushd ${GHOSTJS_DIR}
    echo  NODE_ENV=$NODE_APP_MODE $CPUAFFINITY $NODE_APP_CMD
    #npm install 2>&1 | tee -a $RESULTSLOG
    echo -e "Node Ghost.js set to production mode"
    NODE_ENV=$NODE_APP_MODE $CPUAFFINITY $NODE_APP_CMD 2>&1 | tee -a $RESULTSLOG
    echo -e "\n## Node Server no longer running ##"
    popd
    #sync the output console messages
    sleep 3
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

# VARIABLE SECTION

# define variables
declare -rx SCRIPT=${0##*/}
TEST_NAME=ghostjs-bench
echo -e "\n## TEST: $TEST_NAME ##\n"

echo -e "## OPTIONS ##\n"
optional RESULTSDIR ${ROOT_DIR}/results
export LOGDIR_TEMP=$RESULTSDIR/temp
mkdir -p $LOGDIR_TEMP

optional TIMEOUT 30
CUR_DATE=$(timestamp)
RESULTSLOG=$LOGDIR_TEMP/$TEST_NAME.log
SUMLOG=$LOGDIR_TEMP/score_summary.txt
SERVER_CPU_STAT_FILE=$LOGDIR_TEMP/server_cpu.txt
ARCHIVE_DIR=$RESULTSDIR/$CUR_DATE
DRIVER_URL="http://127.0.0.1:8013/new-world-record-with-apache-spark/"

optional DRIVERHOST
optional NODE_APP_MODE "production"
optional NODE_FILE index.js
optional CLUSTER_MODE false
optional CLUSTER_MODE_NODE_FILE cluster-index.js
optional PORT 8013
optional DRIVERCMD ${RESOURCE_DIR}/ab
optional DRIVERCMD_OPTIONS "--nograph"
optional DRIVERNO 25

NODE_SERVER=$(hostname -s)
echo -e "RESULTSDIR: $RESULTSDIR"
echo -e "RESULTSLOG: $RESULTSLOG"
echo -e "TIMEOUT: $TIMEOUT"
echo -e "NODE_SERVER: $NODE_SERVER"
echo -e "PORT: $PORT"
echo -e "NETWORKTYPE: $NETWORKTYPE"
echo -e "DRIVERCMD: $DRIVERCMD"
echo -e "DRIVERNO: $DRIVERNO\n"


DRIVER_COMMAND="$AB_AFFINITY ab"
# END VARIABLE SECTION

# Date stamp for result files generated by this run
CUR_DATE=$(timestamp)

PLATFORM=`/bin/uname | cut -f1 -d_`
echo -e "Platform identified as: ${PLATFORM}\n"

# Stop existing node processes if still running
stop_node_process

# Check if node executable exists
check_if_node_exists

# node execution command
NODE_APP_CMD="$NODE_AFFINITY ${NODE} ${NODE_FILE}"

# Get hugepage information
hugepages_stats

# Source footprint collection/calculation script
. ${SCRIPT_DIR}/fp.sh

# Start a mysql instance
start_mysql_server

# Start nodeapp server
start_nodeapp_server

# Get the memory footprint just before the run
pre=`getFootprint`
echo -n "Pre run Footprint in KB : $pre"

# Start the client driver command
# Start client
echo -n "\nStart of warming up the server with 1000 requests"
start_client 1000 /tmp/warmup-$TEST_NAME
echo -n "Benchmark start with 4000 requests"
(start_client 4000 $RESULTSLOG) &

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

