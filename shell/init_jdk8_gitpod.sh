#!/bin/bash

# init_jdk8_gitpod.sh
# 2024-05-10
# by mengh
set -x

wget https://d6.injdk.cn/oraclejdk/8/jdk-8u381-linux-x64.tar.gz -O /home/gitpod/.sdkman/candidates/java/jdk-8u381-linux-x64.tar.gz

cd /home/gitpod/.sdkman/candidates/java

rm -rf /home/gitpod/.sdkman/candidates/java/jdk1.8.0_381

tar -zxvf /home/gitpod/.sdkman/candidates/java/jdk-8u381-linux-x64.tar.gz

rm /home/gitpod/.sdkman/candidates/java/current

ln -s /home/gitpod/.sdkman/candidates/java/jdk1.8.0_381 /home/gitpod/.sdkman/candidates/java/current