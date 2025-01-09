#!/bin/bash
#
# sample script to deploy code to a microsoft sql sever database
#

############################################################################################
# mode can be full or delta
# db is name of the db
# examples: 
# ./deploy.sh -m delta -d dev 
# ./deploy.sh -m full -d dev 
##########################################################################################

# main start here 
while getopts ":d:m:" opt; do
  case $opt in
    m) mode="$OPTARG"
    ;;
    d) database="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    exit 1
    ;;
  esac

  case $OPTARG in
    -*) echo "Option $opt needs a valid argument"
    exit 1
    ;;
  esac
done

if [ -z "$mode" ]; then
    printf "Missing mode parameter, exiting.."
    exit
elif [ -z "$database" ]; then
    printf "Missing database parameter, exiting.."
    exit
fi

if [ "$mode" = full ]; then
    sqlcmd -Q "drop database [$database]"
    sqlcmd -Q "create database [$database]"
fi

if [ -f "./build/database.sql" ] && [ -s "./build/database.sql" ]; then
    sqlcmd -d $database -i "./build/database.sql"
else
    printf "Missing ./build/database.sql file.."
fi