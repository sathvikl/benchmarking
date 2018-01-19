#!/bin/bash -x
# add check to delete the container using the port
# add check for container run 
function start_mysql_container() {
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
    
    sudo docker run --cpuset-cpus=$cpu_assign -p 3306:3306 --name=$container_name --env="MYSQL_ROOT_PASSWORD=testdb" -d mysql

    # wait for the container to start the mysql daemon, 
    # earlier versions of docker, take a lot longer to start
    sleep 60

    sudo docker exec -i $container_name bash -c 'cat > ghost_db.mysql' < $mysql_dumpfile 

    sudo docker exec  $container_name bash -c 'mysql -u root -ptestdb -e  "GRANT ALL PRIVILEGES ON *.* TO \"testuser\"@\"%\" IDENTIFIED BY \"testpass\""'
    sudo docker exec  $container_name bash -c 'mysql -u testuser -ptestpass -e "create database ghost_db"'

    sudo docker exec  $container_name bash -c 'mysql -u testuser -ptestpass ghost_db < ghost_db.mysql'
    return 0

}
