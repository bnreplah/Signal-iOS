#!/bin/bash
#PREBUILD SCRIPT
echo "Exporting ENV Variables prebuild"
export DEBUG_INFORMATION_FORMAT=dwarf-with-dsym
export CODE_SIGN_IDENTITY="" 
export CODE_SIGNING_REQUIRED=NO 
export CODE_SIGNING_ALLOWED=NO 
export ENABLE_BITCODE=NO
