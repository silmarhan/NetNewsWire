#!/usr/bin/env ruby
# Usage: ruby scripts/superpowers/add_file_to_target.rb <relative_file_path> <TargetName> [<TargetName> ...]
require 'xcodeproj'

file_path = ARGV[0]
targets = ARGV[1..]
abort "Usage: add_file_to_target.rb <path> <Target> [<Target> ...]" if file_path.nil? || targets.nil? || targets.empty?

project_path = File.expand_path('../../NetNewsWire.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)

# Find or create the parent group along the file path
parts = file_path.split('/')
group = project.main_group
parts[0..-2].each do |part|
  child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == part }
  group = child || group.new_group(part, part)
end

# Add the file ref if not present
file_name = parts.last
existing = group.files.find { |f| f.path == file_name || f.display_name == file_name }
file_ref = existing || group.new_reference(file_name)

# Add to each target's sources build phase if not already there
targets.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  abort "Target #{target_name} not found" unless target
  unless target.source_build_phase.files_references.include?(file_ref)
    target.add_file_references([file_ref])
  end
end

project.save
puts "Added #{file_path} to #{targets.join(', ')}"
