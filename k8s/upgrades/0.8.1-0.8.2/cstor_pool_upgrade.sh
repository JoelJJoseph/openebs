#!/bin/bash

###########################################################################
# STEP: Get SPC name and namespace where OpenEBS is deployed as arguments #
#                                                                         #
# NOTES: Obtain the pool deployments to perform upgrade operation         #
###########################################################################

pool_upgrade_version="0.8.2-RC4"
current_version="0.8.1"

function usage() {
    echo
    echo "Usage:"
    echo
    echo "$0 <spc-name> <openebs-namespace>"
    echo
    echo "  <spc-name> Get the SPC name using: kubectl get spc"
    echo "  <openebs-namespace> Get the namespace where pool pods"
    echo "    corresponding to SPC are deployed"
    exit 1
}

##Checking the version of OpenEBS ####
function verify_openebs_version() {
    local resource=$1
    local name_res=$2
    local openebs_version=$(kubectl get $resource $name_res -n $ns \
                 -o jsonpath="{.metadata.labels.openebs\.io/version}")

    if [[ $openebs_version != $current_version ]] && [[ $openebs_version != $pool_upgrade_version ]]; then
        echo "Expected version of $name_res in $resource is $current_version but got $openebs_version";exit 1;
    fi
    echo $openebs_version
}

## Starting point
if [ "$#" -ne 2 ]; then
    usage
fi

spc=$1
ns=$2

### Get the csp list which are related to the given spc ###
csp_list=$(kubectl get csp -l openebs.io/storage-pool-claim=$spc \
         -o jsonpath="{range .items[*]}{@.metadata.name}:{end}")
rc=$?
if [ $rc -ne 0 ]; then
    echo "Failed to get csp related to spc $spc"
    exit 1
fi

################################################################
# STEP: Update patch files with pool upgrade version           #
#                                                              #
################################################################

sed "s/@pool_version@/$pool_upgrade_version/g" cr-patch.tpl.json > cr_patch.json

echo "Patching the csp resource"
for csp in `echo $csp_list | tr ":" " "`; do
    version=$(verify_openebs_version "csp" $csp)
    rc=$?
    if [ $rc -ne 0 ]; then
        exit 1
    elif [ $version == $pool_upgrade_version ]; then
        continue
    fi
    ## Patching the csp resource
    kubectl patch csp $csp -p "$(cat cr_patch.json)" --type=merge
    rc=$?; if [ $rc -ne 0 ]; then echo "Error occured while upgrading the csp: $csp Exit Code: $rc"; exit; fi
done

echo "Patching Pool Deployment with new image"
for csp in `echo $csp_list | tr ":" " "`; do
    ## Get the pool deployment corresponding to csp
    pool_dep=$(kubectl get deploy -n $ns \
        -l app=cstor-pool,openebs.io/storage-pool-claim=$spc \
        -o jsonpath="{.items[?(@.metadata.labels.openebs\.io/cstor-pool=='$csp')].metadata.name}")

    version=$(verify_openebs_version "deploy" $pool_dep)
    rc=$?
    if [ $rc -ne 0 ]; then
        exit 1
    elif [ $version == $pool_upgrade_version ]; then
        continue
    fi

    ## Get the replica set corresponding to the deployment ##
    pool_rs=$(kubectl get rs -n $ns \
        -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].name=='$pool_dep')]}{@.metadata.name}{end}")
    echo "$pool_dep -> rs is $pool_rs"


    ## Modifies the cstor-pool-patch template with the original values ##
    sed "s/@pool_version@/$pool_upgrade_version/g" cstor-pool-patch.tpl.json > cstor-pool-patch.json

    ## Patch the deployment file ###
    kubectl patch deployment --namespace $ns $pool_dep -p "$(cat cstor-pool-patch.json)"
    rc=$?; if [ $rc -ne 0 ]; then echo "ERROR: Failed to patch $pool_dep $rc"; exit; fi
    rollout_status=$(kubectl rollout status --namespace $ns deployment/$pool_dep)
    rc=$?; if [[ ($rc -ne 0) || !($rollout_status =~ "successfully rolled out") ]];
    then echo "ERROR: Failed to rollout status for $pool_dep error: $rc"; exit; fi

    ## Deleting the old replica set corresponding to deployment
    kubectl delete rs $pool_rs --namespace $ns

    ## Cleaning the temporary patch file
    rm cstor-pool-patch.json
done

### Get the sp list which are related to the given spc ###
sp_list=$(kubectl get sp -l openebs.io/cas-type=cstor,openebs.io/storage-pool-claim=$spc \
        -o jsonpath="{range .items[*]}{@.metadata.name}:{end}")
rc=$?
if [ $rc -ne 0 ]; then
    echo "Failed to get sp related to spc $spc"
    exit 1
fi

### Patch sp resource###
echo "Patching the SP resource"
for sp in `echo $sp_list | tr ":" " "`; do
    version=$(verify_openebs_version "sp" $sp)
    rc=$?
    if [ $rc -ne 0 ]; then
        exit 1
    elif [ $version == $pool_upgrade_version ]; then
        continue
    fi
    kubectl patch sp $sp -p "$(cat cr_patch.json)" --type=merge
    rc=$?
    if [ $rc -ne 0 ]; then echo "Error: failed to patch for SP resource $sp Exit Code: $rc"; exit; fi
done

###Cleaning temporary patch file
rm cr_patch.json

echo "Successfully upgraded $spc to $pool_upgrade_version"
echo "Running post pool upgrade scripts for $spc..."

exit 0