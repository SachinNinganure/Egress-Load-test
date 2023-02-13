echo -e "\033[1m$(date -u) ${@}\033[0m" >>result01.txt
./egress_2p.sh >>result01.txt;sleep 5

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result02.txt
./egress_2p.sh >>result02.txt;sleep 5

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result03.txt
./egress_2p.sh >>result03.txt;sleep 5

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result04.txt
./egress_2p.sh >>result04.txt

echo -e "\033[1m$(date -u) ${@}\033[0m" >>result05.txt
./egress_2p.sh >>result05.txt
