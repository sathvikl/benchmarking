#!/bin/bash
if ! [ -f $1 ]; then
  echo "Not a file"
  exit
fi
fileOrig=$1
file=$1
log=$2
sed '/done/q' $file >${file}.tmp
cat ${file}.tmp | grep -v "top"|grep -v procs > ${file}
idle_values=`cat $file|grep 'Cpu(s)' | sed 's/,/\r\n/g'|grep "id"|sed 's/[%id ]*//g'`
node_values=`cat $file|grep 'node' | awk {'print $9'}`
mysql_values=`cat $file|grep 'mysql' | awk {'print $9'}`
ab_values=`cat $file|grep 'ab' | awk {'print $9'}`
# Since i = 3, it will work only for longer running workloads.
idle_time=`echo $idle_values|awk 'BEGIN { sum=0 ; count=0} {for(i = 3; i <= NF; i++) {sum=sum+$i; count=count+1 }} END {print sum/count}'`
node_percentage=`echo $node_values|awk  'BEGIN { sum=0 ; count=0} {for(i = 3; i <= NF; i++) {sum=sum+$i; count=count+1 }} END {print sum/count}'`
ab_percentage=`echo $ab_values|awk  'BEGIN { sum=0 ; count=0} {for(i = 3; i <= NF; i++) {sum=sum+$i; count=count+1 }} END {print sum/count}'`
mysql_percentage=`echo $mysql_values|awk  'BEGIN { sum=0 ; count=0} {for(i = 3; i <= NF; i++) {sum=sum+$i; count=count+1 }} END {print sum/count}'`

cpu_usage=`echo "100-$idle_time"|bc`
echo "$log utilization $cpu_usage %"
echo "node utilization $node_percentage %"
echo "MySQL utilization $mysql_percentage %"
echo "Apache ab client driver utilization $ab_percentage %"
rm ${1}.tmp
