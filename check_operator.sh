#!/usr/bin/env bash

: '
Access to this file is granted under the SCONE COMMERCIAL LICENSE V1.0

Any use of this product using this file requires a commercial license from scontain UG, www.scontain.com.

Permission is also granted  to use the Program for a reasonably limited period of time  (but no longer than 1 month)
for the purpose of evaluating its usefulness for a particular purpose.

THERE IS NO WARRANTY FOR THIS PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING
THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE.

THE ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE,
YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED ON IN WRITING WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY
MODIFY AND/OR REDISTRIBUTE THE PROGRAM AS PERMITTED ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL,
INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE PROGRAM INCLUDING BUT NOT LIMITED TO LOSS
OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE
WITH ANY OTHER PROGRAMS), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

Copyright (C) 2022 scontain.com
'

set -e

export RED='\e[31m'
export BLUE='\e[34m'
export ORANGE='\e[33m'
export NC='\e[0m' # No Color


function verbose () {
    if [[ $V -eq 1 ]]; then
        echo -e "${BLUE}- $@${NC}"
    fi
}

function warning () {
    echo -e "${ORANGE}WARNING: $@${NC}"
}

function error_exit() {
  trap '' EXIT
  echo -e "${RED}$1${NC}" 
  exit 1
}

# print an error message on an error exit
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'if [ $? -ne 0 ]; then echo -e "${RED}\"${last_command}\" command failed - exiting.${NC}" ; fi' EXIT

# CONFIG SECTION

CERT_MANAGER="https://github.com/cert-manager/cert-manager/releases/download/v1.10.1/cert-manager.yaml"
DEFAULT_NAMESPACE="scone-system"
HELM_CHART="https://github.com/scontain/operator/archive/refs/tags/v0.0.7.tar.gz"
LAS_MANIFEST="https://raw.githubusercontent.com/scontain/operator-samples/main/base_v1beta1_las.yaml"
SGXPLUGIN_MANIFEST="https://raw.githubusercontent.com/scontain/operator-samples/main/base_v1beta1_sgxplugin.yaml"
REGISTRY="registry.scontain.com"
KUBECTLPLUGIN="https://raw.githubusercontent.com/scontain/SH/master/kubectl-provision"

# Functions to fix state

function check_namespace {
    namespace=$1
    verbose "  Checking namespace $namespace"

    if ! kubectl get namespace "$namespace" > /dev/null 2>/dev/null
    then
        warning "  Namespace '$namespace' does not exist."
        if [[ $FIX == 1 ]] ; then
            ns_manifest=".ns.yaml"
            verbose " Creating namespace '$namespace' - enabling automatic pull secret injection"
            verbose "   Creating manifest '$namespace_manifest'"
            cat >"$namespace_manifest"  <<EOF
apiVersion: v1
kind: Namespace
metadata:
name: $namespace
labels:
    name: scone-system
annotations:
    scone-operator/inject-pull-secret:  "true"
    sconeapps/inject-pull-secret:  "true"
EOF

            kubectl apply -f "$namespace_manifest"
        fi
    else
        verbose "  Namespace '$namespace' already exist - no updating/fixing"
    fi
}


function check_secret {
    secret="$1"
    namespace="$2"

    if [[ $UPDATE == 1 &&  "$REGISTRY_USERNAME" != "" ]] ; then
        verbose "  Updating secret $secret"
        kubectl delete secret "$secret" -n "$namespace" --ignore-not-found
        NO_WARNING=1
    else
        NO_WARNING=0
    fi
    if ! kubectl get secret "$secret" -n "$namespace" > /dev/null 2>/dev/null
    then
        if [[ NO_WARNING != 1 ]] ; then
            warning "Secret '$secret' does not exist in namespace '$namespace'."
        fi
        if [[ $FIX == 1 ]] ; then
            verbose "  Fixing/Updating secret $secret"
            if [[ "$REGISTRY_USERNAME" == "" ]] ; then
                warning "You need to specify $user_flag, $token_flag, and $email_flag!"
                warning "CANNOT fix the secret $secret"
            else
                kubectl create secret docker-registry "$secret" --docker-server="$REGISTRY" --docker-username="$REGISTRY_USERNAME"  --docker-password="$REGISTRY_ACCESS_TOKEN"  --docker-email="$REGISTRY_EMAIL" --namespace "$namespace"
            fi
        fi
    else
        verbose "  Secret '$secret' alrady exists in namespace '$namespace'."
    fi
}


#
help_flag="--help"
ns_flag="--namespace"
ns_short_flag="-n"
fix_flag="--fix"
fix_short_flag="-f"
cr_flag="--create"
cr_short_flag="-c"
update_flag="--update"
update_short_flag="-u"
verbose_flag="-v"
verbose=""
owner_flag="--owner-config"
owner_short_flag="-o"
verbose=""
debug_flag="--debug"
debug_short_flag="-d"
debug=""
user_flag="--username"
token_flag="--access-token"
email_flag="--email"
plugin_flag="--plugin-path"

ns="$DEFAULT_NAMESPACE"
repo="$APP_IMAGE_REPO"
create_ns=""

FIX=0  # Default only check - do not fix
UPDATE=0

SVC=""
NAME=""
REGISTRY_USERNAME=""
REGISTRY_ACCESS_TOKEN=""
REGISTRY_EMAIL=""

# find directory on path where we are permitted to copy the plugin to

PLUGINBIN=`which kubectl-provision` || { PLUGINBIN="" ; for p in ${PATH//:/ } ; do
        if [[ -w "$p" ]] ; then
            PLUGINBIN="$p/kubectl-provision"
        fi
    done
}

usage ()
{
  echo ""
  echo "Usage:"
  echo "  check_scone_operator"
  echo ""
  echo "Objectives:"
  echo "  - Checks if the SCONE operator and all its prerequisites are available."
  echo "  - Tries to fix any issues it discovers if flag '--fix' is set."
  echo "  - Tries to update all components in case flag '--update' is set (even if everything is ok)."
  echo "  - Creates a namespace for a service if flag --create NAMESPACE is set."
  echo ""
  echo ""
  echo "Options:"
  echo "    $fix_flag | $fix_short_flag"
  echo "                  Try to fix all warnings that we discover."
  echo "                  The default is to warn about potential issues only."
  echo "    $update_flag | $update_short_flag"
  echo "                  Try to update all prerequisites of the SCONE operator."
  echo "                  independently if they need fixing."
  echo "    $ns_short_flag | $ns_flag"
  echo "                  The Kubernetes namespace in which the SCONE operator should be deployed on the cluster."
  echo "                  Default value: \"$DEFAULT_NAMESPACE\""
  echo "    $cr_short_flag | $cr_flag"
  echo "                  Create a namespace for provisioning SCONE CAS (or another service)."
  echo "    $user_flag REGISTRY_USERNAME"
  echo "                  To create/update/fix the pull secrets ('sconeapps' and 'scone-operator-pull'), "
  echo "                  one needs to specify the user name, access token, and email of the registry."
  echo "                  Signup for an account: https://sconedocs.github.io/registry/"
  echo "    $token_flag REGISTRY_ACCESS_TOKEN"
  echo "                  The access token of the pull secret."
  echo "    $email_flag REGISTRY_EMAIL"
  echo "                  The email address belonging to the pull secret."
  echo "    $plugin_flag"
  echo "                  Path where we should write the plugin binary. The path must be writeable. Default value: \"$PLUGINBIN\""
  echo "    $verbose_flag"
  echo "                  Enable verbose output"
  echo "    $debug_flag | debug_short_flag"
  echo "                  Create debug image instead of a production image"
  echo "    $help_flag"
  echo "                  Output this usage information and exit."
  echo ""
}

##### Parsing arguments

while [[ "$#" -gt 0 ]]; do
  case $1 in
    ${ns_flag} | ${ns_short_flag})
      ns="$2"
      if [ ! -n "${ns}" ]; then
        usage
        error_exit "Error: The namespace '$ns' is invalid."
      fi
      shift # past argument
      shift || true # past value
      ;;
    ${cr_flag} | ${cr_short_flag})
      create_ns="$2"
      if [ ! -n "${create_ns}" ]; then
        usage
        error_exit "Error: The namespace '$create_ns' is invalid."
      fi
      shift # past argument
      shift || true # past value
      ;;
    ${plugin_flag})
      REGISTRY_PLUGINBINUSERNAME="$2"
      if [ ! -w "${PLUGINBIN}" || ! -d "${PLUGINBIN}" ]; then
        usage
        error_exit "Error: Please specify a valid plugin path ('$PLUGINBIN' is invalid)."
      fi
      shift # past argument
      shift || true # past value
      ;;
    ${user_flag})
      REGISTRY_USERNAME="$2"
      if [ ! -n "${REGISTRY_USERNAME}" ]; then
        usage
        error_exit "Error: Please specify a valid REGISTRY USERNAME ('$REGISTRY_USERNAME' is invalid)."
      fi
      shift # past argument
      shift || true # past value
      ;;
    ${token_flag})
      REGISTRY_ACCESS_TOKEN="$2"
      if [ ! -n "${REGISTRY_ACCESS_TOKEN}" ]; then
        usage
        error_exit "Error: Please specify a valid REGISTRY ACCESS TOKEN ('$REGISTRY_ACCESS_TOKEN' is invalid)."
      fi
      shift # past argument
      shift || true # past value
      ;;
    ${email_flag})
      REGISTRY_EMAIL="$2"
      if [ ! -n "${REGISTRY_EMAIL}" ]; then
        usage
        error_exit "Error: Please specify a valid REGISTRY ACCESS TOKEN ('$REGISTRY_EMAIL' is invalid)."
      fi
      shift # past argument
      shift || true # past value
      ;;
    ${fix_flag} | ${fix_short_flag})
      FIX=1
      shift # past argument
      ;;
    ${update_flag} | ${update_short_flag})
      UPDATE=1
      shift # past argument
      ;;
    ${verbose_flag})
      V=1
      shift # past argument
      ;;
    ${debug_flag} | ${debug_short_flag})
      set -x
      shift # past argument
      ;;
    $help_flag)
      usage
      exit 0
      ;;
    *)
      usage
      error_exit "Error: Unknown parameter passed: $1";
      ;;
  esac
done

if [[ $REGISTRY_USERNAME != "" || $REGISTRY_ACCESS_TOKEN != "" ||  $REGISTRY_EMAIL != "" ]] ; then
    if [[ $REGISTRY_USERNAME == "" || $REGISTRY_ACCESS_TOKEN == "" ||  $REGISTRY_EMAIL == "" ]] ; then
        error_exit "You need to specify flags $user_flag, $token_flag, $token_flag"
    fi
fi

if [[ $UPDATE == 1 ]] ; then
    verbose "Updating / fixing all components"
    FIX=1
fi

verbose "Checking cert-manager"

CM="0"

if [[ $UPDATE == 1 ]] ; then
    verbose "  Updating cert-manager (using manifest $CERT_MANAGER)"
    kubectl apply -f "$CERT_MANAGER"
fi

until [[ $CM != "0" ]]
do
    export CM=`kubectl get pods -A | grep cert-manager | grep Running | wc -l | sed 's/^[[:space:]]*//g'`
    if [[ $CM == "0" ]] ; then
        warning "cert-manager is not running - trying to start cert manager"
        kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.1/cert-manager.yaml
        warning "waiting 5 seconds before checking again"
        sleep 5
    else
        verbose "  cert-manager is running (found '$CM' running pods)"
    fi
done

verbose "Checking that operator namespace '$ns' exists"
check_namespace "$ns"

if [[ "$create_ns" != "" ]] ; then
    verbose "Checking that service namespace '$create_ns' exists"
    check_namespace "$create_ns"
fi

check_secret "scone-operator-pull" "$ns"
check_secret "sconeapps" "$ns"

verbose "Checking SCONE Operator"
SO=`helm list -A | grep scone-operator | wc -l | sed 's/^[[:space:]]*//g'`

if [[ $UPDATE == 1 && $SO != "0" ]] ; then
    verbose "  Updating the SCONE Operator"
    helm upgrade scone-operator $HELM_CHART --namespace $ns
fi

if [[ $SO == "0" ]] ; then
    warning "SCONE operator not installed!"
    if [[ $FIX == 1 ]] ; then
        verbose "  Fixing the SCONE Operator"
        helm install scone-operator $HELM_CHART --namespace $ns
    fi
fi

if ! kubectl describe crd sgxplugins > /dev/null 2>/dev/null
then
    warning "Custom Resource Definition 'sgxplugins' does not exist."
fi

if ! kubectl describe crd las > /dev/null 2>/dev/null
then
    warning "Custom Resource definition 'las' does not exist."
fi


if ! kubectl describe crd cas > /dev/null 2>/dev/null
then
    warning "Custom Resource Definition 'cas' does not exist."
fi

if ! kubectl describe crd signedpolicies > /dev/null 2>/dev/null
then
    warning "Custom Resource Definition 'signedpolicies' does not exist."
fi

if ! kubectl describe crd encryptedpolicies > /dev/null 2>/dev/null
then
    warning "Custom Resource Definition 'encryptedpolicies' does not exist."
fi

if ! kubectl get sgxplugin "sgxplugin" > /dev/null 2>/dev/null
then
    warning "Custom Resource 'las' does not yet exist."
    if [[ $FIX == 1 ]] ; then
        verbose "  Fixing by creating a sgxplugin resource using manifest '$SGXPLUGIN_MANIFEST'"
        kubectl apply -f "$SGXPLUGIN_MANIFEST"
    fi
else
  verbose "Custom Resource 'sgxplugin' does already exists"
fi

if ! kubectl get "las" "las" > /dev/null 2>/dev/null
then
    warning "Custom Resource 'las' does not yet exist."
    if [[ $FIX == 1 ]] ; then
        verbose "  Fixing by creating a LAS resource using manifest '$LAS_MANIFEST'"
        kubectl apply -f "$LAS_MANIFEST"
    fi
else
    verbose "Custom Resource 'las' already exists"
fi


verbose "Checking the existing of the plugin"

Fixit=$UPDATE
kubectl provision cas --help > /dev/null 2>/dev/null || Fixit=1

if [[ Fixit != 0 ]] ; then
    verbose "  SCONE kubectl plugin does not exist or should be updated"
    if [[ $FIX == 1 ]] ; then
        if [[ "$PLUGINBIN" == "" || ! -w  "$PLUGINBIN" ]] ; then
            error_exit "cannot write to binary $PLUGINBIN: please specify writable path '$plugin_flag <PATH>'"
        else
            echo "Storing kubectl plugin in directory $PLUGINBIN"
            verbose "  Fixing kubectl plugin - downloading $KUBECTLPLUGIN to file $PLUGINBIN "
            echo curl -fsSL "$KUBECTLPLUGIN"  -o $PLUGINBIN
        fi
    fi
else
    verbose "  SCONE kubectl plugin already installed"
fi
