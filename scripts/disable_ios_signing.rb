project_paths = Dir['ios/**/*.xcodeproj/project.pbxproj']
abort('No iOS Xcode projects found') if project_paths.empty?

project_paths.each do |project_path|
  project = File.read(project_path)

  project.gsub!(/CODE_SIGN_STYLE = Automatic;/, 'CODE_SIGN_STYLE = Manual;')
  project.gsub!(/DEVELOPMENT_TEAM = [^;]+;/, 'DEVELOPMENT_TEAM = "";')
  project.gsub!(/CODE_SIGN_IDENTITY = "[^"]*";/, 'CODE_SIGN_IDENTITY = "";')
  project.gsub!(/CODE_SIGN_IDENTITY = [^;]+;/, 'CODE_SIGN_IDENTITY = "";')
  project.gsub!(/PROVISIONING_PROFILE_SPECIFIER = [^;]+;/, 'PROVISIONING_PROFILE_SPECIFIER = "";')
  project.gsub!(/CODE_SIGNING_ALLOWED = [^;]+;/, 'CODE_SIGNING_ALLOWED = NO;')
  project.gsub!(/CODE_SIGNING_REQUIRED = [^;]+;/, 'CODE_SIGNING_REQUIRED = NO;')
  project.gsub!(/ENABLE_USER_SCRIPT_SANDBOXING = [^;]+;/, 'ENABLE_USER_SCRIPT_SANDBOXING = NO;')

  project.gsub!(/buildSettings = \{.*?\n\t\t\t\};/m) do |block|
    insertions = []
    insertions << "\t\t\t\tCODE_SIGNING_ALLOWED = NO;" unless block.include?('CODE_SIGNING_ALLOWED')
    insertions << "\t\t\t\tCODE_SIGNING_REQUIRED = NO;" unless block.include?('CODE_SIGNING_REQUIRED')
    insertions << "\t\t\t\tCODE_SIGN_IDENTITY = \"\";" unless block.include?('CODE_SIGN_IDENTITY')
    insertions << "\t\t\t\tDEVELOPMENT_TEAM = \"\";" unless block.include?('DEVELOPMENT_TEAM')
    insertions << "\t\t\t\tPROVISIONING_PROFILE_SPECIFIER = \"\";" unless block.include?('PROVISIONING_PROFILE_SPECIFIER')
    insertions << "\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;" unless block.include?('ENABLE_USER_SCRIPT_SANDBOXING')
    next block if insertions.empty?

    block.sub(/\n\t\t\t\};/, "\n#{insertions.join("\n")}\n\t\t\t};")
  end

  File.write(project_path, project)
  puts "Patched unsigned build settings in #{project_path}"
end
