#!/bin/bash 

if [ -z $1 ]; then
  echo -e "$0 <path to resource directory>"
  exit
fi

cd $1
wget https://yarnpkg.com/latest.tar.gz
tar zvxf latest.tar.gz

cp yarn-v1.3.2/bin/* $1/. 
