brew tap veracode/tap
brew install gen-ir

pod install
xcodebuild archive -project $APPCENTER_XCODE_PROJECT -configuration Debug -scheme $APPCENTER_XCODE_SCHEME -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath Signal.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt

ls -la 
gen-ir build_log.txt Signal.xcarchive/IR
zip -r Signal.zip Signal.xcarchive
zip -r Singal-SCA.zip -i Podfile.lock Gemfile.lock Pods/

ls -la
docker run -it --rm veracode/api-wrapper-java:cmd -help
docker run -it --rm  --env VERACODE_API_KEY_ID=$VID  --env VERACODE_API_KEY_SECRET=$VKEY -v ~/:/myapp  veracode/api-wrapper-java:cmd  -action UploadAndScan -createprofile false  -appname "Gen-IR pipeline"  -version "v0.1.APPCENTER" -filepath /myapp/Signal*.zip

