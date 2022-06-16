#!/usr/bin/env bash

# Author: Salvatore Cuzzilla
# em@il: salvatore@cuzzilla.org  
# Starting date:    07-01-2021
# Last change date: 19-01-2020
# Release date:     TBD
# Description: extract L3VPN overlay cfg from an MPLS router


set -o errexit
set -o nounset
set -o pipefail

work_dir=$(dirname "$(readlink --canonicalize-existing "${0}" 2> /dev/null)")

readonly epoch=$(date +'%s')
readonly error_validating_input=79
readonly error_reading_file=80
readonly error_parsing_options=81
readonly error_missing_options=82
readonly error_unknown_options=83
readonly error_missing_options_arg=84
readonly error_unimplemented_options=85
readonly readonly script_name="${0##*/}"

f_option_flag=0
i_option_flag=0
h_option_flag=0

trap clean_up ERR SIGINT SIGTERM

usage() {
  cat <<MAN
  Usage: ${script_name} [-f <ARG> ] [ -i <ARG> ] || [-h]
  
  DESCRIPTION:
    this tool can be used the extract the overaly configuration (MPLS-L3VPN)
    from MPLS-PE routers based on CISCO-XR OS
  
  OPTIONS:
    -h
      Print this help and exit
    -f
      [mandatory] Specify the MPLS-PE configuration file - Must be in 'cisco/formal' format
    -i
      [mandatory] Specify Bundle-Ethernet interface/s 
      (Examples:
       - Bundle-Ether7 is considering all sub-if belonging to bundle number 7
       - Bundle-Ether7.100 is considering only sub-if 100)
MAN
}

clean_up() {
  if [[ -d "${work_dir}/lsts/${pe_hostname}_${epoch}" ]]; then
    echo -e "Deleting: ${work_dir}/lsts/${pe_hostname}_${epoch} ..."
    rm -rf "${work_dir}/lsts/${pe_hostname}_${epoch}"
  fi

  if [[ -d "${work_dir}/cfgs/${pe_hostname}_${epoch}" ]]; then
    echo -e "Deleting: ${work_dir}/cfgs/${pe_hostname}_${epoch} ..."
    rm -rf "${work_dir}/cfgs/${pe_hostname}_${epoch}"
  fi
}

die() {
  local -r msg="${1}"
  local -r code="${2:-90}"
  echo "${msg}" >&2
  exit "${code}"
}

parse_user_options() {
  while getopts ":f:i:h" opts; do
    case "${opts}" in
    f)
      f_option_flag=1
      readonly f_arg="${OPTARG}"
      ;;
    i)
      i_option_flag=1
      readonly i_arg="${OPTARG}"
      ;;
    h)
      h_option_flag=1
      ;;
    :)
      die "error - mind your options/arguments - [ -h ] to know more" "${error_unknown_options}"
      ;;
    \?)
      die "error - mind your options/arguments - [ -h ] to know more" "${error_missing_options_arg}"
      ;;
    *)
      die "error - mind your options/arguments - [ -h ] to know more" "${error_unimplemented_options}"
      ;;
    esac
  done
}
shift $((OPTIND -1))

# Generating the lst "bundle-if,vrf" main source to be able to extract the level2 lst & the level1 cf
# Input: $f_arg && $i_arg
# Output: $level1_lst
gen_level1_lst_rgx1() {
  echo -e "Generating ${level1_lst} from ${pe_formal_cf} ..."
  $(egrep "^interface ${pe_bundle_if}\svrf" "${pe_formal_cf}" | awk -F " " '{print $2","$4}' > "${level1_lst}")
}

gen_level1_lst_rgx2() {
  echo -e "Generating ${level1_lst} from ${pe_formal_cf} ..."
  $(egrep "^interface ${pe_bundle_if}.*\svrf" "${pe_formal_cf}" | awk -F " " '{print $2","$4}' > "${level1_lst}")
}

# Generating the lst for policy-maps & route-policies to be able to extract the associated overaly cf
# Input: $f_arg && $level1_lst
# Output: $level2_pm_lst && $level2_rpl_lst
gen_level2_lst() {
  if [[ ! -f "${level1_lst}" ]]; then
    die "error - reading file: ${level1_lst}" "${error_reading_file}"
  fi

  echo -e "Generating ${level2_pm_lst} && ${level2_rpl_lst} from ${pe_formal_cf} ..."
  
  while read -r line
  do
    local be_if="$(echo "${line}" | awk -F "," '{print $1}')"
    local vrf_if="$(echo "${line}" | awk -F "," '{print $2}')"
    # to be able to distinguish between rpl-00 & rpl-01
    local vrf_if_rpl="${vrf_if::-3}"
    # workaround to cover rpl name unmatching the vrf name
    local vrf_if_rpl_unmatch="${vrf_if_rpl#"NGDCS-"}"

    if [[ ${vrf_if} != "hsrp" ]]; then
      local policy_map=$(egrep "${vrf_if}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^policy-map.*")
      #local route_policy=$(egrep "${vrf_if_rpl}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^route-policy.*")
      # workaround to cover rpl name unmatching the vrf name
      local route_policy=$(egrep "${vrf_if_rpl_unmatch}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^route-policy.*")

      if [[ ! -z "${policy_map}" ]]; then
        echo -e "${policy_map}" >> "${level2_pm_lst}"
      else
        echo -e "pm empty for line ${be_if},${vrf_if}" >> "${level2_pm_empty_lst}"
      fi  
      
      if [[ ! -z "${route_policy}" ]]; then
        echo -e "${route_policy}" >> "${level2_rpl_lst}"
      else
        echo -e "rpl empty for line ${be_if},${vrf_if}" >> "${level2_rpl_empty_lst}"
      fi
    fi
  done < "${level1_lst}"
}

# Generating level1 cf ( vrf, if, router_[bgp|static|hsrp] )
# Input: $f_arg && $level1_lst
# Output: $level1_vrf_cf && $level1_if_cf && $level1_rbgp_cf && $level1_rstatic_cf && $level1_hsrp_cf
gen_level1_cf() {
  while read -r line
  do
    local be_if="$(echo "${line}" | awk -F "," '{print $1}')"
    local vrf_if="$(echo "${line}" | awk -F "," '{print $2}')"

    if [[ ${vrf_if} != "hsrp" ]]; then
      local vrf=$(egrep "${vrf_if}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^vrf.*")
      local interface=$(egrep "${vrf_if}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^interface.*")
      local router_bgp=$(egrep "${vrf_if}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^router\sbgp.*")
      local router_static=$(egrep "${vrf_if}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^router\sstatic.*")
      local router_hsrp=$(egrep "${vrf_if}|${be_if}$be_if_pad" "${pe_formal_cf}" | egrep "^router\shsrp.*")

      echo -e "Extracting Level1 MPLS-PEs overlay configrations for ${be_if} ..."

      if [[ ! -z "${vrf}" ]]; then
        echo -e "${vrf}" >> "${level1_vrf_cf}"
      else
        echo -e "vrf empty for line ${be_if},${vrf_if}" >> "${level1_vrf_empty_cf}"
      fi  
      
      if [[ ! -z "${interface}" ]]; then
        echo -e "${interface}" >> "${level1_if_cf}"
      else
        echo -e "interface empty for line ${be_if},${vrf_if}" >> "${level1_if_empty_cf}"
      fi  
      
      if [[ ! -z "${router_bgp}" ]]; then
        echo -e "${router_bgp}" >> "${level1_rbgp_cf}"
      else
        echo -e "router_bgp empty for line ${be_if},${vrf_if}" >> "${level1_rbgp_empty_cf}"
      fi  
      
      if [[ ! -z "${router_static}" ]]; then
        echo -e "${router_static}" >> "${level1_rstatic_cf}"
      else
        echo -e "router_static empty for line ${be_if},${vrf_if}" >> "${level1_rstatic_empty_cf}"
      fi  
      
      if [[ ! -z "${router_hsrp}" ]]; then
        echo -e "${router_hsrp}" >> "${level1_hsrp_cf}"
      else
        echo -e "router_hsrp empty for line ${be_if},${vrf_if}" >> "${level1_router_hsrp_empty_cf}"
      fi
    fi
  done < "${level1_lst}"
}

# Generating level2 cf ( policy_map, route_policy )
# Input: $f_arg && $level2_pm_lst && $level2_rpl_lst
# Output: $level2_pm_cf && $level2_rpl_cf
gen_level2_cf() {
  if [[ ! -f "${level2_rpl_lst}" ]]; then
    die "error - reading file: ${level2_rpl_lst}" "${error_reading_file}"
  fi
  
  if [[ ! -f "${level2_pm_lst}" ]]; then
    die "error - reading file: ${level2_pm_lst}" "${error_reading_file}"
  fi
  
  while read -r line
  do
    if [[ ! -z "${line}" ]]; then
      rpl=$(sed -n "/^${line}/,/end-policy/p" "${pe_formal_cf}")
    
      echo -e "Extracting Level2 MPLS-PEs overlay configrations for ${line} ..."

      if [[ ! -z "${rpl}" ]]; then
        echo -e "${rpl}" >> "${level2_rpl_cf}"
        echo -e "!" >> "${level2_rpl_cf}"
      else
        echo -e "rpl empty for line ${be_if},${vrf_if}" >> "${level2_rpl_empty_cf}"
      fi
    fi
  done < "${level2_rpl_lst}"
 
  while read -r line
  do
    if [[ ! -z "${line}" ]]; then
      pm=$(sed -n "/^${line}/,/end-policy-map/p" "${pe_formal_cf}")

      echo -e "Extracting Level2 MPLS-PEs overlay configrations for ${line} ..."

      if [[ ! -z "${pm}" ]]; then
        echo -e "${pm}" >> "${level2_pm_cf}"
        echo -e "!" >> "${level2_pm_cf}"
      else
        echo -e "pm empty for line ${be_if},${vrf_if}" >> "${level2_pm_empty_cf}"
      fi
    fi
  done < "${level2_pm_lst}"
}

parse_user_options "${@}"

if ((h_option_flag)); then
  usage
  exit 0
fi

if ((f_option_flag)) && ((i_option_flag)); then
  readonly pe_hostname=$(echo "${f_arg}" | awk -F "." '{print $1}')
  readonly pe_formal_cf="${work_dir}/${f_arg}"
  readonly pe_bundle_if="${i_arg}"
  readonly be_if_pad=" "
  readonly level1_lst="${work_dir}/lsts/${pe_hostname}_${epoch}/level1.lst"
  readonly level2_lst="${work_dir}/lsts/${pe_hostname}_${epoch}/level2.lst"
  readonly level2_pm_lst="${work_dir}/lsts/${pe_hostname}_${epoch}/level2_pm.lst"
  readonly level2_rpl_lst="${work_dir}/lsts/${pe_hostname}_${epoch}/level2_rpl.lst"
  readonly level1_vrf_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_vrf.cf"
  readonly level1_if_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_if.cf"
  readonly level1_rbgp_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_rbgp.cf"
  readonly level1_rstatic_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_rstatic.cf"
  readonly level1_hsrp_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_hsrp.cf"
  readonly level2_rpl_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level2_rpl.cf"
  readonly level2_pm_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level2_pm.cf"

  readonly level2_pm_empty_lst="${work_dir}/lsts/${pe_hostname}_${epoch}/level2_pm_empty.lst"
  readonly level2_rpl_empty_lst="${work_dir}/lsts/${pe_hostname}_${epoch}/level2_rpl_empty.lst"
  readonly level1_vrf_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_vrf_empty.cf"
  readonly level1_if_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_if_empty.cf"
  readonly level1_rbgp_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_rbgp_empty.cf"
  readonly level1_rstatic_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_rstatic_empty.cf"
  readonly level1_hsrp_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level1_hsrp_empty.cf"
  readonly level2_rpl_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level2_rpl_empty.cf"
  readonly level2_pm_empty_cf="${work_dir}/cfgs/${pe_hostname}_${epoch}/level2_pm_empty.cf"

  readonly pe_bundle_if_rgx1="^Bundle-Ether[0-9]{1,5}\.[0-9]{1,5}$"
  readonly pe_bundle_if_rgx2="^Bundle-Ether[0-9]{1,5}$"

  if [[ ! -f "${pe_formal_cf}" ]]; then
    die "error - file reading failed: ${pe_formal_cf}" "${error_reading_file}"
  fi
  
  if [[ ! "${pe_bundle_if}" =~ ${pe_bundle_if_rgx1} ]] | [[ ! "${pe_bundle_if}" =~ ${pe_bundle_if_rgx2} ]]; then
    die "error - input validation failed: ${pe_bundle_if}" "${error_validating_input}"
  fi
  
  if [[ ! -d "${work_dir}/lsts/${pe_hostname}_${epoch}" ]]; then
    mkdir -p "${work_dir}/lsts/${pe_hostname}_${epoch}"
  fi

  if [[ ! -d "${work_dir}/cfgs/${pe_hostname}_${epoch}" ]]; then
    mkdir -p "${work_dir}/cfgs/${pe_hostname}_${epoch}"
  fi
  
  if [[ "${pe_bundle_if}" =~ ${pe_bundle_if_rgx1} ]]; then
    gen_level1_lst_rgx1
  elif [[ "${pe_bundle_if}" =~ ${pe_bundle_if_rgx2} ]]; then
    gen_level1_lst_rgx2
  fi

  gen_level2_lst
  gen_level1_cf
  gen_level2_cf
else 
  die "error - mind  your options/arguments - [ -h ] to know more" "${error_missing_options}"
fi

exit 0
