WRAPPER_VERSION=`curl https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/maven-metadata.xml | grep latest |  cut -d '>' -f 2 | cut -d '<' -f 1`
if `wget https://repo1.maven.org/maven2/com/veracode/vosp/api/wrappers/vosp-api-wrappers-java/$WRAPPER_VERSION/vosp-api-wrappers-java-$WRAPPER_VERSION.jar -O VeracodeJavaAPI.jar`; then
                chmod 755 VeracodeJavaAPI.jar
                echo '[INFO] SUCCESSFULLY DOWNLOADED WRAPPER'
  else
                echo '[ERROR] DOWNLOAD FAILED'
                exit 1
fi
        

brew tap veracode/tap
brew install gen-ir

pod install
xcodebuild archive -workspace $APPCENTER_XCODE_WORKSPACE -configuration Debug -scheme $APPCENTER_XCODE_SCHEME -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath Signal.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt

ls -la 
gen-ir build_log.txt Signal.xcarchive/IR
zip -r Signal.zip Signal.xcarchive
zip -r Singal-SCA.zip -i Podfile.lock Gemfile.lock Pods/

ls -la


java -verbose -jar VeracodeJavaAPI.jar -action UploadAndScan -vid $VID -vkey $VKEY  -createprofile false  -appname "Gen-IR pipeline"  -version "v0.1.APPCENTER" -filepath /myapp/Signal*.zip

