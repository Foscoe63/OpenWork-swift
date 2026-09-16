Pod::Spec.new do |spec|
  spec.name         = "SwiftOpenWork"
  spec.version      = "1.0.0"
  spec.summary      = "SwiftOpenWork: AI Agent Desktop Application"
  spec.description  = "SwiftOpenWork, a native macOS app for autonomous AI agents with local and cloud model providers. Not affiliated with any other product named OpenWork."
  spec.author       = 'SwiftOpenWork'
  spec.license      = "MIT"
  spec.source       = { :git => "https://github.com/Foscoe63/OpenWork-swift.git", :tag => spec.version }
  
  spec.platforms    = { :os => "ios", :macos => "10.15" }
  spec.source_files = "Sources/**/*.{swift,m}"
  
  spec.dependency "OpenWorkCore"
  spec.dependency "OpenWorkAgents"
  
  spec.swift_version = "5.9"
end
