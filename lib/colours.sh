#!/usr/bin/env bash
# ============================================================================
# copt — Colour helpers and logging functions
# ============================================================================

# ----- colour codes ---------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RST='\033[0m'  C_RED='\033[0;31m'  C_GRN='\033[0;32m'
    readonly C_YEL='\033[0;33m'  C_BLU='\033[0;34m'  C_CYN='\033[0;36m'
    readonly C_BLD='\033[1m'
else
    readonly C_RST='' C_RED='' C_GRN='' C_YEL='' C_BLU='' C_CYN='' C_BLD=''
fi

# ----- logging functions ----------------------------------------------------
info()  { printf "${C_BLU}[INFO]${C_RST}  %s\n" "$*"; }
ok()    { printf "${C_GRN}[ OK ]${C_RST}  %s\n" "$*"; }
warn()  { printf "${C_YEL}[WARN]${C_RST}  %s\n" "$*" >&2; }
die()   { printf "${C_RED}[ERR ]${C_RST}  %s\n" "$*" >&2; exit 1; }
