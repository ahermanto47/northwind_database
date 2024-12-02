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

call_sqlcmd_v2() {

    result=$(sqlcmd -u -W -w 999 -h-1 -s"," -i input.sql | tr -d '\r')
    echo "$result" > file1

}

get_table_info_from_db_v3() {

    cat > input.sql << EOM
:setvar SQLCMDERRORLEVEL 1
USE DEV
GO
SET NOCOUNT ON
GO
select 
   CONCAT(
   '[' , COLUMN_NAME, '] ',
   '[', DATA_TYPE, ']' ,
   case when DATA_TYPE in ('nvarchar','nchar') then CONCAT('(' , CHARACTER_MAXIMUM_LENGTH, ') ') else ' ' end,
   case when exists ( 
        select id from syscolumns
        where object_name(id)= '$2'
        and name=column_name
        and columnproperty(id,name,'IsIdentity') = 1 
   ) then
        'IDENTITY(' + 
        cast(ident_seed('$2') as varchar) + ',' + 
        cast(ident_incr('$2') as varchar) + ') '
   else '' end,
   case when IS_NULLABLE = 'YES' then 'NULL,' else 'NOT NULL,' end 
   )
from INFORMATION_SCHEMA.columns 
where TABLE_SCHEMA = '$1' AND TABLE_NAME = '$2'
GO
EOM

    call_sqlcmd_v2

}

get_table_info_from_file_v2() {

    result=$(sed -e '/CREATE/,/GO/!d' "$1" | grep -e ',' | grep -v 'ASC,' | grep -v ')WITH' | sed -e 's/^\s*//')
    echo "$result" > file2

}

find_difference_v2() {

    result=$(diff file1 file2)
    echo "$result"

}

generate_alter_statement() {

    IFS=',' read -ra OBJECT <<< "$3"
    diff_action_result="${OBJECT[0]}"
    object_change="${OBJECT[1]}"
    read diff_action <<< $(echo $diff_action_result | awk '{split($0, a, "[0-9]+"); print a[2]}')
    read db_line repo_line <<< $(echo $diff_action_result | awk '{split($0, a, "[^0-9]+"); print a[1], a[2]}')

    if [ $debug == 1 ]; then
        echo "$diff_action_result"
        echo "$object_change"
        echo "$diff_action"
        echo "$db_line"
        echo "$repo_line"
    fi

    ALTER_STATEMENT=$(echo "ALTER TABLE "$1.$2)
    echo "$ALTER_STATEMENT" >> database.sql

    if [ "$diff_action" == "a" ]; then
        MODIFY_COLUMN=$(echo "ADD "$object_change)
        echo "$MODIFY_COLUMN" >> database.sql
    elif [ "$diff_action" == "d" ]; then 
        IFS=' ' read -ra OBJECT <<< "$object_change"
        DROP_COLUMN=$(echo "${OBJECT[0]}")
        MODIFY_COLUMN=$(echo "DROP COLUMN "$DROP_COLUMN)
        echo "$MODIFY_COLUMN" >> database.sql
    elif [ "$diff_action" == "c" ]; then
        # todo 
        echo "NOP"
    fi
        
    echo "GO" >> database.sql

}


# mode can be full or delta
# debug can be 1 or 0
while getopts ":d:m:" opt; do
  case $opt in
    d) debug="$OPTARG"
    ;;
    m) mode="$OPTARG"
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

printf "Argument debug is %s\n" "$debug"
printf "Argument mode is %s\n" "$mode"

mkdir build
cp dbo.*.sql build
cd build

for file in *.sql 
do
    if [ "$mode" == "delta" ]; then

        # we find difference from repo vs actual db
        object_schema=$(get_object_info_from_filename "$file" "schema")
        object_name=$(get_object_info_from_filename "$file" "name")
        object_type=$(get_object_info_from_filename "$file" "type")
        
        # first we get table info from db
        if [ "$object_type" == "Table" ]; then

            if [ $debug == 1 ]; then
                echo "$object_name"
                echo "---------------------------------------------------------"
            fi

            # get table info from db
            get_table_info_from_db_v3 "$object_schema" "$object_name"

            # then we get table info from repo
            get_table_info_from_file_v2 "$file"

            # find the difference
            diff_result=$(find_difference_v2 $db_result $file_result)

            if [ $debug == 1 ]; then
                echo "$diff_result"
                echo "---------------------------------------------------------"
            fi

            # generate alter statement
            if [ -z "$diff_result" ]; then
                echo "No difference"
            else
                diffs=$(echo "$diff_result" | paste -sd "," - | sed -e 's/<//g' | sed -e 's/>//g')
                echo "$diffs"
                generate_alter_statement $object_schema $object_name "$diffs"
            fi
        
        # then we get view info from db
            
            # find the difference

            # generate alter statement

        # then we get storedprocedure info from db
            
            # find the difference

            # generate alter statement

        fi

    elif [ "$mode" == "full" ]; then

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
if [ "$mode" == "full" ]; then
    for tmp in table.tmp view.tmp sp.tmp
    do
        cat $tmp >> database.sql
    done
fi