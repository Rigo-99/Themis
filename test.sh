#!/bin/bash

PARTITION=${1:-gpu_p2}
USER_ME=$(whoami)

declare -A TOTAL_CPU USED_CPU MY_CPU
declare -A TOTAL_MEM_MB USED_MEM_MB MY_MEM_MB
declare -A TOTAL_GPU USED_GPU MY_GPU
declare -A NODE_STATE

declare -A EXPANDED_CACHE
expand_nodes_cached() {
  local spec="$1"
  if [[ ! "$spec" =~ \[ ]]; then
    printf "%s\n" "$spec"
    return
  fi
  if [[ -n "${EXPANDED_CACHE[$spec]:-}" ]]; then
    printf "%s\n" "${EXPANDED_CACHE[$spec]}"
    return
  fi
  local out
  out=$(scontrol show hostnames "$spec" 2>/dev/null || true)
  [[ -z "$out" ]] && out="$spec"
  EXPANDED_CACHE[$spec]="$out"
  printf "%s\n" "$out"
}

mem_to_mb() {
    local mem="$1"
    local value unit
    value="${mem%[GMK]}"
    unit="${mem: -1}"
    case "$unit" in
        G|g) echo $((value * 1024)) ;;
        M|m) echo "$value" ;;
        K|k) echo $((value / 1024)) ;;
        *) echo "Unknown unit $mem" >&2; return 1 ;;
    esac
}

# --------------------------
# 1. INFO NODI DA SINFO
# --------------------------
SINFO_DATA=$(sinfo -p "$PARTITION" -N -O nodehost,cpusstate,allocmem,memory,statecompact:10,Gres:70 -h)
while read -r NODE CPUSSTATE ALLOCMEM MEM STATE GRES; do
  [[ -z "$NODE" ]] && continue
  IFS='/' read -r CPUS_ALLOC CPUS_IDLE CPUS_OTHER CPUS_TOTAL <<< "$CPUSSTATE"
  TOTAL_CPU[$NODE]=$((CPUS_ALLOC + CPUS_IDLE + CPUS_OTHER))
  TOTAL_MEM_MB[$NODE]=$MEM
  USED_MEM_MB[$NODE]=$ALLOCMEM
  NODE_STATE[$NODE]=$STATE

  # GPU totale
  if [[ $GRES =~ gpu:[^:]+:([0-9]+) ]]; then
    TOTAL_GPU[$NODE]=${BASH_REMATCH[1]}
  elif [[ $GRES =~ gpu:([0-9]+) ]]; then
    TOTAL_GPU[$NODE]=${BASH_REMATCH[1]}
  else
    TOTAL_GPU[$NODE]=0
  fi
done <<< "$SINFO_DATA"

# --------------------------
# 2. USO JOBS DA SQUEUE (OTTIMIZZATO)
# --------------------------
squeue_all=$(squeue -h -p "$PARTITION" -o "%A %u %C %b %D %m %R" 2>/dev/null || true)

if [[ -n "$squeue_all" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Split riga in campi
    IFS=' ' read -r JOBID JOBUSER CPU_REQ GRES_FIELD NUMNODES MEM_REQ_RAW NODELIST_FIELD <<< "$line"

    MEM_REQ=$(mem_to_mb "$MEM_REQ_RAW")

    # Determina GPU dal campo GRES
    GPU_REQ=0
    if [[ $GRES_FIELD =~ gpu:([0-9]+) ]]; then GPU_REQ=${BASH_REMATCH[1]}; fi

    # Se single-node
    if (( NUMNODES == 1 )); then
      NODE=$(expand_nodes_cached "$NODELIST_FIELD")
      USED_CPU[$NODE]=$(( ${USED_CPU[$NODE]:-0} + CPU_REQ ))
      USED_GPU[$NODE]=$(( ${USED_GPU[$NODE]:-0} + GPU_REQ ))
      USED_MEM_MB[$NODE]=$(( ${USED_MEM_MB[$NODE]:-0} + MEM_REQ ))

      if [[ "$JOBUSER" == "$USER_ME" ]]; then
        MY_CPU[$NODE]=$(( ${MY_CPU[$NODE]:-0} + CPU_REQ ))
        MY_GPU[$NODE]=$(( ${MY_GPU[$NODE]:-0} + GPU_REQ ))
        MY_MEM_MB[$NODE]=$(( ${MY_MEM_MB[$NODE]:-0} + MEM_REQ ))
      fi

    else
      # Multi-nodo: usa scontrol per distribuire risorse
      SINFO=$(scontrol show job "$JOBID" 2>/dev/null || true)

      CPU_TOTAL=0
      GPU_TOTAL=0
      MEM_TOTAL=0
      if [[ $SINFO =~ NumCPUs=([0-9]+) ]]; then CPU_TOTAL=${BASH_REMATCH[1]}; fi
      if [[ $SINFO =~ TresPerNode=([^[:space:]]+) ]]; then
        TRES=${BASH_REMATCH[1]}
        if [[ $TRES =~ gpu:([0-9]+) ]]; then GPU_TOTAL=${BASH_REMATCH[1]}; fi
      fi
      if [[ $SINFO =~ AllocMem=([0-9]+) ]]; then MEM_TOTAL=${BASH_REMATCH[1]}; fi

      mapfile -t JOB_NODES < <(expand_nodes_cached "$NODELIST_FIELD")
      NN=${#JOB_NODES[@]}
      (( NN == 0 )) && NN=1
      CPU_PER_NODE=$(( CPU_TOTAL / NN ))
      GPU_PER_NODE=$(( GPU_TOTAL / NN ))
      MEM_PER_NODE=$(( MEM_TOTAL / NN ))

      for nd in "${JOB_NODES[@]}"; do
        USED_CPU[$nd]=$(( ${USED_CPU[$nd]:-0} + CPU_PER_NODE ))
        USED_GPU[$nd]=$(( ${USED_GPU[$nd]:-0} + GPU_PER_NODE ))
        USED_MEM_MB[$nd]=$(( ${USED_MEM_MB[$nd]:-0} + MEM_PER_NODE ))

        if [[ "$JOBUSER" == "$USER_ME" ]]; then
          MY_CPU[$nd]=$(( ${MY_CPU[$nd]:-0} + CPU_PER_NODE ))
          MY_GPU[$nd]=$(( ${MY_GPU[$nd]:-0} + GPU_PER_NODE ))
          MY_MEM_MB[$nd]=$(( ${MY_MEM_MB[$nd]:-0} + MEM_PER_NODE ))
        fi
      done
    fi

  done <<< "$squeue_all"
fi

# --------------------------
# 3. STAMPA VARIABILI ORDINATE
# --------------------------
echo
echo "=== VARIABILI NODI (ORDINATE) ==="
for n in $(printf "%s\n" "${!TOTAL_CPU[@]}" | sort -V); do
  echo "NODE = $n"
  echo "  STATE            = ${NODE_STATE[$n]}"
  echo "  TOTAL_CPU        = ${TOTAL_CPU[$n]}"
  echo "  USED_CPU         = ${USED_CPU[$n]:-0}"
  echo "  MY_CPU           = ${MY_CPU[$n]:-0}"
  echo "  TOTAL_GPU        = ${TOTAL_GPU[$n]:-0}"
  echo "  USED_GPU         = ${USED_GPU[$n]:-0}"
  echo "  MY_GPU           = ${MY_GPU[$n]:-0}"
  echo "  TOTAL_MEM_MB     = ${TOTAL_MEM_MB[$n]:-0}"
  echo "  USED_MEM_MB      = ${USED_MEM_MB[$n]:-0}"
  echo "  MY_MEM_MB        = ${MY_MEM_MB[$n]:-0}"
  echo
done

