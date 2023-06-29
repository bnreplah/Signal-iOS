WRAPPER_VERSION=`curl https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/maven-metadata.xml | grep latest |  cut -d '>' -f 2 | cut -d '<' -f 1`
if `wget https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/$WRAPPER_VERSION/vosp-api-wrappers-java-$WRAPPER_VERSION.jar -O VeracodeJavaAPI.jar`; then
                chmod 755 VeracodeJavaAPI.jar
                echo '[INFO] SUCCESSFULLY DOWNLOADED WRAPPER'
  else
                echo '[ERROR] DOWNLOAD FAILED'
                exit 1
fi

#Defined the application name
Appname="Signal"

brew tap veracode/tap
brew install gen-ir

pod install


#if including the SRCCLR_API_TOKEN as an enviornmental variable to be able to conduct Veracode SCA Agent-based scan
echo "RUNNING VERACODE SCA AGENT-BASED SCAN"
(curl -sSL https://download.sourceclear.com/ci.sh) | sh - scan $APPCENTER_SOURCE_DIRECTORY

#APPCENTER DEFINED ENV VAR
echo "APPCENTER_XCODE_PROJECT:  $APPCENTER_XCODE_PROJECT"	
echo "APPCENTER_XCODE_SCHEME: $APPCENTER_XCODE_SCHEME"
echo "APPCENTER_SOURCE_DIRECTORY: $APPCENTER_SOURCE_DIRECTORY"
ls $APPCENTER_SOURCE_DIRECTORY
echo "APPCENTER_OUTPUT_DIRECTORY: $APPCENTER_OUTPUT_DIRECTORY"
xcodebuild archive -workspace $Appname.xcworkspace -configuration Debug -scheme $APPCENTER_XCODE_SCHEME -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath $Appname.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt

ls -la 
gen-ir build_log.txt $Appname.xcarchive/IR
zip -r $Appname.zip $Appname.xcarchive
zip -r $Appname-SCA.zip Podfile.lock Gemfile.lock Pods/
ls -la
mkdir artifacts/
ls -la
cp $Appname-SCA.zip $Appname.zip artifacts/
ls -la artifacts/

java -jar VeracodeJavaAPI.jar -action UploadAndScan -vid $VID -vkey $VKEY  -deleteincompletescan 2 -createprofile false  -appname "Gen-IR pipeline"  -version "v0.3.APPCENTER" -filepath artifacts/Signal.zip

