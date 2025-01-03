#!/bin/bash
#
# sample script to deploy code to a microsoft sql sever database
#
sqlcmd -Q "drop database [dev]"
sqlcmd -Q "create database [dev]"
sqlcmd -d dev -i "./build/database.sql"