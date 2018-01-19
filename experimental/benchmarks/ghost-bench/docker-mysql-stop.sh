#!/bin/bash

function stop_mysql_container() {
  sudo docker stop $1
  sudo docker rm -v $1 
}
