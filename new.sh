#!/bin/bash


show_help() {
    cat << EOF
Usage: $0 <partition>

This script summarizes the resource usage of nodes in a given SLURM partition.
It prints a node-level usage table:
- CPU, GPU and MEM usage bars:
  - Red    # = your jobs
  - Yellow + = other users' jobs
  - Green  - = free resources
  - Gray   @ = non available resources
- If total resources exceed the dedicated space, bars are scaled
  and displayed inside curly braces {} instead of square brackets [].

Options:
  -h, --help    Show this help message

EOF
    exit 0
}

# --- Parse args ---
if [[ $# -eq 0 ]]; then
    echo "Error: partition name required."
    echo "Try '$0 --help' for usage."
    exit 1
fi


if [[ $1 == "-h" || $1 == "--help" ]]; then
    show_help
fi


PARTITION=${1:-baies}
USER_ME=$(whoami)

BASE_CPU=24
BASE_GPU=8
BASE_MEM=10

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



# ---  Progress bar function ---
progress_bar() {
    local mine=$1       # risorse mie
    local others=$2     # risorse altri
    local total=$3      # totale disponibile
    local length=$4     # lunghezza barra
    local gray=${5:-0}

    local mine_len=0
    local others_len=0
    local free_len=0

    if (( total > length )); then
        # total > length: usa parentesi graffe e calcola proporzioni
        local open="{"; local close="}"
        
        if (( total > 0 )); then
            local free=$((total - mine - others))
            
            # calcola proporzioni con aritmetica intera (moltiplica per 1000 per precisione)
            local m_f=$(( (mine * length * 1000) / total ))
            local o_f=$(( (others * length * 1000) / total ))
            local f_f=$(( (free * length * 1000) / total ))
            
            # arrotonda (aggiunge 500 prima di dividere per 1000)
            mine_len=$(( (m_f > 0 && m_f < 1000) ? 1 : (m_f + 500) / 1000 ))
            others_len=$(( (o_f > 0 && o_f < 1000) ? 1 : (o_f + 500) / 1000 ))
            free_len=$(( (f_f > 0 && f_f < 1000) ? 1 : (f_f + 500) / 1000 ))
            
            # aggiusta per avere somma = length
            local sum=$((mine_len + others_len + free_len))
            local diff=$((length - sum))
            
            # aggiungi la differenza al segmento più grande
            if (( mine_len >= others_len && mine_len >= free_len )); then
                mine_len=$((mine_len + diff))
            elif (( others_len >= free_len )); then
                others_len=$((others_len + diff))
            else
                free_len=$((free_len + diff))
            fi
        else
            free_len=$length
        fi

        echo -ne "$open"
        if (( gray )); then
            printf "\033[90m%${length}s\033[0m" "" | tr ' ' '@'
        else
            (( mine_len   > 0 )) && printf "\033[31m%${mine_len}s" "" | tr ' ' '#'
            (( others_len > 0 )) && printf "\033[33m%${others_len}s" "" | tr ' ' '+'
            (( free_len   > 0 )) && printf "\033[32m%${free_len}s" "" | tr ' ' '-'
            echo -ne "\033[0m"
        fi
        echo -ne "$close"
    else
        # total <= length: usa parentesi quadre, 1 carattere = 1 risorsa
        local open="["; local close="]"
        
        mine_len=$mine
        others_len=$others
        free_len=$((total - mine - others))
        
        local bar_len=$((mine_len + others_len + free_len))
        local padding=$((length - bar_len))
        
        echo -ne "$open"
        if (( gray )); then
            printf "\033[90m%${bar_len}s\033[0m" "" | tr ' ' '@'
        else
            (( mine_len   > 0 )) && printf "\033[31m%${mine_len}s" "" | tr ' ' '#'
            (( others_len > 0 )) && printf "\033[33m%${others_len}s" "" | tr ' ' '+'
            (( free_len   > 0 )) && printf "\033[32m%${free_len}s" "" | tr ' ' '-'
            echo -ne "\033[0m"
        fi
        echo -ne "$close"
        
        # aggiungi spazi per arrivare a length caratteri totali
        (( padding > 0 )) && printf "%${padding}s" ""
    fi

    local used=$((mine + others))
    local percent=0
    (( total > 0 )) && percent=$((100 * used / total))
    printf " %3d%%" "$percent"
}


# --------------------------
# 1. INFO NODI DA SINFO
# --------------------------
NODES=()
SINFO_DATA=$(sinfo -p "$PARTITION" -N -O nodehost,cpusstate,allocmem,memory,statecompact:10,Gres:70 -h)
while read -r NODE CPUSSTATE ALLOCMEM MEM STATE GRES; do
  [[ -z "$NODE" ]] && continue
  NODES+=("$NODE")
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
      #USED_MEM_MB[$NODE]=$(( ${USED_MEM_MB[$NODE]:-0} + MEM_REQ ))

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






# --- 4. Node table ---

# get the maximum number of CPU and GPU

MAX_CPU=${TOTAL_CPU[0]}; for v in "${TOTAL_CPU[@]}"; do ((v>MAX_CPU)) && MAX_CPU=$v; done
MAX_GPU=${TOTAL_GPU[0]}; for v in "${TOTAL_GPU[@]}"; do ((v>MAX_GPU)) && MAX_GPU=$v; done

LEN_CPU=$(( MAX_CPU < BASE_CPU ? MAX_CPU : BASE_CPU ))
LEN_GPU=$(( MAX_GPU < BASE_GPU ? MAX_GPU : BASE_GPU ))

CPU_COL=$((LEN_CPU+17))
GPU_COL=$((LEN_GPU+17))
MEM_COL=$((BASE_MEM+25))






printf "\n=== NODES in partition %s ===\n" "$PARTITION"
printf "%-15s | %-*s | %-*s | %-*s\n" "NODE" $CPU_COL "CPU usage" $GPU_COL "GPU usage" $MEM_COL "MEM usage [MB]"
printf "%s+%s+%s+%s\n" \
       "$(printf '%0.s-' $(seq 1 16))" \
       "$(printf '%0.s-' $(seq 1 $((CPU_COL+2))))" \
       "$(printf '%0.s-' $(seq 1 $((GPU_COL+2))))" \
       "$(printf '%0.s-' $(seq 1 $((MEM_COL+2))))"



for NODE in $(printf "%s\n" "${NODES[@]}" | sort); do
    CPU_TOTAL=${TOTAL_CPU[$NODE]}
    GPU_TOTAL=${TOTAL_GPU[$NODE]}
    MEM_TOTAL=${TOTAL_MEM_MB[$NODE]}
    CPU_USED=${USED_CPU[$NODE]:-0}
    GPU_USED=${USED_GPU[$NODE]:-0}
    MEM_USED=${USED_MEM_MB[$NODE]:-0}
    CPU_MY=${MY_CPU[$NODE]:-0}
    GPU_MY=${MY_GPU[$NODE]:-0}
    MEM_MY=${MY_MEM_MB[$NODE]:-0}
    CPU_OTHERS=$((CPU_USED - CPU_MY))
    GPU_OTHERS=$((GPU_USED - GPU_MY))
    MEM_OTHERS=$((MEM_USED - MEM_MY))


    #echo "$n : CPU [$CPU_MY|$CPU_OTHERS|$CPU_TOTAL]  GPU [$GPU_MY|$GPU_OTHERS|$GPU_TOTAL]  MEM [$MEM_MY + $MEM_OTHERS = $MEM_USED|$MEM_TOTAL]"

    # Nodo inattivo?
    GRAY=0
    STATE=${NODE_STATE[$NODE]}
    # Se lo stato contiene uno dei flag "drain", "fail", "down", "unknown", allora grigio
    if [[ $STATE =~ drain|drain*|fail|down|unknown ]]; then
        GRAY=1
    fi

    printf "%-15s | " "$NODE"
    progress_bar $CPU_MY $CPU_OTHERS $CPU_TOTAL $LEN_CPU $GRAY
    printf " (%3d/%-3d) | " "$CPU_USED" "$CPU_TOTAL"

    if (( GPU_TOTAL > 0 )); then
        progress_bar $GPU_MY $GPU_OTHERS $GPU_TOTAL $LEN_GPU $GRAY
        printf " (%3d/%-3d) | " "$GPU_USED" "$GPU_TOTAL"
    else
	# check if this works even if base gpu is different from 8 ! 
        if (( GRAY )); then
            printf "\033[90m[   N/A   ]\033[0m %*s (  0/  0)" $((LEN_GPU-7)) ""
        else
            printf "[   N/A   ] %*s (  0/  0)" $((LEN_GPU-7)) ""
        fi
    fi

    progress_bar $MEM_MY $MEM_OTHERS $MEM_TOTAL $BASE_MEM $GRAY
    # translate in GB!
    printf " (%7d/%-7d) " "$MEM_USED" "$MEM_TOTAL"
    printf "\n"


done


