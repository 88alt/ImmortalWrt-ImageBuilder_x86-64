#!/bin/bash
# This shell script is executed inside the chroot
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until

echo Set hostname
echo "installer" > /etc/hostname

# Set as non-interactive so apt does not prompt for user input
export DEBIAN_FRONTEND=noninteractive

echo Install security updates and apt-utils
apt-get update
apt-get -y install apt || true
apt-get -y upgrade

echo Set locale
apt-get -y install locales
sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales
update-locale LANG=en_US.UTF-8

echo Install packages
apt-get install -y --no-install-recommends linux-image-amd64 live-boot systemd-sysv
apt-get install -y parted openssh-server bash-completion cifs-utils curl dbus dosfstools firmware-linux-free gddrescue gdisk iputils-ping isc-dhcp-client less nfs-common ntfs-3g openssh-client open-vm-tools procps vim wimtools wget

echo Clean apt post-install
apt-get clean

echo Enable systemd-networkd as network manager
systemctl enable systemd-networkd

echo Set resolv.conf to use systemd-resolved
rm /etc/resolv.conf
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
echo "PermitEmptyPasswords yes" >> /etc/ssh/sshd_config
echo "root:1234" | chpasswd
systemctl enable ssh

echo Remove machine-id
rm /etc/machine-id

echo List installed packages
dpkg --get-selections|tee /packages.txt
