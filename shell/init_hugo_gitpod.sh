#!/bin/bash

# init_jdk8_gitpod.sh
# 2024-05-10
# by mengh
set -x

mkdir -p /home/gitpod/env

wget https://github.com/gohugoio/hugo/releases/download/v0.127.0/hugo_extended_0.127.0_linux-amd64.tar.gz -O /home/gitpod/env/hugo_extended_0.127.0_linux-amd64.tar.gz

cd /home/gitpod/env

tar -zxvf /home/gitpod/env/hugo_extended_0.127.0_linux-amd64.tar.gz

/home/gitpod/env/hugo version