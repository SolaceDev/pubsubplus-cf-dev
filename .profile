##

export MY_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

export SOLACE_MESSAGING_CF_DEV=${SOLACE_MESSAGING_CF_DEV:-$MY_HOME}

export PATH=$SOLACE_MESSAGING_CF_DEV/bin:$PATH

export WORKSPACE=${WORKSPACE:-$HOME/workspace}

export SYSTEM_DOMAIN=${SYSTEM_DOMAIN:-"bosh-lite.com"}
export CF_ADMIN_PASSWORD=${CF_ADMIN_PASSWORD:-"admin"}

if [ -f $WORKSPACE/bucc/bin/bucc ]; then
   $WORKSPACE/bucc/bin/bucc env > $WORKSPACE/.env
fi

if [ -f $WORKSPACE/.env ]; then
   source $WORKSPACE/.env
   export BOSH_IP=$BOSH_ENVIRONMENT
fi

if [ -f $WORKSPACE/deployment-vars.yml ]; then
   export CF_ADMIN_PASSWORD=$(bosh int $WORKSPACE/deployment-vars.yml --path /cf_admin_password) 
fi

source $SOLACE_MESSAGING_CF_DEV/bin/bosh-common.sh

if [ -z $SEEN_BANNER ]; then
 echo
 echo
 cat $SOLACE_MESSAGING_CF_DEV/.banner
 echo
 echo
 export SEEN_BANNER=1
fi

printf "SOLACE_MESSAGING_CF_DEV\t\t%s\n" "$SOLACE_MESSAGING_CF_DEV"

printf "WORKSPACE\t\t\t%s\n" "$WORKSPACE"

## Test PCF Dev access

CF_API_FOUND=$( cf api | grep "api endpoint" | grep http | wc -l )

if [ "$CF_API_FOUND" -eq "0" ]; then

   printf  "CF   \t\t\t\t%s\n" "Access attempt (may take some time)"

   ping -q -c 5 -w 10 api.$SYSTEM_DOMAIN > /dev/null
   if [ $? -eq "0" ]; then
    export CF_ACCESS=0
    cf api https://api.$SYSTEM_DOMAIN --skip-ssl-validation > /dev/null
    if [ $? -eq 0 ]; then
       cf auth admin $CF_ADMIN_PASSWORD > /dev/null
       if [ $? -eq 0 ]; then
          export CF_ACCESS=1
       else
       export CF_ACCESS=0
       fi
    else
      export CF_ACCESS=0
    fi
   else
     export CF_ACCESS=0
   fi

   if [ $CF_ACCESS -eq "1" ]; then
    printf  "CF   \t\t\t\t%s\n" "OK"
   else
    printf  "CF   \t\t\t\t%s\n" "WARN: CF is not accessible. Is it installed? running? is routing enabled?"
   fi

else
  CF_API=$( cf api | grep "api endpoint" | grep http )
  printf  "CF   \t\t\t\t%s\n" "You seem to have CF set to access ( $CF_API )"
  if [[ $CF_API == "https://api.local.pcfdev.io" ]]; then 
    export WINDOWS=true
    printf " Setting SYSTEM_DOMAIN to local.pcfdev.io" 
    export SYSTEM_DOMAIN='local.pcfdev.io'
  fi
  export CF_ACCESS=1
fi


## Test BOSH access

export BOSH_ACCESS=0
printf "BOSH   \t\t\t\t%s\n" "Access attempt (may take some time)"

ping -q -c 5 -w 10 $BOSH_IP > /dev/null
if [ $? -eq "0" ]; then
  targetBosh
else
  export BOSH_ACCESS=0
fi

if [ $BOSH_ACCESS -eq "1" ]; then
    printf "BOSH   \t\t\t\t%s\n" "OK"
else
    printf "BOSH   \t\t\t\t%s\n" "WARN: BOSH is not accessible. Is it installed ? running? is routing enabled?"
fi

echo

