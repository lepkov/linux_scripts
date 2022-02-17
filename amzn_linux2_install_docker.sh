sudo yum -y install docker; \
sudo service docker start; \
sudo usermod -a -G docker ec2-user; \
sudo chkconfig docker on; \
sudo curl -L --fail https://raw.githubusercontent.com/linuxserver/docker-docker-compose/master/run.sh -o /usr/local/bin/docker-compose; \
sudo chmod +x /usr/local/bin/docker-compose; \
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose; \
sudo reboot;
