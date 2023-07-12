#!/bin/bash
#  Author: Ben Halpern
#  Veracode
#  Microsoft App Center Post Build Script
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# How to use:
#  Place this script inside the root directory of the application connected to Appcenter.
#  Either modify the constants, or comment them out and set them as enviornmental variables from within Micrsoft App Center
#  A "VID" and "VKEY" Variable need to be set within App Center set with the Veracode API ID and Key 
#  If you provide a "SRCCLR_API_TOKEN" variable in App Center then a SCA Agent scan will be performed. https://docs.veracode.com/r/Setting_Up_Agent_Based_Scans
# NOTE: make sure that the archive settings in section SCN010 when creating the archive match that of your configuration
# This shell script is meant to be used as a modifiable document showing a method of integrating veracode into the Microsoft App Center Workflow
# If the build log is able to be pulled out of App Center, then that can be used instead of the Archive being generated.

#::SCN001
##################################################################################
# Script Configuration Switches
##################################################################################
# DEBUG : true -> Uses Hardcoded Test Values
# LEGACY: true -> Uses old method of Gen-IR

LEGACY=false
DEBUG=false

if [ "$LEGACY" = true ]; then
  echo "----------------------------------------------------------------------------"
  echo " Legacy is turned on : $LEGACY"
  echo "----------------------------------------------------------------------------"

fi

if [ "$DEBUG" = true ]; then

  echo "----------------------------------------------------------------------------"
  echo " Debug is turned on : $DEBUG"
  echo "----------------------------------------------------------------------------"

fi

###################################################################################
# XCODE Settings Variables
##################################################################################
# Put the location of Your Signing Identity to sign the code with
CODE_SIGN_IDENTITY_V="" 
CODE_SIGNING_REQUIRED_V='NO' 
CODE_SIGNING_ALLOWED_V='NO'

echo "======================================================================================"
echo "===        Microsoft App Center Post Build Script with Veracode Integration        ==="
#echo "=====        Veracode Unofficial Integration with Microsoft App Center        ========"
echo "============                    Version 1.0.3                     ===================="
echo "======================================================================================"

#::SCN002
# Inspired by and utilized code written by gilmore867
# https://github.com/gilmore867/VeracodePrescanCheck
#################################################################################
# Downloading Latest Version of the Wrapper 
#################################################################################

# Veracode's API Wrapper
# Documentation:
#   https://docs.veracode.com/r/c_about_wrappers
#     
# Description:
#  Makes a curl request to pull down the latest wrapper version information and then uses that to pull down the latest version of the Veracode API Wrapper.

WRAPPER_VERSION=`curl https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/maven-metadata.xml | grep latest |  cut -d '>' -f 2 | cut -d '<' -f 1`
if `wget https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/$WRAPPER_VERSION/vosp-api-wrappers-java-$WRAPPER_VERSION.jar -O VeracodeJavaAPI.jar`; then
                chmod 755 VeracodeJavaAPI.jar
                echo '[INFO] SUCCESSFULLY DOWNLOADED WRAPPER'
  else
                echo '[ERROR] DOWNLOAD FAILED'
                exit 1
fi

#::SCN003
#################################################################################
# Local Script Variables
# Edit these to match your application
#################################################################################

#Default
projectLocation="$appName.xcodeproj"

appName="Signal"
if [ $DEBUG ]; then
  
  projectLocation="./$appName.xcodeproj"

elif [ $LEGACY ]; then
  projectLocation=$APPCENTER_XCODE_PROJECT
fi

#::SCN004
# https://docs.veracode.com/r/r_uploadandscan
###############################################################################
# Parameters for Veracode Upload and Scan
###############################################################################

#APPLICATIONNAME="$appName"
DELETEINCOMPLETE=2                # Default is [(0): don't delete a scan ,(1): delete any scan that is not in progress and doesn't have results ready,(2): delete any scan that doesn't have results ready]  
SANDBOXNAME="MSAPPCENTER"
CREATESANDBOX=true
CREATEPROFILE=false
OPTARGS=''

#::SCN005
echo "========================================================================================================================================================================"
echo "Clean build"
echo "========================================================================================================================================================================"

xcodebuild clean

#::SCN006
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "========================================================================================================================================================================"
echo "Install Gen-IR and Generate Dependencies"
echo "========================================================================================================================================================================"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
brew tap veracode/tap
brew install gen-ir

#::SCN007
# This section is specific to the example which the file is contained
# Make sure to change this to specifically point to the package managers in which your application utilizes
make dependencies
bundle install
pod install

#::SCN008
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "========================================================================================================================================================================"
echo "Reading out the configuration structure"
echo "========================================================================================================================================================================"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
xcodebuild -list 

#::SCN009
#APPCENTER DEFINED ENV VAR
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "= App Center Defined  Variables      ===================================================================================================================================" 
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

echo "APPCENTER_XCODE_PROJECT/WORKSPACE:  $APPCENTER_XCODE_PROJECT"	
echo "APPCENTER_XCODE_SCHEME: $APPCENTER_XCODE_SCHEME"
echo "APPCENTER_SOURCE_DIRECTORY: $APPCENTER_SOURCE_DIRECTORY"
echo "APPCENTER_OUTPUT_DIRECTORY: $APPCENTER_OUTPUT_DIRECTORY"

ls $APPCENTER_SOURCE_DIRECTORY

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
#::SCN010
# Creating XCODE Project Archive to be place within
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "========================================================================================================================================================================"
echo " Creating Archive"
echo "========================================================================================================================================================================"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

if [ "$DEBUG" = true ]; then
      echo "[DEBUG]:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
      xcodebuild archive -workspace Signal.xcworkspace  -configuration Debug -scheme Signal -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath Signal.xcarchive CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY_V CODE_SIGNING_REQUIRED=$CODE_SIGNING_REQUIRED_V CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED_V ENABLE_BITCODE=NO | tee build_log.txt
      echo "========================================================================================================================================================================"
      echo "Output from Build_log.txt #############################################################################################################################################"
      echo "========================================================================================================================================================================"
      cat build_log.txt
else
  if [ "$LEGACY" = true ]; then
        xcodebuild archive -workspace $appName.xcworkspace -configuration Debug -scheme $APPCENTER_XCODE_SCHEME -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath $appName.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt
        echo "========================================================================================================================================================================"
        echo "Output from Build_log.txt #############################################################################################################################################"
        echo "========================================================================================================================================================================"
        cat build_log.txt
  else
    xcodebuild build -project $appName.xcodeproj -scheme $APPCENTER_XCODE_SCHEME -configuration Debug -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY_V CODE_SIGNING_REQUIRED=$CODE_SIGNING_REQUIRED_V CODE_SIGNING_ALLOWED=$CODE_SIGNING_ALLOWED_V ENABLE_BITCODE=NO | gen-ir - $appName.xcarchive ir_files/  --project-path $projectLocation
  fi
fi

#::SCN011
#if including the SRCCLR_API_TOKEN as an enviornmental variable to be able to conduct Veracode SCA Agent-based scan
# comment out the next line if the token is set in appcenter
SRCCLR_API_TOKEN=$SRCCLR_API_TOKEN
if [ -n $SRCCLR_API_TOKEN ]; then
  
  echo "========================================================================================================================================================================"
  echo "RUNNING VERACODE SCA AGENT-BASED SCAN  #################################################################################################################################"
  echo "========================================================================================================================================================================"

  curl -sSL https://download.sourceclear.com/ci.sh | sh
  ls -la 
fi

#gen-ir build_log.txt $appName.xcarchive/IR
#updated version
#::SCN012
echo "========================================================================================================================================================================"
echo "GEN-IR Running #########################################################################################################################################################"
echo "========================================================================================================================================================================"
#https://github.com/veracode/gen-ir/
echo "========================================================================================================================================================================" 
echo "Contents of archive 1####################################################################################################################################################"
echo "========================================================================================================================================================================"

ls -la $appName.xcarchive

#::SCN013
if [ "$LEGACY" = true ]; then
  echo "[LEGACY]::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
  echo "========================================================================================================================================================================" 
  echo "Running modified version to write bitcode out to IR folder #############################################################################################################"
  echo "========================================================================================================================================================================"
  
  # uses old method
  #ls -la $appName.xcarchive
  #mkdir $appName.xcarchive/IR
  #gen-ir build_log.txt Signal.xcarchive/ 
  gen-ir build_log.txt $appName.xcarchive/IR

  echo "========================================================================================================================================================================" 
  echo "Contents of archive  2####################################################################################################################################################"
  echo "========================================================================================================================================================================"

  ls -la $appName.xcarchive/IR
else
  # uses new method
  # https://docs.veracode.com/r/Generate_IR_to_Package_iOS_and_tvOS_Apps
  echo "Default"
  #gen-ir build_log.txt $appName.xcarchive --project-path $projectLocation
fi

#::SCN013
echo "========================================================================================================================================================================"
echo "Zipping up artifact ####################################################################################################################################################"
echo "========================================================================================================================================================================"

if [ "$LEGACY" = true ]; then
  zip -r $appName.zip $appName.xcarchive
else
  zip -r $appName.zip $appName.xcarchive
fi
# This section is also specific to your configuration. Make sure to include the necessary SCA component files such as the lock files from your enviornment
zip -r $appName-Podfile.zip Podfile.lock Gemfile.lock 
ls -la

#::SCN014

mkdir Veracode/
ls -la
cp $appName-Podfile.zip $appName.zip Veracode/
ls -la Veracode/

#::SCN015
echo "========================================================================================================================================================================"
echo "#####  Veracode Upload and Scan  #######################################################################################################################################"
echo "========================================================================================================================================================================"
if [ $DEBUG ]; then
  echo "         0000000000000000000000000          1111111    -----------------------------------------------------------"
  echo "         000000              00000        11 111111    ------- Veracode Upload and Scan --------------------------"
  echo "         111111              11111             1111    -----------------------------------------------------------"
  echo "         010101              10101             1111    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "         110010              11011             1111    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "         111111              11111             1111    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
  echo "         1111111111111111111111111          111111111  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
fi


if [ "$DEBUG" = true ]; then
  echo "[DEBUG]:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
  java -jar VeracodeJavaAPI.jar -action UploadAndScan -vid $VID -vkey $VKEY  -deleteincompletescan 2 -createprofile false -createsandbox true -appname "$APPLICATIONNAME" -sandboxname "$SANDBOXNAME" -version "$APPCENTER_BUILD_ID-v0.3.APPCENTER" -filepath Veracode/
else

 if [ -n $SANDBOXNAME ]; then
    java -jar VeracodeJavaAPI.jar -action UploadAndScan -vid $VID -vkey $VKEY  -deleteincompletescan $DELETEINCOMPLETE -createprofile $CREATEPROFILE -createsandbox $CREATESANDBOX -appname "$APPLICATIONNAME" -sandboxname "$SANDBOXNAME" -version "$APPCENTER_BUILD_ID-APPCENTER" -filepath Veracode/ $OPTARGS
  else
    java -jar VeracodeJavaAPI.jar -action UploadAndScan -vid $VID -vkey $VKEY  -deleteincompletescan $DELETEINCOMPLETE -createprofile $CREATEPROFILE -appname "$APPLICATIONNAME" -version "$APPCENTER_BUILD_ID-APPCENTER" -filepath Veracode/ $OPTARGS
  fi

fi

#EOF
