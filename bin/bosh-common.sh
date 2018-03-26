#!/bin/bash

export MY_BIN_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export PYTHONPATH=$MY_BIN_HOME

export DEPLOYMENT_NAME="solace_messaging"
export LOG_FILE=${LOG_FILE:-"$WORKSPACE/bosh_deploy.log"}

export USE_ERRANDS=${USE_ERRANDS:-"1"}

######################################

export BOSH_IP=${BOSH_IP:-"192.168.50.4"}
export BOSH_CMD="/usr/local/bin/bosh"
export BOSH_CLIENT=${BOSH_CLIENT:-admin}
export BOSH_CLIENT_SECRET=${BOSH_CLIENT_SECRET:-admin}
export BOSH_NON_INTERACTIVE${BOSH_NON_INTERACTIVE:-true}
export BOSH_ENVIRONMENT=${BOSH_ENVIRONMENT:-"lite"}
export BOSH_DEPLOYMENT=${BOSH_DEPLOYMENT:-$DEPLOYMENT_NAME}
export STEMCELL_VERSION=${STEMCELL_VERSION:-"3541.9"}
export STEMCELL_NAME="bosh-stemcell-$STEMCELL_VERSION-warden-boshlite-ubuntu-trusty-go_agent.tgz"
export STEMCELL_URL="https://s3.amazonaws.com/bosh-core-stemcells/warden/$STEMCELL_NAME"

function targetBosh() {

  ## Setup to access target bosh-lite
    
  if [ ! -f $WORKSPACE/.env ] && [ "$BOSH_IP" == "192.168.50.4" ]; then
     # Old bosh-lite
     if [ ! -d $WORKSPACE/bosh-lite ]; then
       (cd $WORKSPACE; git clone https://github.com/cloudfoundry/bosh-lite.git)
     fi 

     # bosh target $BOSH_IP alias as 'lite'
     BOSH_TARGET_LOG=$( $BOSH_CMD alias-env lite -e $BOSH_IP --ca-cert=$WORKSPACE/bosh-lite/ca/certs/ca.crt --client=admin --client-secret=admin  )
  else
     # unset BOSH_DEPLOYMENT
     # New bosh-lite
     BOSH_TARGET_LOG=$( $BOSH_CMD alias-env lite -e $BOSH_IP )
  fi

  if [ $? -eq 0 ]; then
     # Login will rely on BOSH_* env vars..
     BOSH_LOGIN_LOG=$( BOSH_CLIENT=$BOSH_CLIENT BOSH_CLIENT_SECRET=$BOSH_CLIENT_SECRET $BOSH_CMD log-in )
     if [ $? -eq 0 ]; then
        export BOSH_ACCESS=1
     else
        export BOSH_ACCESS=0
        echo $BOSH_LOGIN_LOG
     fi
  else
     export BOSH_ACCESS=0
     echo $BOSH_TARGET_LOG
  fi

}


function prepareBosh() { 

echo "Checking stemcell $STEMCELL_NAME"

  FOUND_STEMCELL=`bosh stemcells | grep bosh-warden-boshlite-ubuntu-trusty-go_agent | grep $STEMCELL_VERSION | wc -l`
  if [ "$FOUND_STEMCELL" -eq "0" ]; then
     if [ ! -f $WORKSPACE/$STEMCELL_NAME ]; then
        wget -O $WORKSPACE/$STEMCELL_NAME $STEMCELL_URL
     fi
     bosh upload-stemcell $WORKSPACE/$STEMCELL_NAME
  else
     echo "$STEMCELL_NAME was found $FOUND_STEMCELL"
  fi
}

function deleteOrphanedDisks() {

$BOSH_CMD disks --orphaned

ORPHANED_DISKS=$( $BOSH_CMD disks --orphaned --json | jq '.Tables[].Rows[] | select(.deployment="solace_messaging") | .disk_cid' | sed 's/\"//g' )

for DISK_ID in $ORPHANED_DISKS; do
	echo "Will delete $DISK_ID"
	$BOSH_CMD -n delete-disk $DISK_ID
	echo
	echo "Orphaned Disk $DISK_ID was deleted"
	echo
done

}

#################################

function shutdownVMRJobs() {

 echo "In shutdownVMRJobs"

 VM_JOB=$1

 echo "Looking for VM job $VM_JOB" 
 VM_FOUND_COUNT=`$BOSH_CMD vms | grep $VM_JOB | wc -l`
 VM_RUNNING_FOUND_COUNT=`$BOSH_CMD vms --json | jq '.Tables[].Rows[] | select(.process_state=="running") | .instance' | grep $VM_JOB |  wc -l`
 DEPLOYMENT_FOUND_COUNT=`$BOSH_CMD deployments | grep $DEPLOYMENT_NAME | wc -l`
 RELEASE_FOUND_COUNT=`$BOSH_CMD releases | grep solace-vmr | wc -l`

 if [ "$VM_RUNNING_FOUND_COUNT" -eq "1" ]; then

   echo "Will stop monit jobs if any are running on $DEPLOYMENT_NAME / $VM_JOB"
   $BOSH_CMD ssh $VM_JOB "sudo /var/vcap/bosh/bin/monit stop all" 

   RUNNING_COUNT=`$BOSH_CMD ssh $VM_JOB "sudo /var/vcap/bosh/bin/monit summary" | grep running | wc -l`
   MAX_WAIT=60
   while [ "$RUNNING_COUNT" -gt "0" ] && [ "$MAX_WAIT" -gt "0" ]; do
   	echo "Waiting for monit to finish shutdown - found $RUNNING_COUNT still running"
	sleep 5
        let MAX_WAIT=MAX_WAIT-5
        RUNNING_COUNT=`$BOSH_CMD ssh $VM_JOB "sudo /var/vcap/bosh/bin/monit summary " | grep running | wc -l`
   done
 else
  echo "Did not find running job $VM_JOB"
 fi

}

function shutdownAllVMRJobs() {
    local DEPLOYED_MANIFEST="$WORKSPACE/deployed-manifest.yml"
    $BOSH_CMD -n manifest > $DEPLOYED_MANIFEST
    echo "Shutting down all VMR jobs..."
    VMR_JOBS=$(bosh vms --json | jq '.Tables[].Rows[] | select(.process_state=="running") | .instance' | sed 's/\"//g' )
    for VMR_JOB_NAME in ${VMR_JOBS[@]}; do
        echo "Shutting down $VMR_JOB_NAME"
        shutdownVMRJobs $VMR_JOB_NAME | tee $LOG_FILE
    done
    rm $DEPLOYED_MANIFEST
}

function deleteDeploymentAndRelease() {

 DEPLOYMENT_FOUND_COUNT=`$BOSH_CMD deployments | grep $DEPLOYMENT_NAME | wc -l`
 SOLACE_VMR_RELEASE_FOUND_COUNT=`$BOSH_CMD releases | grep solace-vmr | wc -l`
 SOLACE_MESSAGING_RELEASE_FOUND_COUNT=`$BOSH_CMD releases | grep solace-messaging | wc -l`

 local DEPLOYED_MANIFEST="$WORKSPACE/deployed-manifest.yml"

 if [ "$DEPLOYMENT_FOUND_COUNT" -eq "1" ]; then
    $BOSH_CMD -n manifest > $DEPLOYED_MANIFEST

    if [ "$USE_ERRANDS" -eq "1" ]; then
      echo "Calling bosh run-errand delete-all"
      $BOSH_CMD run-errand delete-all
    fi

    # Delete the deployment 
    echo "Deleting deployment $DEPLOYMENT_NAME"
    $BOSH_CMD -n delete-deployment 
 else
   echo "No deployment found."
 fi

 if [ "$SOLACE_VMR_RELEASE_FOUND_COUNT" -ge "1" ]; then
    # solace-vmr
    echo "Deleting release solace-vmr"
    $BOSH_CMD -n delete-release solace-vmr
 else
    echo "No solace-vmr release found"
 fi

 if [ "$SOLACE_MESSAGING_RELEASE_FOUND_COUNT" -ge "1" ]; then
    # solace-messaging
    echo "Deleting release solace-messaging"
    $BOSH_CMD -n delete-release solace-messaging
 else
    echo "No solace-messaging release found"
 fi
 
 if [ -f $DEPLOYED_MANIFEST ]; then
    rm $DEPLOYED_MANIFEST
 fi

}

function getReleaseNameAndVersion() {
    SOLACE_VMR_BOSH_RELEASE_FILE_MATCHER="$WORKSPACE/releases/solace-vmr-*.tgz"
    for f in $SOLACE_VMR_BOSH_RELEASE_FILE_MATCHER; do
      if ! [ -e "$f" ]; then
        echo "Could not find solace-vmr bosh release file: $SOLACE_VMR_BOSH_RELEASE_FILE_MATCHER"
        exit 1
      fi

      export SOLACE_VMR_BOSH_RELEASE_FILE="$f"
      break
    done
    export SOLACE_VMR_BOSH_RELEASE_VERSION_FULL=$(basename $SOLACE_VMR_BOSH_RELEASE_FILE | sed 's/solace-vmr-//g' | sed 's/.tgz//g' )
    export SOLACE_VMR_BOSH_RELEASE_VERSION=$(basename $SOLACE_VMR_BOSH_RELEASE_FILE | sed 's/solace-vmr-//g' | sed 's/.tgz//g' | awk -F\- '{ print $1 }' )
    export SOLACE_VMR_BOSH_RELEASE_VERSION_DEV=$(basename $SOLACE_VMR_BOSH_RELEASE_FILE | sed 's/solace-vmr-//g' | sed 's/.tgz//g' | awk -F\- '{ print $2 }' )
    echo "Determined SOLACE_VMR_BOSH_RELEASE_VERSION_FULL $SOLACE_VMR_BOSH_RELEASE_VERSION_FULL"
    echo "Determined SOLACE_VMR_BOSH_RELEASE_VERSION $SOLACE_VMR_BOSH_RELEASE_VERSION"
    echo "Determined SOLACE_VMR_BOSH_RELEASE_VERSION_DEV $SOLACE_VMR_BOSH_RELEASE_VERSION_DEV"


    SOLACE_MESSAGING_BOSH_RELEASE_FILE_MATCHER="$WORKSPACE/releases/solace-messaging-*.tgz"
    for f in $SOLACE_MESSAGING_BOSH_RELEASE_FILE_MATCHER; do
      if ! [ -e "$f" ]; then
        echo "Could not find solace-messaging bosh release file: $SOLACE_MESSAGING_BOSH_RELEASE_FILE_MATCHER"
        exit 1
      fi

      export SOLACE_MESSAGING_BOSH_RELEASE_FILE="$f"
      break
    done
    export SOLACE_MESSAGING_BOSH_RELEASE_VERSION_FULL=$(basename $SOLACE_MESSAGING_BOSH_RELEASE_FILE | sed 's/solace-messaging-//g' | sed 's/.tgz//g' )
    export SOLACE_MESSAGING_BOSH_RELEASE_VERSION=$(basename $SOLACE_MESSAGING_BOSH_RELEASE_FILE | sed 's/solace-messaging-//g' | sed 's/.tgz//g' | awk -F\- '{ print $1 }' )
    export SOLACE_MESSAGING_BOSH_RELEASE_VERSION_DEV=$(basename $SOLACE_MESSAGING_BOSH_RELEASE_FILE | sed 's/solace-messaging-//g' | sed 's/.tgz//g' | awk -F\- '{ print $2 }' )
    echo "Determined SOLACE_MESSAGING_BOSH_RELEASE_VERSION_FULL $SOLACE_MESSAGING_BOSH_RELEASE_VERSION_FULL"
    echo "Determined SOLACE_MESSAGING_BOSH_RELEASE_VERSION $SOLACE_MESSAGING_BOSH_RELEASE_VERSION"
    echo "Determined SOLACE_MESSAGING_BOSH_RELEASE_VERSION_DEV $SOLACE_MESSAGING_BOSH_RELEASE_VERSION_DEV"

}

function uploadAndDeployRelease() {

echo "in function uploadAndDeployRelease. SOLACE_MESSAGING_BOSH_RELEASE_FILE: $SOLACE_MESSAGING_BOSH_RELEASE_FILE"

SOLACE_MESSAGING_BOSH_RELEASE_FILE=${SOLACE_MESSAGING_BOSH_RELEASE_FILE:-`ls $WORKSPACE/releases/solace-messaging-*.tgz | tail -1`}
SOLACE_MESSAGING_RELEASE_FOUND_COUNT=`$BOSH_CMD releases | grep solace-messaging | wc -l`

if [ -f $SOLACE_MESSAGING_BOSH_RELEASE_FILE ]; then

 targetBosh

 if [ "$SOLACE_MESSAGING_RELEASE_FOUND_COUNT" -gt "0" ]; then
  UPLOADED_RELEASE_VERSION=`$BOSH_CMD releases | grep solace-messaging | awk '{ print $4 }'`
  # remove trailing '*'
  UPLOADED_RELEASE_VERSION="${UPLOADED_RELEASE_VERSION%\*}"
  echo "Determined solace-messaging uploaded version $UPLOADED_RELEASE_VERSION"
 fi

 if [ "$SOLACE_MESSAGING_RELEASE_FOUND_COUNT" -eq "0" ] || \
    [ "$SOLACE_MESSAGING_BOSH_RELEASE_VERSION_FULL" '>' "$UPLOADED_RELEASE_VERSION" ]; then
  echo "Will upload release $SOLACE_MESSAGING_BOSH_RELEASE_FILE"

  $BOSH_CMD upload-release $SOLACE_MESSAGING_BOSH_RELEASE_FILE | tee -a $LOG_FILE
 else
  echo "A solace-messaging release with version greater than or equal to $SOLACE_MESSAGING_BOSH_RELEASE_VERSION_FULL already exists. Skipping release upload..."
 fi

fi

SOLACE_VMR_BOSH_RELEASE_FILE=${SOLACE_VMR_BOSH_RELEASE_FILE:-`ls $WORKSPACE/releases/solace-vmr-*.tgz | tail -1`}
RELEASE_FOUND_COUNT=`$BOSH_CMD releases | grep solace-vmr | wc -l`

echo "in function uploadAndDeployRelease. SOLACE_VMR_BOSH_RELEASE_FILE: $SOLACE_VMR_BOSH_RELEASE_FILE"

if [ -f $SOLACE_VMR_BOSH_RELEASE_FILE ]; then

 targetBosh

 if [ "$RELEASE_FOUND_COUNT" -gt "0" ]; then
  UPLOADED_RELEASE_VERSION=`$BOSH_CMD releases | grep solace-vmr | awk '{ print $4 }'`
  # remove trailing '*'
  UPLOADED_RELEASE_VERSION="${UPLOADED_RELEASE_VERSION%\*}"
 fi

 if [ "$RELEASE_FOUND_COUNT" -eq "0" ] || \
    [ "$SOLACE_VMR_BOSH_RELEASE_VERSION_FULL" '>' "$UPLOADED_RELEASE_VERSION" ]; then
  echo "Will upload release $SOLACE_VMR_BOSH_RELEASE_FILE"

  $BOSH_CMD upload-release $SOLACE_VMR_BOSH_RELEASE_FILE | tee -a $LOG_FILE
 else
  echo "A solace-vmr release with version greater than or equal to $SOLACE_VMR_BOSH_RELEASE_VERSION_FULL already exists. Skipping release upload..."
 fi

 echo "Calling bosh deployment"
 echo "MANIFEST_FILE=$MANIFEST_FILE"

# $BOSH_CMD deployment $MANIFEST_FILE | tee -a $LOG_FILE 

 VMR_JOBS=$(py "getManifestJobNames" $MANIFEST_FILE)
 for VMR_JOB_NAME in ${VMR_JOBS[@]}; do
    JOB=$(py "getManifestJobByName" $MANIFEST_FILE $VMR_JOB_NAME)
    if [ "$(echo -n $JOB | wc -c)" -eq "0" ]; then
        continue
    fi

    POOL_NAME="$(echo -n $JOB | shyaml get-value properties.pool_name)"
    SOLACE_DOCKER_IMAGE_NAME="$(py 'getSolaceDockerImageName' $POOL_NAME)"
    echo "Will deploy VMR with name $VMR_JOB_NAME, having POOL_NAME: $POOL_NAME, and using $SOLACE_DOCKER_IMAGE_NAME" | tee -a $LOG_FILE
 done

 $BOSH_CMD -n deploy $MANIFEST_FILE | tee -a $LOG_FILE
 BOSH_DEPLOY_RETURN_CODE=${PIPESTATUS[0]}

 if [ "$BOSH_DEPLOY_RETURN_CODE" -ne "0" ]; then
   >&2 echo "bosh deploy returned a non-zero code - deployment failed"
   >&2 echo "Aborting"
   exit 1
 fi

 $BOSH_CMD vms
 DEPLOYMENT_FOUND_COUNT=`2>&1 $BOSH_CMD deployments | grep $DEPLOYMENT_NAME | wc -l`
 if [ "$DEPLOYMENT_FOUND_COUNT" -eq "0" ]; then
   >&2 echo "bosh did not find any deployments - deployment likely failed"
   exit 1
 fi

 POOL_NAMES=$(py "getPoolNames")
 FAILED_VMS_COUNT=`2>&1 $BOSH_CMD vms | grep -E "($(echo ${POOL_NAMES[*]} | tr ' ' '|'))/[0-9]+" | grep -v running | wc -l`
 if [ "$FAILED_VMS_COUNT" -gt "0" ]; then
   >&2 echo "Found non-running VMs - deployment likely failed"
   exit 1
 fi

 if [ "$USE_ERRANDS" -eq "1" ]; then
   echo "Calling $BOSH_CMD run-errand deploy-all"
   $BOSH_CMD run-errand deploy-all
 fi

 if [ "$USE_ERRANDS" -eq "1" ]; then
   echo "Calling $BOSH_CMD run-errand tests"
   $BOSH_CMD run-errand tests
 fi

else
 >&2 echo "Could not locate a release file in $WORKSPACE/releases/solace-vmr-*.tgz"
 exit 1
fi

}

function py() {
  local OP=$1 PARAMS=() CURRENT_DIR=`pwd`
  shift

  cd $MY_BIN_HOME

  while (( "$#" )); do
    if [ -n "$1" ] && (echo "$1" | grep -qE "[^0-9]"); then
      PARAMS+=("\"$1\"")
    else
      PARAMS+=($1)
    fi
    shift
  done

  python3 -c "import commonUtils; commonUtils.$OP($(IFS=$','; echo "${PARAMS[*]}"))"

  cd $CURRENT_DIR
}


function runDeleteAllErrand() {
   targetBosh
   $BOSH_CMD run-errand delete-all
}

function runTestsErrand() {
   targetBosh
   $BOSH_CMD run-errand tests
}

function runDeployAllErrand() {
  targetBosh
  $BOSH_CMD run-errand deploy-all
}

