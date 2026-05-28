#!/usr/bin/env ruby
# Removes duplicate PBXBuildFile entries within the same Sources build phase
# from NetNewsWire.xcodeproj.
#
# Text-level approach: walks each "files = ( ... )" block in PBXSourcesBuildPhase
# sections and removes lines whose "/* NAME.swift in Sources */" comment is
# already seen in that block. Also removes the now-unreferenced PBXBuildFile
# definitions at the top.

require 'set'

project_path = File.expand_path('../../NetNewsWire.xcodeproj/project.pbxproj', __dir__)
content = File.read(project_path)

# 1) Find each PBXSourcesBuildPhase block's `files = ( ... );` list,
#    keep only first occurrence of each "comment" (e.g. "Foo.swift in Sources").
removed_uuids = Set.new
new_content = +""
i = 0
last_save_marker = "/* Begin PBXSourcesBuildPhase section */"
end_marker = "/* End PBXSourcesBuildPhase section */"
sources_section_start = content.index(last_save_marker)
sources_section_end = content.index(end_marker)
abort "Could not locate PBXSourcesBuildPhase section" unless sources_section_start && sources_section_end

before = content[0...sources_section_start]
section = content[sources_section_start...sources_section_end]
after = content[sources_section_end..]

# Within section, find each `files = (` ... `);` block.
new_section = section.gsub(/files = \(([^)]*)\)\s*;/m) do |whole|
  inner = $1
  seen = {}
  out_lines = []
  inner.each_line do |line|
    m = line.match(%r{^(\s*)([0-9A-F]{24})\s*/\*\s*(.+?)\s*\*/\s*,\s*$})
    if m
      uuid, comment = m[2], m[3]
      if seen.key?(comment)
        removed_uuids << uuid
        next  # skip this duplicate
      else
        seen[comment] = uuid
        out_lines << line
      end
    else
      out_lines << line
    end
  end
  "files = (#{out_lines.join})\t;"
end

# 2) Remove the now-orphaned PBXBuildFile definitions in the PBXBuildFile section.
buildfile_section_start = before.index("/* Begin PBXBuildFile section */")
buildfile_section_end = before.index("/* End PBXBuildFile section */")
if buildfile_section_start && buildfile_section_end
  bf_section = before[buildfile_section_start...buildfile_section_end]
  cleaned_bf = bf_section.each_line.reject do |line|
    m = line.match(/^\s*([0-9A-F]{24})\s*\/\*/)
    m && removed_uuids.include?(m[1])
  end.join
  before = before[0...buildfile_section_start] + cleaned_bf + before[buildfile_section_end..]
end

File.write(project_path, before + new_section + after)
puts "Removed #{removed_uuids.size} duplicate build file references."
removed_uuids.each { |u| puts "  - #{u}" }
