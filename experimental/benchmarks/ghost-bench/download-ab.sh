#!/bin/bash  

if [ -z $1 ]; then
  echo -e "download-ab.sh <path to resource directory>"
  exit
fi

resource_dir=`readlink -f $1`

mkdir -p $resource_dir/apache2-utils/

pushd $resource_dir/apache2-utils/
wget http://archive.ubuntu.com/ubuntu/pool/main/a/apache2/apache2-utils_2.4.29-1ubuntu2_amd64.deb
ar -x  apache2-utils_2.4.29-1ubuntu2_amd64.deb 
tar xfJ data.tar.xz -C .
cp usr/bin/ab $resource_dir/.
popd 

rm -rf $resource_dir/apache2-utils/

