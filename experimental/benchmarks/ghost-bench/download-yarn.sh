#!/bin/bash 

if [ -z $1 ]; then
  echo -e "$0 <path to resource directory>"
  exit
fi

cd $1
wget https://github.com/yarnpkg/yarn/releases/download/v1.3.2/yarn-v1.3.2.tar.gz
tar xzf yarn-v1.3.2.tar.gz
