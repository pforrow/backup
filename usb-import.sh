#!/bin/bash

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "=== USB Emoncms import start ==="
date +"%Y-%m-%d-%T"
echo "Backup module version:"
cat $script_location/backup-module/module.json | grep version
echo "EUID: $EUID"
echo "Reading $script_location/config.cfg...."
if [ -f "$script_location/config.cfg" ]
then
    source "$script_location/config.cfg"
    echo "Location of data databases: $database_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of Emoncms: $emoncms_location"
else
    echo "ERROR: Backup $script_location/backup/config.cfg file does not exist"
    exit 1
fi

emonhub=$(systemctl show emonhub | grep LoadState | cut -d"=" -f2)
feedwriter=$(systemctl show feedwriter | grep LoadState | cut -d"=" -f2)
emoncms_mqtt=$(systemctl show emoncms_mqtt | grep LoadState | cut -d"=" -f2)

echo

disk=false
# Scan through disks to find 'usb-Generic_Mass-Storage'
for diskname in 'sda' 'sdb' 'sdc'
  do
  disk_id=$(find /dev/disk/by-id/ -lname "*$diskname")
  if [ $disk_id ]; then
      usb=$(ls $disk_id | grep 'usb-Generic-')
      if [ $usb ]; then
          echo "Found: $disk_id at /dev/$diskname"
          disk="$diskname"
      fi
      usb=$(ls $disk_id | grep 'usb-Mass_Storage_Device')
      if [ $usb ]; then
          echo "Found: $disk_id at /dev/$diskname"
          disk="$diskname"
      fi
  fi
done

if [ $disk != false ]; then
    # ---------------------------------------------------
    # Create mount points
    # ---------------------------------------------------
    if [ ! -d /media/old_sd_boot ]; then
        echo "creating mount point /media/old_sd_boot"
        sudo mkdir /media/old_sd_boot
    fi

    if [ ! -d /media/old_sd_root ]; then
        echo "creating mount point /media/old_sd_root"
        sudo mkdir /media/old_sd_root
    fi

    if [ ! -d /media/old_sd_data ]; then
        echo "creating mount point /media/old_sd_data"
        sudo mkdir /media/old_sd_data
    fi
    
    # ---------------------------------------------------
    # Mount partitions
    # ---------------------------------------------------
    echo "Mounting old SD card boot partition"
    sudo mount -r /dev/$disk'1' /media/old_sd_boot
    echo "Mounting old SD card root partition"
    sudo mount -r /dev/$disk'2' /media/old_sd_root
    echo "Mounting old SD card data partition"
    sudo mount -r /dev/$disk'3' /media/old_sd_data

    echo

    # ---------------------------------------------------
    # Stopping services
    # ---------------------------------------------------
    echo "Stopping services.."
    if [[ $emonhub == "loaded" ]]; then
        sudo service emonhub stop
    fi
    if [[ $feedwriter == "loaded" ]]; then
        sudo service feedwriter stop
    fi
    if [[ $emoncms_mqtt == "loaded" ]]; then
        sudo service emoncms_mqtt stop
    fi

    # ---------------------------------------------------------------
    # Mysql import (direct file copy method as we cant run mysqldump)
    # --------------------------------------------------------------- 
    echo "Read MYSQL authentication details from settings.php"
    if [ -f $script_location/get_emoncms_mysql_auth.php ]; then
        auth=$(echo $emoncms_location | php $script_location/get_emoncms_mysql_auth.php php)
        IFS=":" read username password database <<< "$auth"
    else
        echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
        echo "$PWD"
        exit 1
    fi
    
    echo "stopping mysql"
    sudo systemctl stop mariadb 
    
    if [ -d /var/lib/mysql/emoncms ]; then
        echo "Manually deleting old mysql emoncms database"
        sudo rm -rf /var/lib/mysql/emoncms
    fi
    
    echo "Manual install of emoncms database"
    
    # Old structure
    if sudo test -d "/media/old_sd_data/mysql/emoncms"; then
        sudo cp -rv /media/old_sd_data/mysql/emoncms /var/lib/mysql/emoncms
    # New structure
    elif sudo test -d "/media/old_sd_root/var/lib/mysql/emoncms"; then
        sudo cp -rv /media/old_sd_root/var/lib/mysql/emoncms /var/lib/mysql/emoncms
    else
        echo "could not find mysql database"
    fi
        
    echo "Setting database ownership"
    sudo chown mysql:mysql /var/lib/mysql/emoncms
    sudo chown -R mysql:mysql /var/lib/mysql/emoncms

    echo "starting mysql"
    sudo systemctl start mariadb    
    
    echo "checking database"
    mysqlcheck -A --auto-repair -u$username -p$password

    if [ -f /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php ]; then
        echo "Updating Emoncms Database.."
        php /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php
    fi

    # ---------------------------------------------------------------
    # Copy over phpfina files
    # --------------------------------------------------------------- 
    echo "Archive old data folders"
    sudo mv $database_path/phpfina $database_path/phpfina_old
    sudo mv $database_path/phptimeseries $database_path/phptimeseries_old
  
    echo "Copying PHPFina feed data"
    if sudo test -d "/media/old_sd_data/phpfina"; then
        sudo cp -rfv /media/old_sd_data/phpfina $database_path/phpfina
        sudo chown -R www-data:root $database_path/phpfina
    fi
    
    echo "Copying PHPTimeSeries feed data"
    if sudo test -d "/media/old_sd_data/phptimeseries"; then
        sudo cp -rfv /media/old_sd_data/phptimeseries $database_path/phptimeseries
        sudo chown -R www-data:root $database_path/phptimeseries
    fi
    # ---------------------------------------------------------------
    # Copy emonhub conf
    # ---------------------------------------------------------------
    # New structure
    if [ -f /media/old_sd_root/etc/emonhub/emonhub.conf ]; then
        sudo cp -fv /media/old_sd_root/etc/emonhub/emonhub.conf $emonhub_config_path/emonhub.conf
    fi
    # Old structure
    if [ -f /media/old_sd_data/emonhub.conf ]; then
        sudo cp -fv /media/old_sd_data/emonhub.conf $emonhub_config_path/emonhub.conf
    fi
    # ---------------------------------------------------------------
    # Clear redis and restart services
    # --------------------------------------------------------------- 
    echo "Flushing redis"
    redis-cli "flushall" 2>&1
    
    # Restart services
    if [[ $emonhub == "loaded" ]]; then
        echo "Restarting emonhub..."
        sudo service emonhub start
    fi
    if [[ $feedwriter == "loaded" ]]; then
        echo "Restarting feedwriter..."
        sudo service feedwriter start
    fi
    if [[ $emoncms_mqtt == "loaded" ]]; then
        echo "Restarting emoncms MQTT..."
        sudo service emoncms_mqtt start
    fi

    # ---------------------------------------------------
    # Unmount partitions
    # ---------------------------------------------------
    sudo umount /dev/$disk'1'
    sudo umount /dev/$disk'2'
    sudo umount /dev/$disk'3'
    
    date +"%Y-%m-%d-%T"
    # This string is identified in the interface to stop ongoing AJAX calls in logger window, please ammend in interface if changed here
    echo "=== Emoncms import complete! ==="
    sudo service apache2 restart
else
    echo "USB drive not found"
fi
