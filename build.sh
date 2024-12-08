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

    if [ "$1" = "column" ]; then
        result=$(sqlcmd -u -W -w 999 -h-1 -s"," -i input.sql | tr -d '\r')
        echo "$result" > file_from_db
    elif [ "$1" = "index" ]; then
        result=$(sqlcmd -u -W -w 999 -h-1 -s"," -i input.sql | tr -d '\r')
        echo "$result"  > current_index_in_db
        echo "$result"  | grep -oP '(\(.+\))WITH (\(.+\))' | sed -e 's/WITH/,/g' | sed -e 's/(//g' | sed -e 's/)//g' | tr ',' '\n' > file_from_db
    fi


}

get_table_index_info_from_db() {

    cat > input.sql << EOM
:setvar SQLCMDERRORLEVEL 1
USE DEV
GO
SET NOCOUNT ON
GO
SELECT
   CONCAT( 
   'CONSTRAINT ',
   QUOTENAME(i.name),
   ' ',
   'PRIMARY KEY',
   ' ',
   i.type_desc COLLATE DATABASE_DEFAULT,
   ' (  ',
   STRING_AGG(QUOTENAME(c.name) + ' ASC',','),
   ' )WITH (',
   'PAD_INDEX = ',
   case when i.is_padded = 1 then 'ON, ' else 'OFF, ' end,
   'STATISTICS_NORECOMPUTE = ',
   case is_padded when 1 then 'ON, ' else 'OFF, ' end,
   'IGNORE_DUP_KEY = ',
   case when ignore_dup_key = 1 then 'ON, ' else 'OFF, ' end,
   'ALLOW_ROW_LOCKS = ',
   case when allow_row_locks = 1 then 'ON, ' else 'OFF, ' end,
   'ALLOW_PAGE_LOCKS = ',
   case when allow_page_locks = 1 then 'ON, ' else 'OFF, ' end,
   'OPTIMIZE_FOR_SEQUENTIAL_KEY = ',
   case when optimize_for_sequential_key = 1 then 'ON, ' else 'OFF' end,
   ') ON [PRIMARY]'
   )
FROM
    sys.tables t
INNER JOIN 
    sys.indexes i ON t.object_id = i.object_id
INNER JOIN 
    sys.index_columns ic ON i.index_id = ic.index_id AND i.object_id = ic.object_id
INNER JOIN 
    sys.columns c ON ic.column_id = c.column_id AND ic.object_id = c.object_id
WHERE
    i.index_id = 1  -- clustered index
	and t.name = '$2'
group by i.name, t.schema_id, t.name, i.type_desc, i.is_padded, i.ignore_dup_key, 
i.allow_row_locks, i.allow_page_locks, i.optimize_for_sequential_key
GO
EOM

    call_sqlcmd "index"

}

get_table_column_info_from_db() {

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

    call_sqlcmd "column"

}

get_table_index_info_from_file() {

    result=$(sed -n '/CONSTRAINT/{/NONCLUSTERED/q; p; :loop n; p; /WITH/q; b loop}' "$1" | tr '\n' ' ' )
    echo "$result" | grep -oP -m 1 '(\[[a-zA-Z_]+\])' > index_name
    echo "$result" | grep -oP '(\(.+\))WITH (\(.+\))' | sed -e 's/WITH/,/g' | sed -e 's/(//g' | sed -e 's/)//g' | tr ',' '\n' > file_from_repo

}

get_table_column_info_from_file() {

    result=$(sed -e '/CREATE/,/GO/!d' "$1" | grep -e ',' | grep -v 'ASC,' | grep -v ')WITH' | sed -e 's/^\s*//')
    echo "$result" > file_from_repo

}

find_difference() {

    if [ -z ${1} ]; then
        result=$(diff file_from_db file_from_repo)
        echo "$result"
    elif [ "$1" = "ignore_space" ]; then
        result=$(diff -w file_from_db file_from_repo)
        echo "$result"
    fi

    rm file_from_db file_from_repo
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

    if [ "$4" = "column" ]; then
        ALTER_STATEMENT=$(echo "ALTER TABLE [$1].[$2]")
        echo "$ALTER_STATEMENT" >> database.sql 2>&1

        if [ "$diff_action" == "a" ]; then
            MODIFY_COLUMN=$(echo "ADD "$object_change)
            echo "$MODIFY_COLUMN" >> database.sql 2>&1
        elif [ "$diff_action" == "d" ]; then 
            IFS=' ' read -ra OBJECT <<< "$object_change"
            DROP_COLUMN=$(echo "${OBJECT[0]}")
            MODIFY_COLUMN=$(echo "DROP COLUMN "$DROP_COLUMN)
            echo "$MODIFY_COLUMN" >> database.sql 2>&1
        elif [ "$diff_action" == "c" ]; then
            # todo 
            echo "NOP"
        fi
    elif [ "$4" = "index" ]; then
        ALTER_STATEMENT=$(echo "ALTER TABLE [$1].[$2] DROP CONSTRAINT $5 WITH ( ONLINE = OFF )")
        echo "$ALTER_STATEMENT" >> database.sql 2>&1

        if [ "$diff_action" == "a" ]; then
            # todo 
            echo "NOP"
        elif [ "$diff_action" == "d" ]; then 
            CURRENT_INDEX=$(cat current_index_in_db)
            if [ $debug == 1 ]; then
                echo "current index in db: $CURRENT_INDEX"
            fi
            index_to_be_removed=$(echo "$object_change" | awk '{$1=$1};1' | sed 's/[][\/*.]/\\&/g; s%.*%,&%')
            if [ $debug == 1 ]; then
                echo "index_to_be_removed: $index_to_be_removed"
            fi
            MODIFY_INDEX=$(sed -e "s|${index_to_be_removed}||g" current_index_in_db )
            if [ $debug == 1 ]; then
                echo "modified index: $MODIFY_INDEX"
            fi
            echo "ALTER TABLE [$1].[$2] ADD $MODIFY_INDEX" >> database.sql 2>&1
        elif [ "$diff_action" == "c" ]; then
            # todo 
            echo "NOP"
        fi
    fi
        
    echo "GO" >> database.sql 2>&1

}


# mode can be full or delta
# debug can be 1 or 0
# example: ./build.sh -d 1 -m delta
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

rm -rf build
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
                echo "---------------------------------------------------------"
                echo "table: $object_name"
            fi

            # get table column info from db
            get_table_column_info_from_db "$object_schema" "$object_name"

            # then we get table column info from repo
            get_table_column_info_from_file "$file"

            # find the column difference
            diff_result=$(find_difference)

            if [ $debug == 1 ]; then
                echo "---------------------------------------------------------"
                echo "$diff_result"
            fi

            # generate alter column statement
            if [ -z "$diff_result" ]; then
                echo "No column difference"
            else
                diffs=$(echo "$diff_result" | paste -sd "," - | sed -e 's/<//g' | sed -e 's/>//g')
                echo "$diffs"
                generate_alter_statement $object_schema $object_name "$diffs" "column"
            fi
        
            # get table index info from db
            get_table_index_info_from_db "$object_schema" "$object_name"

            # then we get table index info from repo
            get_table_index_info_from_file "$file"

            # grab the index name
            index_name=$(cat index_name)
            if [ $debug == 1 ]; then
                echo "index: $index_name"
                echo "---------------------------------------------------------"
            fi

            # find the index difference
            diff_result=$(find_difference "ignore_space")

            if [ $debug == 1 ]; then
                echo "$diff_result"
                echo "---------------------------------------------------------"
            fi

            # generate alter index statement
            if [ -z "$diff_result" ]; then
                echo "No index difference"
            else
                diffs=$(echo "$diff_result" | paste -sd "," - | sed -e 's/<//g' | sed -e 's/>//g')
                echo "$diffs"
                generate_alter_statement $object_schema "$object_name" "$diffs" "index" $index_name
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
        cat $tmp >> database.sql 2>&1
    done
fi