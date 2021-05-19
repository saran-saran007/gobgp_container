#!/usr/bin/env bash

nextip(){
    IP=$1
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}

configdut(){
	echo "Cleaning up old nbr config file"
	rm newnbr.conf
	rm full_config.conf
        IP=`ip addr show $2 | grep inet | head -n 1 | awk '{printf $2}' | awk -F/ '{print $1}'`
        NUM=$4
        for i in $(seq 1 $NUM); do
                export CIP=$IP
                (envsubst < nbr.conf) >> newnbr.conf
		echo "NEIGHBOR $i"
		cat newnbr.conf
		echo "==============="
                IP=$(nextip $IP)
        done
	sleep 1
	sed '/neighbors:/r newnbr.conf' running.conf > full_config.conf
	echo "copying running config to dut"
        scp full_config.conf cloud-user@$1:~/running.conf
	echo "Going to copy running config to routing-container"
	#ssh -l cloud-user $1 "kubectl cp running.conf  ngupf-routing-n0-0 /config/ngupf-routing/gobgpd.conf"
	ssh -l cloud-user $1 "kubectl cp running.conf ngupf-routing-n0-0:/opt/config/gobgpd.conf"
}

cleanup(){
	echo "cleaning up"
	NUM=$4
	for i in $(seq 1 $NUM); do
		docker kill bgp$i
	done
	sudo docker container prune
	echo "exising images"
	sudo docker image prune
	sudo docker images
	echo "existing containers"
	sudo docker ps -a
	sudo docker network rm bgp_network
	echo "existing networks"
	sudo docker network ls
	sudo docker image rm gobgp:latest
	ip addr show | grep ens224: | grep inet | awk '{print $2" "$(NF)}' > secIntfs
        echo "present secondary interfaces"
        cat secIntfs
        awk  '{ printf "sudo ip address del %s dev %s\n", $1, $2 }' secIntfs > delcmds
        echo "executing delete commands"
        cat delcmds
        while read cmd
        do
                `$cmd`
        done < delcmds
        rm secIntfs
        rm delcmds
}

#docker run --sysctl net.ipv6.conf.all.disable_ipv6=0 -d --name  bgp1 -ti gobgp:$tag
#docker run --sysctl net.ipv6.conf.all.disable_ipv6=0 -d --name  bgp2 -ti gobgp:$tag



createContainers(){
	# Create the N contianers
	NUM=$4
	IP=$EXPOSEC1IP
	for i in $(seq 1 $NUM); do
		echo "Creating containers with exposed ip:$IP"
		addridx=`expr $i + 1`
		docker run --privileged -d -p $IP:179:179 --name  bgp$i -ti gobgp:latest
		IP=$(nextip $IP)
		echo "Creating secondary ip:$IP on logical interface:$addridx"
		sudo ifconfig $2:$addridx $IP netmask 255.255.255.0 up
	done
}

showContainers(){
	#Show Build image and containers
	echo "current images"
	docker images
	echo "current containers"
	docker ps -a
}


setupContainers(){
	echo "creating docker network"
	sudo docker network create -d bridge bgp_network --ipv6 --subnet=2001::/64
	for i in $(seq 1 $NUM); do
		#echo "Connecting containers"
		sudo docker network connect bgp_network bgp$i
		#Set env variables required
		export CIP=`docker container inspect -f '{{ .NetworkSettings.Networks.bgp_network.IPAddress }}' bgp$i`
		export CIPV6=`docker container inspect -f '{{ .NetworkSettings.Networks.bgp_network.GlobalIPv6Address }}' bgp$i`
		echo "fetching container ip addresses $CIP $CIPV6"
		#Create container configs
		(envsubst < testnodeN.conf) > container.conf
		docker cp container.conf bgp$i:/opt/workspace/mygobgp/bgp$i.conf
		echo "wrote the config to bgp$i"
		docker exec -ti bgp$i cat /opt/workspace/mygobgp/bgp$i.conf
		docker exec -d bgp$i  bash -c "nohup gobgpd -l debug -f /opt/workspace/mygobgp/bgp$i.conf > /opt/workspace/mygobgp/bgp$i.log"
		echo "gobgp daemon started in  container#$i"
	done
}
monitorBgp(){
	echo "********************************"
	echo "exec the following cmd  to attach - docker exec -ti bgp<n> bash"
	echo "exec the following cmds  to view the logs:-"
	echo "docker exec -ti bgp1 tail -f /opt/workspace/mygobgp/bgp<n>.log"
	echo "********************************"
	echo "showing bgp neighbors"
        NUM=$4
        for i in $(seq 1 $NUM); do
		echo "==============="
		docker exec -ti bgp$i gobgp neighbor
        done
}

pumpRoutesFromContainer(){
	CONTAINER=$1
	NUMROUTES=$2
	IP="1.1.1.1"
	echo "pumping $NUMROUTES routes from container $CONTAINER"
        for i in $(seq 1 $NUMROUTES); do
		docker exec $CONTAINER gobgp global rib add $IP/32
                IP=$(nextip $IP)
	done
}

pumpRoutes(){
        NUMNBR=$4
        NUMROUTES=$5
	echo "pumping $NUMROUTES routes from each of the $NUMNBR neighbors to DUT"
        for i in $(seq 1 $NUMNBR); do
		pumpRoutesFromContainer bgp$i $NUMROUTES &
        done

}

#Run the script
if [ $# -ne 5 ]
  then
    echo "Usage: ./build.sh <DUT-MGMT-IP> <DUT linking interface> <BGP-Peer-ip> <num-of-containers/peers> <num routes>"
    echo "Example: ./build.sh  10.194.55.64 ens224 6.6.6.61 4 100"
    exit
fi
export DUTIP=$3
export NUMCONTAINER=$4
#Cleanup previous run
cleanup $1 $2 $3 $4
# Build the image
sudo docker build -f Dockerfile2 -t gobgp:latest .
#Set DUT and exposed container IP env variables
export EXPOSEC1IP=`ip addr show $2 | grep inet | head -n 1 | awk '{printf $2}' | awk -F/ '{print $1}'`
#Create the containers
createContainers $1 $2 $3 $4
#Show status
showContainers
#setup the containers and start gobgp
setupContainers
#Create and copy config to DUT
echo " copying config to DUT"
configdut $1 $2 $3 $4
#Check bgp peering status
monitorBgp $1 $2 $3 $4
#wait for 20 seconds for bgp sessions to come up
echo "waiting for 20 seconds for the bgp sessions to come up"
sleep 20
#Check bgp peering status
monitorBgp $1 $2 $3 $4
# pump routes
time pumpRoutes $1 $2 $3 $4 $5
wait
echo "Script completed execution"
