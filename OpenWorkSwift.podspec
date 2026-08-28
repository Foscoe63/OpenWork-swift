Pod::Spec.new do |spec|
  spec.name         = "OpenWorkSwift"
  spec.version      = "1.0.0"
  spec.summary      = "OpenWork-Swift: AI Agent Desktop Application"
  spec.description  = "A comprehensive Swift implementation of OpenWork with advanced AI agent capabilities and model provider management."
  spec.author       = 'OpenWork'
  spec.license      = "MIT"
  spec.source       = { :git => "https://github.com/OpenWork-Team/OpenWork-Swift.git", :tag => spec.version }
  
  spec.platforms    = { :os => "ios", :macos => "10.15" }
  spec.source_files = "Sources/**/*.{swift,m}"
  
  spec.dependency "OpenWorkCore"
  spec.dependency "OpenWorkAgents"
  
  spec.swift_version = "5.9"
end
