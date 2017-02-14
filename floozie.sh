#!/usr/bin/env bash

#------------------------------------------------------------------------------
# FUNCTIONS
#------------------------------------------------------------------------------

# function: show_help
function show_help () {
  cat << EOF
  Usage: $0 -w 'workflow_dir'

    -w workflow_dir     directory containing oozie workflows for processing.
                        directory provided should be in th«e following format:
                          provider/database/classification/catalog/schema
                        provider, database, classification, catalog and schema
                          variables are reversed from workflow_dir path.
    -h help             help documentation

EOF
}

function is_workflow () {
  if [[ ${obj} =~ (.*)\/workflow.xml$ ]]; then
    return 0;
  else
    return 1;
  fi
}

#------------------------------------------------------------------------------
# ARGUEMENTS
#------------------------------------------------------------------------------

while getopts :n:w:h FLAG; do
  case $FLAG in
    w)  #set option "w"
      workflow_dir=$OPTARG;
      ;;
    h|help)  #show help
      show_help;
      exit 0;
      ;;
  esac
done

shift $((OPTIND-1))  #This tells getopts to move on to the next argument.

# verify arguements have been set
if [ -z ${workflow_dir} ]; then
  echo "==> ERROR: Please specify the 'workflow_dir' arguement. Aborting script.";
  echo "==> Run '$0 -help' for additional info.";
  exit 1;
fi

#------------------------------------------------------------------------------
# VARIABLES
#------------------------------------------------------------------------------

SCRIPTPATH=`dirname "${BASH_SOURCE[0]}"`;
configs_dir="${SCRIPTPATH}/configs";
properties_dir="${SCRIPTPATH}/properties";
reports_dir="${SCRIPTPATH}/reports";
templates_dir="${SCRIPTPATH}/templates"
color="teal"


#------------------------------------------------------------------------------
# MAIN
#------------------------------------------------------------------------------

# get hadoop cluster info
namenode=`hdfs getconf -confkey dfs.nameservices`
jobtracker=`hdfs getconf -confKey yarn.resourcemanager.address`

# get hdfs workflow list
for obj in `grep -P '^(?!(Found\s([0-9]*)\sitems))' <(hadoop fs -ls -R ${workflow_dir}) | awk '{ print $NF }'`; do
  if is_workflow ${obj}; then

    # notify
    echo "==> Workflow file found: ${obj}"

    # set timestamps
    month=`date "+%m"`;
    day=`date "+%d"`;
    year=`date "+%Y"`;

    # reverse vars from obj path
    IFS='/' read -r -a path <<< "${obj}"
    if [ ${#path[@]} -ge 6 ]; then
      if [[ "${path[${#path[@]}-6]}" == "mdr" && "${path[${#path[@]}-5]}" == "standard" ]]; then
        provider="${path[${#path[@]}-7]}";
        database="${path[${#path[@]}-6]}";
        classification="${path[${#path[@]}-5]}";
        catalog="${path[${#path[@]}-4]}";
        schema="${path[${#path[@]}-3]}";
        table="${path[${#path[@]}-2]}";
      else
        provider="${path[${#path[@]}-6]}";
        database="${path[${#path[@]}-5]}";
        classification="all";
        catalog="${path[${#path[@]}-4]}";
        schema="${path[${#path[@]}-3]}";
        table="${path[${#path[@]}-2]}";
      fi
    else
      echo "==> ERROR: ${obj} needs to be a more complete path. Aborting script.";
      echo "==> Run '$0 -help' for additional info.";
      exit 1;
    fi

    # source config
    if [ "${classification}" != "all" ]; then
      config="${configs_dir}/${provider}_${database}_${classification}_${catalog}.sh"
    else
      config="${configs_dir}/${provider}_${database}_${catalog}.sh"
    fi
    if [ -f ${config} ]; then
      source ${config}
    else
      echo "==> ERROR: missing ${config} file. Aborting script.";
      exit 1;
    fi

    # construct job.properties output
    job_properties_dir="${properties_dir}/${provider}/${database}/${classification}/${catalog}/${schema}/${table}"
    job_properties_file="${job_properties_dir}/${table}_${year}${month}${day}_job.properties"

    # create job.properties file if missing
    if [ ! -f "${job_properties_file}" ]; then
      echo "==> Creating ${job_properties_file}";
      mkdir -p "${job_properties_dir}"
      if [ "${classification}" != "all" ]; then
        cp "${templates_dir}/job.properties" "${job_properties_file}";
      else
        cp "${templates_dir}/job_sans_class.properties" "${job_properties_file}";
      fi 

      # source credentials
      source ${config}

      # update values
      sed -i "s/_namenode/${namenode}/g" ${job_properties_file}
      sed -i "s/_jobtracker/${jobtracker}/g" ${job_properties_file}
      sed -i "s/_month/${month}/g" ${job_properties_file}
      sed -i "s/_day/${day}/g" ${job_properties_file}
      sed -i "s/_year/${year}/g" ${job_properties_file}
      sed -i "s/_provider/${provider}/g" ${job_properties_file}
      sed -i "s/_database/${database}/g" ${job_properties_file}
      sed -i "s/_classification/${classification}/g" ${job_properties_file}
      sed -i "s/_catalog/${catalog}/g" ${job_properties_file}
      sed -i "s/_schema/${schema}/g" ${job_properties_file}
      sed -i "s/_table/${table}/g" ${job_properties_file}
      sed -i "s/_sql_user/${SQL_USER}/g" ${job_properties_file}
      sed -i "s/_sql_pass/${SQL_PASS}/g" ${job_properties_file}
      sed -i "s/_conn_string/${CONN_STRING}/g" ${job_properties_file}
      sed -i "s/_color/${color}/g" ${job_properties_file}
    fi

    # submit workflow to oozie
    job_output=$(oozie job -run -doas hdfs -oozie http://oozie.service.${color}.consul:11000/oozie -config ${job_properties_file});
    job_id=$( echo "${job_output}" | awk '{ print $2 }' );

    # verify job was submitted
    if [ -z "${job_id}" ]; then
      echo "==> ERROR: Job was not sucessfully submitted. Aborting script.";
      exit 1;
    fi

    # wait for job to complete
    while grep -q -P "Status\s+:\s+RUNNING" <(oozie job -info ${job_id} -oozie http://oozie.service.${color}.consul:11000/oozie); do
      sleep 60;
    done

    # query oozie for job metrics
    mapfile -t metrics < <(grep -P "Status\s+:\s+(\w+)|Started\s+\:\s+([a-zA-Z0-9:-\s]+)|Ended\s+\:\s+([a-zA-Z0-9:-\s]+)" <(oozie job -info ${job_id} -oozie http://oozie.service.${color}.consul:11000/oozie))
    status=$(echo "${metrics[0]}" | awk -F': ' '{ print $2 }')
    start_time=$(echo "${metrics[1]}" | awk -F': ' '{ print $2 }')
    end_time=$(echo "${metrics[2]}" | awk -F': ' '{ print $2 }')

    # create report file
    report="${reports_dir}/${provider}_${database}_${classification}_${catalog}_${year}${month}${day}.csv"
    if [ ! -f ${report} ]; then
      if [ -f "${reports_dir}/example.csv" ]; then
        cp "${reports_dir}/example.csv" ${report};
      else
        echo "==> ERROR: Template not found ${reports_dir}/example.csv. Aborting script.";
        exit 1;
      fi
    fi

    # report metrics
    echo "${provider},${database},${classification},${catalog},${schema},${table},${status},${start_time},${end_time},${job_id}" >> ${report}

  fi
done
