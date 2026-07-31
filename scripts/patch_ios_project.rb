bundle_id = ENV.fetch('BUNDLE_ID')
team_id = ENV.fetch('TEAM_ID')
profile_name = ENV.fetch('PROFILE_NAME')
export_method = ENV.fetch('EXPORT_METHOD', 'ad-hoc')
export_method = 'ad-hoc' if export_method.strip.empty?
code_sign_identity = ENV.fetch('IOS_CODE_SIGN_IDENTITY', 'Apple Distribution')

project_path = 'ios/Runner.xcodeproj/project.pbxproj'
project = File.read(project_path)
project.gsub!(/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/, "PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};")
project.gsub!(/DEVELOPMENT_TEAM = [^;]+;/, "DEVELOPMENT_TEAM = #{team_id};")
project.gsub!(/CODE_SIGN_STYLE = Automatic;/, 'CODE_SIGN_STYLE = Manual;')
project.gsub!(/CODE_SIGN_IDENTITY = "[^"]*";/, "CODE_SIGN_IDENTITY = \"#{code_sign_identity}\";")
if project.match?(/PROVISIONING_PROFILE_SPECIFIER = .*;/)
  project.gsub!(/PROVISIONING_PROFILE_SPECIFIER = .*;/, "PROVISIONING_PROFILE_SPECIFIER = \"#{profile_name}\";")
else
  project.gsub!(
    /CODE_SIGN_STYLE = Manual;/,
    "CODE_SIGN_STYLE = Manual;\n\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = \"#{profile_name}\";"
  )
end
File.write(project_path, project)

export_options = <<~PLIST
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>method</key>
    <string>#{export_method}</string>
    <key>teamID</key>
    <string>#{team_id}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
      <key>#{bundle_id}</key>
      <string>#{profile_name}</string>
    </dict>
  </dict>
  </plist>
PLIST

File.write('ios/ExportOptions.plist', export_options)
