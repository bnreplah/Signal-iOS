#!/bin/bash
#################################################################################
# Downloading Latest Version of the Wrapper 
#################################################################################

WRAPPER_VERSION=`curl https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/maven-metadata.xml | grep latest |  cut -d '>' -f 2 | cut -d '<' -f 1`
if `wget https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/$WRAPPER_VERSION/vosp-api-wrappers-java-$WRAPPER_VERSION.jar -O VeracodeJavaAPI.jar`; then
                chmod 755 VeracodeJavaAPI.jar
                echo '[INFO] SUCCESSFULLY DOWNLOADED WRAPPER'
  else
                echo '[ERROR] DOWNLOAD FAILED'
                exit 1
fi

#################################################################################
# Local Script Variables
# Edit these to match your application
#################################################################################

appname="Signal"
projectLocation="$appname.xcodeproj"
debug=true

brew tap veracode/tap
brew install gen-ir
make dependencies
bundle install
pod install


#APPCENTER DEFINED ENV VAR
echo "APPCENTER_XCODE_PROJECT/WORKSPACE:  $APPCENTER_XCODE_PROJECT"	
echo "APPCENTER_XCODE_SCHEME: $APPCENTER_XCODE_SCHEME"
echo "APPCENTER_SOURCE_DIRECTORY: $APPCENTER_SOURCE_DIRECTORY"
ls $APPCENTER_SOURCE_DIRECTORY
echo "APPCENTER_OUTPUT_DIRECTORY: $APPCENTER_OUTPUT_DIRECTORY"
echo "========================================================================================================================================================================"
echo "creating archive"
echo "========================================================================================================================================================================"
xcodebuild archive -workspace $appname.xcworkspace -configuration Debug -scheme $APPCENTER_XCODE_SCHEME -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath $appname.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt
if [$debug]; then
      xcodebuild archive -workspace Signal.xcworkspace  -configuration Debug -scheme Signal-Veracode -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath Signal.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt
      echo "========================================================================================================================================================================"
      echo "Output from Build_log.txt"
      echo "========================================================================================================================================================================"
      cat build_log.txt
fi

#if including the SRCCLR_API_TOKEN as an enviornmental variable to be able to conduct Veracode SCA Agent-based scan
echo "========================================================================================================================================================================"
echo "RUNNING VERACODE SCA AGENT-BASED SCAN"
echo "========================================================================================================================================================================"
SRCCLR_API_TOKEN=$SRCCLR_API_TOKEN
curl -sSL https://download.sourceclear.com/ci.sh | sh



ls -la 
#gen-ir build_log.txt $appname.xcarchive/IR
#updated version
echo "========================================================================================================================================================================"
echo "GEN-IR Running ##############################################################################"
echo "========================================================================================================================================================================"
gen-ir build_log.txt $appname.xcarchive/ --project-path $projectLocation 

if [$debug]; then
  echo "========================================================================================================================================================================" 
  echo "Running modified version to write bitcode out to IR folder"
  echo "========================================================================================================================================================================"
  gen-ir build_log.txt Signal.xcarchive/IR --project-path ./Signal.xcproj
fi


echo "========================================================================================================================================================================"
echo "Zipping up artifact"
echo "========================================================================================================================================================================"
zip -r $appname.zip $appname.xcarchive
zip -r $appname-Podfile.zip Podfile.lock Gemfile.lock Pods/
ls -la

mkdir Veracode/
ls -la
cp $appname-Podfile.zip $appname.zip Veracode/
ls -la Veracode/

java -jar VeracodeJavaAPI.jar -action UploadAndScan -vid $VID -vkey $VKEY  -deleteincompletescan 2 -createprofile false  -appname "Gen-IR pipeline"  -version "$APPCENTER_BUILD_ID-v0.3.APPCENTER" -filepath Veracode/

