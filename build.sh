#!/usr/bin/env bash
if [ $# -eq 0 ]
  then
    echo "Usage: ./build.sh <image-tag> <dockerfile to use>"
    echo "Example: ./build.sh apr22 Dockerfile_apt_install_gobgp"
    exit
fi
    
echo "cleaning up"
docker kill bgp1
docker kill bgp2
docker container prune
echo "exising images"
docker image prune
docker images
echo "existing containers"
docker ps -a
docker network rm bgp_network
echo "existing networks"
docker network ls
if [ $# -eq 0 ]
  then
    tag='latest'
    docker image rm gobgp:latest
    exit
  else
    tag=$1
    docker image rm gobgp:$tag
fi
sudo docker build -f $2 -t gobgp:$tag .
#docker run --sysctl net.ipv6.conf.all.disable_ipv6=0 -d --name  bgp1 -ti gobgp:$tag
#docker run --sysctl net.ipv6.conf.all.disable_ipv6=0 -d --name  bgp2 -ti gobgp:$tag
docker run --privileged -d --name  bgp1 -ti gobgp:$tag
docker run --privileged -d --name  bgp2 -ti gobgp:$tag
echo "current images"
docker images
echo "current containers"
docker ps -a
echo "creating docker network"
docker network create -d bridge bgp_network --ipv6 --subnet=2001::/64
echo "Connecting containers"
docker network connect bgp_network bgp1
docker network connect bgp_network bgp2
echo "fetching container ip addresses"
export bgp1IP=`docker container inspect -f '{{ .NetworkSettings.Networks.bgp_network.IPAddress }}' bgp1`
export bgp2IP=`docker container inspect -f '{{ .NetworkSettings.Networks.bgp_network.IPAddress }}' bgp2`
export bgp1IPV6=`docker container inspect -f '{{ .NetworkSettings.Networks.bgp_network.GlobalIPv6Address }}' bgp1`
export bgp2IPV6=`docker container inspect -f '{{ .NetworkSettings.Networks.bgp_network.GlobalIPv6Address }}' bgp2`
(envsubst < testnode1.conf) > bgp1.conf
(envsubst < testnode2.conf) > bgp2.conf
docker cp bgp1.conf bgp1:/opt/workspace/mygobgp/bgp1.conf
docker cp bgp2.conf bgp2:/opt/workspace/mygobgp/bgp2.conf
#docker exec -d bgp1 /bin/bash -c export bgp1IP=$bgp1IP
#docker exec -d bgp1 /bin/bash -c export bgp2IP=$bgp2IP
#docker exec -d bgp2 /bin/bash -c export bgp1IP=$bgp1IP
#docker exec -d bgp2 /bin/bash -c export bgp2IP=$bgp2IP
#docker exec -ti bgp1 echo "bgp1IP: $bgp1IP bgp2IP: $bgp2IP"
#docker exec -ti bgp2 echo "bgp1IP: $bgp1IP bgp2IP: $bgp2IP"
#docker exec -ti bgp1 bash -c "printf '[global.config]\n  as = 65001\n  router-id = \"$bgp1IP\"\n\n[[neighbors]]\n  [neighbors.config]\n    neighbor-address = \"$bgp2IP\"\n    peer-as = 65001\n    [neighbors.add-paths.config]\n      send-max = 8\n      receive = true\n  [neighbors.transport.config]\n     local-address = \"$bgp1IP\"\n' > /opt/workspace/mygobgp/bgp1.conf"
#docker exec -ti bgp2 bash -c "printf '[global.config]\n  as = 65001\n  router-id = \"$bgp2IP\"\n\n[[neighbors]]\n  [neighbors.config]\n    neighbor-address = \"$bgp1IP\"\n    peer-as = 65001\n    [neighbors.add-paths.config]\n      send-max = 8\n      receive = true\n  [neighbors.transport.config]\n     local-address = \"$bgp2IP\"\n' > /opt/workspace/mygobgp/bgp2.conf"
echo "wrote the config to bgp1"
docker exec -ti bgp1 cat /opt/workspace/mygobgp/bgp1.conf
echo "wrote the config to bgp2"
docker exec -ti bgp2 cat /opt/workspace/mygobgp/bgp2.conf
docker exec -d bgp1  gobgpd -l debug -f /opt/workspace/mygobgp/bgp1.conf
docker exec -d bgp2  gobgpd -l debug -f /opt/workspace/mygobgp/bgp2.conf
echo "gobgp daemon started"
echo "checking status of gobgp1"
docker exec -ti bgp1 gobgp global
docker exec -ti bgp1 gobgp neighbor
echo "checking status of gobgp2"
docker exec -ti bgp2 gobgp global
docker exec -ti bgp2 gobgp neighbor
echo "exec the following cmd  to attach - docker exec -ti bgp1/bgp2 bash"

