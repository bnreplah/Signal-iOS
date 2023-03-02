brew tap veracode/tap
brew install gen-ir

pod install
xcodebuild archive -workspace Signal.xcworkspace  -configuration Debug -scheme Signal-Veracode -destination generic/platform=iOS DEBUG_INFORMATION_FORMAT=dwarf-with-dsym -archivePath Signal.xcarchive CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_BITCODE=NO | tee build_log.txt

ls -la 
gen-ir build_log.txt Signal.xcarchive/IR
zip -r Signal.zip Signal.xcarchive
zip Singal-Podfile.zip podfile.lock 

ls -la
