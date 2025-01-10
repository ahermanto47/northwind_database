#!/bin/bash
#
# sample script to build a microsoft sql sever database
#

# global variables start here 
declare -A table_files_dependencies_map=()
processed_tables=()
phase_0_tables=()
phase_1_tables=()
phase_2_tables=()
declare -A view_files_dependencies_map=()
processed_views=()
phase_0_views=()
phase_1_views=()
phase_2_views=()

# functions start here 
log() {
    #$1 is the message
    timestamp=$(date -u +%T)
    if [ $debug = 1 ]; then
        echo "($timestamp):(${FUNCNAME[1]}): $1"
    fi
}

get_object_info_from_filename() {

    IFS='.' read -ra OBJECT <<< "$1"

    if [ "$2" = "schema" ]; then
        echo "${OBJECT[0]}"
    elif [ "$2" = "name" ]; then
        echo "${OBJECT[1]}"
    elif [ "$2" = "type" ]; then
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
    elif [ "$1" = "definition" ]; then
        result=$(sqlcmd -u -y 8000 -h-1 -i input.sql | sed '/^[[:space:]]*$/d')
        echo "$result"  > file_from_db
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

get_stored_procedure_definition_from_db() {

    cat > input.sql << EOM
:setvar SQLCMDERRORLEVEL 1
USE DEV
GO
SET NOCOUNT ON
GO
select 
   ROUTINE_DEFINITION 
from INFORMATION_SCHEMA.ROUTINES 
where ROUTINE_SCHEMA = '$1'
AND ROUTINE_NAME = '$2'
GO
EOM

    call_sqlcmd "definition"

}

get_view_definition_from_db() {


    cat > input.sql << EOM
:setvar SQLCMDERRORLEVEL 1
USE DEV
GO
SET NOCOUNT ON
GO
select 
   VIEW_DEFINITION 
from INFORMATION_SCHEMA.VIEWS 
where TABLE_SCHEMA = '$1'
AND TABLE_NAME = '$2'
GO
EOM

    call_sqlcmd "definition"

}

write_drop_statement() {

    case "$4" in
        "Table") 
        in_object_type="table"
        in_object_flag=3
        ;;
        "View") 
        in_object_type="view"
        in_object_flag=2
        ;;
        "StoredProcedure") 
        in_object_type="procedure"
        in_object_flag=4
        ;;
    esac

    cat >> "$1" << EOM
if exists (select * from sysobjects where id = object_id('$2.$3') and sysstat & 0xf = $in_object_flag)
	drop $in_object_type "$2"."$3"
GO
EOM

}

get_definition_from_file() {

    result=$(sed -e '/CREATE/,/GO/!d' "$1" | sed -e 's/GO//g' | sed '/^[[:space:]]*$/d')
    if [ "$2" = "repo" ]; then
        echo "$result" > file_from_repo
    elif [ "$2" = "dir" ]; then
        echo "$result" > file_from_db
    fi    
}

get_table_index_info_from_file() {

    result=$(sed -n '/CONSTRAINT/{/NONCLUSTERED/q; p; :loop n; p; /WITH/q; b loop}' "$1" | tr '\n' ' ' )
    echo "$result" | grep -oP -m 1 '(\[[a-zA-Z_]+\])' > index_name
    if [ "$2" = "repo" ]; then
        echo "$result" | grep -oP '(\(.+\))WITH (\(.+\))' | sed -e 's/WITH/,/g' | sed -e 's/(//g' | sed -e 's/)//g' | tr ',' '\n' > file_from_repo
    elif [ "$2" = "dir" ]; then
        echo "$result" | grep -oP '(\(.+\))WITH (\(.+\))' | sed -e 's/WITH/,/g' | sed -e 's/(//g' | sed -e 's/)//g' | tr ',' '\n' > file_from_db
    fi

}

get_table_column_info_from_file() {


    result=$(sed -e '/CREATE/,/GO/!d' "$1" | grep -e ',' | grep -v 'ASC,' | grep -v ')WITH' | sed -e 's/^\s*//')
    # result=$(sed -n '/CREATE/{p; :loop n; p; /CONSTRAINT/q; b loop}' "$1" | sed '1d;$d'| sed -e 's/^\s*//')
    if [ "$2" = "repo" ]; then
        echo "$result" > file_from_repo
    elif [ "$2" = "dir" ]; then
        echo "$result" > file_from_db
    fi

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

    if [ "$4" = "definition" ]; then
        sed -e 's/CREATE/ALTER/g' "$5" >> database.sql
    else

        IFS=',' read -ra OBJECT <<< "$3"
        diff_action_result="${OBJECT[0]}"
        object_change="${OBJECT[1]}"
        read diff_action <<< $(echo $diff_action_result | awk '{split($0, a, "[0-9]+"); print a[2]}')
        read db_line repo_line <<< $(echo $diff_action_result | awk '{split($0, a, "[^0-9]+"); print a[1], a[2]}')

        if [ $debug = 1 ]; then
            echo "$diff_action_result"
            echo "$object_change"
            echo "$diff_action"
            echo "$db_line"
            echo "$repo_line"
        fi

        if [ "$4" = "column" ]; then
            ALTER_STATEMENT=$(echo "ALTER TABLE [$1].[$2]")
            echo "$ALTER_STATEMENT" >> database.sql 2>&1

            if [ "$diff_action" = "a" ]; then
                MODIFY_COLUMN=$(echo "ADD "$object_change)
                echo "$MODIFY_COLUMN" >> database.sql 2>&1
            elif [ "$diff_action" = "d" ]; then 
                IFS=' ' read -ra OBJECT <<< "$object_change"
                DROP_COLUMN=$(echo "${OBJECT[0]}")
                MODIFY_COLUMN=$(echo "DROP COLUMN "$DROP_COLUMN)
                echo "$MODIFY_COLUMN" >> database.sql 2>&1
            elif [ "$diff_action" = "c" ]; then
                # todo 
                echo "NOP"
            fi
        elif [ "$4" = "index" ]; then
            ALTER_STATEMENT=$(echo "ALTER TABLE [$1].[$2] DROP CONSTRAINT $5 WITH ( ONLINE = OFF )")
            echo "$ALTER_STATEMENT" >> database.sql 2>&1
            echo "GO" >> database.sql 2>&1

            if [ "$diff_action" = "a" ]; then
                # todo 
                echo "NOP"
            elif [ "$diff_action" = "d" ]; then 
                CURRENT_INDEX=$(cat current_index_in_db)
                log "current index in db: $CURRENT_INDEX"
                index_to_be_removed=$(echo "$object_change" | awk '{$1=$1};1' | sed 's/[][\/*.]/\\&/g; s%.*%,&%')
                log "index_to_be_removed: $index_to_be_removed"
                MODIFY_INDEX=$(sed -e "s|${index_to_be_removed}||g" current_index_in_db )
                log "modified index: $MODIFY_INDEX"
                echo "ALTER TABLE [$1].[$2] ADD $MODIFY_INDEX" >> database.sql 2>&1
            elif [ "$diff_action" = "c" ]; then
                # todo 
                echo "NOP"
            fi
        fi

        echo "GO" >> database.sql 2>&1
        
    fi

}

write_table_file() {

    log "Caller - ${FUNCNAME[1]}"
    log "Processing table file - [$1]"

    if [[ ${processed_tables[@]} =~ $1 ]]; then
        log "$1 is already processed"
    else
        log "writing file $1"
        cat "$1" >> table.tmp
        processed_tables+=("$1")
    fi

}

write_view_file() {

    log "Caller - ${FUNCNAME[1]}"
    log "Processing view file - [$1]"

    if [[ ${processed_views[@]} =~ $1 ]]; then
        log "$1 is already processed"
    else
        log "writing file $1"
        cat "$1" >> view.tmp
        processed_views+=("$1")
    fi

}

map_file_dependencies() {

    input_object_type="table"
    if [ "$2" = "view" ]; then
        input_object_type="view"
    fi
    log "Mapping dependencies for $input_object_type file - [$1]"
    
    file_dependencies=()

    REFERENCE_SEARCH_TERM="REFERENCES"
    if [ "$2" = "view" ]; then
        input_object_name=$(get_object_info_from_filename "$file" "name")
        REFERENCE_SEARCH_TERM="$input_object_name"
        dependencies2=$(grep -e "$REFERENCE_SEARCH_TERM" *.View.sql | grep FROM | awk -F":" '{print $1}')
    else
        dependencies2=$(grep -e "$REFERENCE_SEARCH_TERM" "$1" | awk '{print $2}')
    fi

    if [[ -z $dependencies2 ]]; then
        log "$1 has no dependencies"

        if [ "$2" = "table" ]; then
            phase_0_tables+=("$1")
        else
            phase_0_views+=("$1")
        fi

    else
        # Save current IFS (Internal Field Separator)
        SAVEIFS=$IFS
        # Change IFS to newline char
        IFS=$'\n'
        # split the value string into an array by the same name
        dependency_names=($dependencies2)
        # Reset IFS to before
        IFS=$SAVEIFS
        
        log "dependency_names - ${dependency_names[*]}"

        for (( l=0; l<${#dependency_names[@]}; l++ ))
        do
            if [ "$2" = "view" ]; then
                if [ "${dependency_names[$i]}" = "$1" ]; then
                    log "Skipping dependency to itself - $i: ${dependency_names[$l]}"
                    continue
                fi

                file_dependencies+=("${dependency_names[$l]}")    
            else
                object_schema=$(get_object_info_from_filename "$1" "schema")
                object_name=$(get_object_info_from_filename "$1" "name")

                if [ ${dependency_names[$l]} = "[$object_schema].[$object_name]" ]; then
                    log "Skipping dependency to itself - $l: ${dependency_names[$l]}"
                    phase_0_tables+=("$1")
                    continue
                fi

                tmp_file_from_name=$(echo "${dependency_names[$l]}" | sed 's/[][]//g')
                file_from_name=$(echo "$tmp_file_from_name.Table.sql")

                file_dependencies+=("$file_from_name")
            fi

        done

        str_file_dependencies=$(IFS=, ; echo "${file_dependencies[*]}")

        if [ ! -z "$str_file_dependencies" ]; then
            log "Joined dependencies - [$str_file_dependencies]"

            if [ "$2" = "view" ]; then
                view_files_dependencies_map+=(["$1"]="$str_file_dependencies")                
            else
                table_files_dependencies_map+=(["$1"]="$str_file_dependencies")
            fi
        fi
    fi

}

write_map_key_files() {

    log "Writing map key file and its dependencies - [$1]"

    if [ "$2" = "table" ]; then
        str_table_files_3=${table_files_dependencies_map[$1]}
        # Save current IFS (Internal Field Separator)
        SAVEIFS=$IFS
        # Change IFS to newline char
        IFS=$','
        # split the value string into an array by the same name
        table_files_3=($str_table_files_3)
        # Reset IFS to before
        IFS=$SAVEIFS

        for (( j=0; j<${#table_files_3[@]}; j++ ))
        do
            log "Calling write_table_file - ${table_files_3[$j]}" 
            write_table_file "${table_files_3[$j]}"
        done

        log "Calling write_table_file - $1" 
        write_table_file "$1"
    
    else
        str_view_files_3=${view_files_dependencies_map[$1]}
        # Save current IFS (Internal Field Separator)
        SAVEIFS=$IFS
        # Change IFS to newline char
        IFS=$','
        # split the value string into an array by the same name
        view_files_3=($str_view_files_3)
        # Reset IFS to before
        IFS=$SAVEIFS

        log "Calling write_view_file - $1" 
        write_view_file "$1"

        for (( k=0; k<${#view_files_3[@]}; k++ ))
        do
            log "Calling write_view_file - ${view_files_3[$k]}" 
            write_view_file "${view_files_3[$k]}"
        done

    fi

}

is_object_exist_in_target() {

    # if we file is empty then its new object, otherwise its an existing object
    if [[ -z $(grep '[^[:space:]]' file_from_db) ]] ; then
        echo 0 
    else
        echo 1
    fi

}

############################################################################################
# mode can be full or delta
# debug can be 1 or 0
# target can be db or dir
# source is the full path when target is dir
# examples: 
# ./build.sh -d 1 -m delta -t dir -s /c/users/dowload/export_db
# ./build.sh -d 1 -m delta -t db
############################################################################################

# main start here 
while getopts ":d:m:t:s:" opt; do
  case $opt in
    d) debug="$OPTARG"
    ;;
    m) mode="$OPTARG"
    ;;
    t) target="$OPTARG"
    ;;
    s) source="$OPTARG"
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
elif [ -z "$target" ] && [ "$mode" = "delta" ]; then
    printf "Missing target parameter for delta mode, exiting.."
    exit
fi

printf "Argument debug is %s\n" "$debug"
printf "Argument mode is %s\n" "$mode"
printf "Argument target is %s\n" "$target"
printf "Argument source is %s\n" "$source"

rm -rf build
mkdir build
cp dbo.*.sql build
cd build
dos2unix dbo.*.sql

for file in *.sql 
do
    # get object info from the filename
    object_schema=$(get_object_info_from_filename "$file" "schema")
    object_name=$(get_object_info_from_filename "$file" "name")
    object_type=$(get_object_info_from_filename "$file" "type")

    if [ "$mode" = "delta" ]; then
        # we look for differences from repo vs target

        # initialize
        echo "SET NOCOUNT ON" >> database.sql 2>&1
        echo "GO"  >> database.sql 2>&1

        # first we get table info
        if [ "$object_type" = "Table" ]; then

            log "---------------------------------------------------------------------------------------------------"
            log "table: $object_name"

            if [ "$target" = "db" ]; then 
                # get table column info from db
                get_table_column_info_from_db "$object_schema" "$object_name"
            elif [ "$target" = "dir" ]; then
                # then we get table column info from target directory
                get_table_column_info_from_file "$source$file" "dir"
            fi

            is_table_update=$(is_object_exist_in_target)

            log "is_table_update - $is_table_update"

            if [ $is_table_update -eq 0 ]; then
                # this is a new object, just write the whole table file
                cat "$file" >> database.sql
                # then skip the rest of table logic
                continue
            fi

            # then we get table column info from repo
            get_table_column_info_from_file "$file" "repo"

            # find the column difference
            diff_result=$(find_difference)

            log "diff_result - $diff_result"

            # generate alter column statement
            if [ -z "$diff_result" ]; then
                log "No column difference"
            else
                diffs=$(echo "$diff_result" | paste -sd "," - | sed -e 's/<//g' | sed -e 's/>//g')
                log "diffs - $diffs"
                generate_alter_statement $object_schema $object_name "$diffs" "column"
            fi
        

            if [ "$target" = "db" ]; then 
                # get table index info from db
                get_table_index_info_from_db "$object_schema" "$object_name"
            elif [ "$target" = "dir" ]; then
                # then we get table index info from target directory
                dos2unix "$source$file"
                get_table_index_info_from_file "$source$file" "dir"
            fi

            # then we get table index info from repo
            get_table_index_info_from_file "$file" "repo"

            # grab the index name
            index_name=$(cat index_name)
            log "index: $index_name"

            # find the index difference
            diff_result=$(find_difference "ignore_space")

            log "diff_result - $diff_result"

            # generate alter index statement
            if [ -z "$diff_result" ]; then
                log "No index difference"
            else
                diffs=$(echo "$diff_result" | paste -sd "," - | sed -e 's/<//g' | sed -e 's/>//g')
                log "diffs - $diffs"
                generate_alter_statement $object_schema "$object_name" "$diffs" "index" $index_name
            fi

            #break
        
        # then we get view info from db
        elif [ "$object_type" = "View" ]; then
            log "---------------------------------------------------------------------------------------------------"
            log "view: $object_name"
            
            if [ "$target" = "db" ]; then 
                # get view info from db
                get_view_definition_from_db "$object_schema" "$object_name"
            elif [ "$target" = "dir" ]; then
                # then we get view info from target directory
                dos2unix "$source$file"
                get_definition_from_file "$source$file" "dir" 
            fi

            is_view_update=$(is_object_exist_in_target)

            log "is_view_update - $is_view_update"

            get_definition_from_file "$file" "repo"

            # find the difference
            diff_result=$(find_difference "ignore_space")

            log "diff_result - $diff_result"

            # generate alter statement
            if [ -z "$diff_result" ]; then
                log "No definition difference"
            else
                if [ $is_view_update -eq 1 ]; then
                    # existing object, so update it using sql ALTER
                    generate_alter_statement $object_schema "$object_name" "$diffs" "definition" "$file"
                else
                    # this is a new object, proceed write the whole file
                    cat "$file" >> database.sql
                fi
            fi
 
        # then we get storedprocedure info from db
        elif [ "$object_type" = "StoredProcedure" ]; then
            log "---------------------------------------------------------------------------------------------------"
            log "storedprocedure: $object_name"

            if [ "$target" = "db" ]; then 
                # get storedprocedure info from db
                get_stored_procedure_definition_from_db "$object_schema" "$object_name"
            elif [ "$target" = "dir" ]; then
                # then we get storedprocedure info from target directory
                dos2unix "$source$file"
                get_definition_from_file "$file" "dir"
            fi            

            is_sp_update=$(is_object_exist_in_target)

            log "is_sp_update - $is_sp_update"

            get_definition_from_file "$file" "repo"

            # find the difference
            diff_result=$(find_difference "ignore_space")

            log "diff_result - $diff_result"

            # generate alter statement
            if [ -z "$diff_result" ]; then
                log "No definition difference"
            else
                if [ $is_sp_update -eq 1 ]; then
                    # existing object, so update it using sql ALTER
                    generate_alter_statement $object_schema "$object_name" "$diffs" "definition" "$file"
                else
                    # this is a new object, proceed write the whole file
                    cat "$file" >> database.sql
                fi
            fi

        fi

    elif [ "$mode" = "full" ]; then

        # we force everything from repo
        if [[ $file = *"Table"* ]]; then

            # for tables we map their dependencies here
            log "---------------------------------------------------------------------------------------------------"
            log "Processing table file - [$file]"

            write_drop_statement "drop_table.tmp" "$object_schema" "$object_name" "$object_type"
            map_file_dependencies "$file" "table"

        elif  [[ $file = *"View"* ]]; then
            # view also require dependency processing
            log "---------------------------------------------------------------------------------------------------"
            log "Processing view file - [$file]"

            write_drop_statement "drop_view.tmp" "$object_schema" "$object_name" "$object_type"
            map_file_dependencies "$file" "view"

        elif  [[ $file = *"StoredProcedure"* ]]; then
            write_drop_statement "drop_sp.tmp" "$object_schema" "$object_name" "$object_type"
            cat "$file" >> sp.tmp
        fi

    fi

done

# we do this only for full build
if [ "$mode" = "full" ]; then

    # iterate through the table dependency map, write table with multi dependencies last
    for table_file in "${!table_files_dependencies_map[@]}"
    do
        log "---------------------------------------------------------------------------------------------------"
        log "Processing table file - [$table_file]"
        log "Dependencies for table file - $table_file: ${table_files_dependencies_map[$table_file]}"

        str_table_files=${table_files_dependencies_map[$table_file]}
        # Save current IFS (Internal Field Separator)
        SAVEIFS=$IFS
        # Change IFS to newline char
        IFS=$','
        # split the value string into an array by the same name
        table_files_2=($str_table_files)
        # Reset IFS to before
        IFS=$SAVEIFS

        phase=1

        for (( i=0; i<${#table_files_2[@]}; i++ ))
        do
            str_map_keys=$(echo "${!table_files_dependencies_map[@]}")

            if [[ "$str_map_keys" = *"${table_files_2[$i]}"* ]]; then
                # this table has multi dependency put it on second phase
                log "$table_file depends on map key ${table_files_2[$i]}"
                phase=2
                phase_2_tables+=("$table_file")
                break
            fi
        done

        if [ $phase -eq 1 ]; then
             phase_1_tables+=("$table_file")
        fi

    done

    # write tables with no dependencies
    log "Phase 0 tables - [${phase_0_tables[*]}]"
    for (( i=0; i<${#phase_0_tables[@]}; i++ ))
    do
        log "Phase 0 processing table file - [${phase_0_tables[$i]}]"
        write_table_file "${phase_0_tables[$i]}"
    done

    # write tables with simple dependencies
    log "Phase 1 tables - [${phase_1_tables[*]}]"
    for (( i=0; i<${#phase_1_tables[@]}; i++ ))
    do
        log "Phase 1 processing map key table file - [${phase_1_tables[$i]}]"
        write_map_key_files "${phase_1_tables[$i]}" "table"
    done

    # write tables with multi level dependencies
    log "Phase 2 tables - [${phase_2_tables[*]}]"
    for (( i=0; i<${#phase_2_tables[@]}; i++ ))
    do
        log "Phase 2 processing map key table file - [${phase_2_tables[$i]}]"
        write_map_key_files "${phase_2_tables[$i]}" "table"
    done
    
    # iterate through the view dependency map, write view with multi dependencies last
    for view_file in "${!view_files_dependencies_map[@]}"
    do
        log "---------------------------------------------------------------------------------------------------"
        log "Processing view file - [$view_file]"
        log "Dependencies for view file - $view_file: ${view_files_dependencies_map[$view_file]}"

        str_view_files=${view_files_dependencies_map[$view_file]}
        # Save current IFS (Internal Field Separator)
        SAVEIFS=$IFS
        # Change IFS to newline char
        IFS=$','
        # split the value string into an array by the same name
        view_files_2=($str_view_files)
        # Reset IFS to before
        IFS=$SAVEIFS

        phase=1

        for (( i=0; i<${#view_files_2[@]}; i++ ))
        do
            str_map_keys=$(echo "${!view_files_dependencies_map[@]}")

            if [[ "$str_map_keys" = *"${view_files_2[$i]}"* ]]; then
                # this view has multi dependency put it on second phase
                log "$view_file depends on map key ${view_files_2[$i]}"
                phase=2
                phase_2_views+=("$view_file")
                continue
            fi
            
        done

        if [ $phase -eq 1 ]; then
             phase_1_views+=("$view_file")
        fi

    done

    # write views with multi level dependencies
    log "Phase 2 views - [${phase_2_views[*]}]"
    for (( i=0; i<${#phase_2_views[@]}; i++ ))
    do
        log "Phase 2 processing map key view file - [${phase_2_views[$i]}]"
        write_map_key_files "${phase_2_views[$i]}" "view"
    done

    # write views with simple dependencies
    log "Phase 1 views - [${phase_1_views[*]}]"
    for (( i=0; i<${#phase_1_views[@]}; i++ ))
    do
        log "Phase 1 processing map key view file - [${phase_1_views[$i]}]"
        write_map_key_files "${phase_1_views[$i]}" "view"
    done

    # write views with no dependencies
    log "Phase 0 views - [${phase_0_views[*]}]"
    for (( i=0; i<${#phase_0_views[@]}; i++ ))
    do
        log "Phase 0 processing map key view file - [${phase_0_views[$i]}]"
        write_map_key_files "${phase_0_views[$i]}" "view"
    done
        
    # write everything
    
    # initialize
    echo "SET NOCOUNT ON" >> database.sql 2>&1
    echo "GO" >> database.sql 2>&1
    echo "SET QUOTED_IDENTIFIER ON" >> database.sql 2>&1 
    echo "GO" >> database.sql 2>&1

    for tmp in drop_sp.tmp drop_view.tmp drop_table.tmp table.tmp view.tmp sp.tmp
    do
        cat $tmp >> database.sql 2>&1
    done
fi

# cleanup
if [ "$mode" = "full" ]; then
    rm dbo.*.sql *.tmp
else
    rm dbo.*.sql current_index_in_db index_name input.sql
fi