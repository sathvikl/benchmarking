#!/bin/bash
# add check to delete the container using the port
# add check for container run 
start_mysql_container() {
  local container_name=$1
  local mysql_dumpfile=$3 
  local cpu_assign=$2
  if [ -f $3 ] 
  then
    echo -e "MySQL in container instance will import mysqldump file $mysql_dumpfile\n"
  else
    echo 1; return 1;
  fi

  #check if there is already a container using the port or the name
  if [[ -n $(sudo docker ps | grep $container_name) ]]; then 
    echo -e "$container_name already exists, deleting the image\n"
    sudo docker stop $container_name; sudo docker rm -v $container_name;  
  fi 
  if [[ $(nc -z 127.0.0.1 3306; echo $?) -eq 0 ]]; then
    echo -e "Port 3306 is in use, cannot proceed from here."
    return 0
  fi
  
  sudo docker run --cpuset-cpus=$cpu_assign -p 3306:3306 --name=$container_name --env="MYSQL_ROOT_PASSWORD=testdb" -d mysql:5.7.21
  if [[ -n $(sudo docker ps | grep $container_name) ]]; then 
    echo -e "Docker: $container_name created..\n"  
  else
    return 0;
  fi 
  
  # wait for the container to start the mysql daemon, 
  # earlier versions of docker, take a lot longer to start
  echo -e "## wait for 60 seconds for the MySQL daemon within the container to start...\n" 
  sleep 20

  if [[ -n $(sudo docker ps | grep $container_name) ]]; then 
    echo -e "$container_name was started\n"
  else
    echo 1; return 1;
  fi 

  echo -e "## Creating the MySQL database: ghost_db in the container $container_name..\n"
  sudo docker exec -i $container_name bash -c 'cat > ghost_db.mysql' < $mysql_dumpfile 

  sudo docker exec  $container_name bash -c 'mysql -u root -ptestdb -e  "GRANT ALL PRIVILEGES ON *.* TO \"testuser\"@\"%\" IDENTIFIED BY \"testpass\""'
  sudo docker exec  $container_name bash -c 'mysql -u testuser -ptestpass -e "create database ghost_db"'

  sudo docker exec  $container_name bash -c 'mysql -u testuser -ptestpass ghost_db < ghost_db.mysql'
  return 0

}
