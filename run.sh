echo "print the env var"
ls $WORKSPACE/flexy-artifacts/workdir/install-dir/ipfile.txt
private_ip_address=`cat $WORKSPACE/flexy-artifacts/workdir/install-dir/ipfile.txt`
echo "$private_ip_address"
echo -e "\033[1m$(date -u) ${@}\033[0m" >>result01.txt
./egress_2p.sh>result01.txt;sleep 5

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result02.txt
./egress_2p.sh $private_ip_address>>result02.txt;sleep 5

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result03.txt
./egress_2p.sh $private_ip_address>>result03.txt;sleep 5

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result04.txt
./egress_2p.sh $private_ip_address>>result04.txt

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result05.txt
./egress_2p.sh $private_ip_address>>result05.txt
