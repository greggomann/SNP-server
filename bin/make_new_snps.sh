#!/bin/sh

S3PASSWDFILE=/tmp/.passwd-s3fs
BUCKET=1001proteomes

if [ ! -e $S3PASSWDFILE ]; then
    read -p "Access Key Id: " accessKeyId 
    stty -echo 
    read -p "Secret Access Key: " secretAccessKey; echo 
    stty echo
    read -p "Bucket name: " BUCKET
    echo "$accessKeyId"":""$secretAccessKey" > $S3PASSWDFILE
    chmod 600 $S3PASSWDFILE
fi

export S3PASSWDFILE

bin/setup_s3fs.sh $BUCKET

#bin/snp_generator.sh

#sudo umount $HOME/mnt_s3