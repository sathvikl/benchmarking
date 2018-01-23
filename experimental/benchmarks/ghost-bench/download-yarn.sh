#!/bin/bash 

if [ -z $1 ]; then
  echo -e "$0 <path to resource directory>"
  exit
fi

if [[ -z $YARN_VERSION ]]; then
  export YARN_VERSION="v1.3.2"
else
  echo -e "Using Yarn version from YARN_VERSION: yarn-$YARN_VERSION"
fi

cd $1
wget https://github.com/yarnpkg/yarn/releases/download/$YARN_VERSION/yarn-$YARN_VERSION.tar.gz
tar xzf yarn-$YARN_VERSION.tar.gz
