#!/bin/bash
#
# sample script to build a microsoft sql sever database
#
get_object_info_from_filename() {

    IFS='.' read -ra OBJECT <<< "$1"

    if [ "$2" == "schema" ]; then
        echo "${OBJECT[0]}"
    elif [ "$2" == "name" ]; then
        echo "${OBJECT[1]}"
    elif [ "$2" == "type" ]; then
        echo "${OBJECT[2]}"
    fi

}

call_sqlcmd() {

    result=$(sqlcmd -W -w 999 -h-1 -s"," -i input.sql)
    echo "$result"

}

get_table_info_from_db() {

    cat > input.sql << EOM
:setvar SQLCMDERRORLEVEL 1
USE DEV
GO
SET NOCOUNT ON
GO
SELECT 
   s.name as schema_name, 
   t.name as table_name, 
   c.name as column_name 
FROM sys.columns AS c
INNER JOIN sys.tables AS t ON t.object_id = c.object_id
INNER JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = '$1' and t.name = '$2'
GO
EOM

    call_sqlcmd

}

# param can be full or delta
echo "Received param $1"

mkdir build
cp dbo.*.sql build
cd build

for file in *.sql 
do
    if [ "$1" == "delta" ]; then

        # we find difference from repo vs actual db
        object_schema=$(get_object_info_from_filename "$file" "schema")
        object_name=$(get_object_info_from_filename "$file" "name")
        object_type=$(get_object_info_from_filename "$file" "type")
        
        # first we get table info from db
        if [ "$object_type" == "Table" ]; then
            result=$(get_table_info_from_db "$object_schema" "$object_name")
            echo "$result"
            # then we get table info from repo
            
            # find the difference

            # generate alter statement
        
        # then we get view info from db
            
            # find the difference

            # generate alter statement

        # then we get storedprocedure info from db
            
            # find the difference

            # generate alter statement

        fi

    elif [ "$1" == "full" ]; then

        # we force everything from repo
        if [[ $file == *"Table"* ]]; then
            cat "$file" >> table.tmp
        elif  [[ $file == *"View"* ]]; then
            cat "$file" >> view.tmp
        elif  [[ $file == *"StoredProcedure"* ]]; then
            cat "$file" >> sp.tmp
        fi

    fi
done

# we do this only for full build
if [ "$1" == "full" ]; then
    for tmp in table.tmp view.tmp sp.tmp
    do
        cat $tmp >> database.sql
    done
fi