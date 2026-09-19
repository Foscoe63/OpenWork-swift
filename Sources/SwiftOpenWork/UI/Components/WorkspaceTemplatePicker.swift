import SwiftUI
import SwiftOpenWorkEngine

/// The "Start from" row in both new-workspace sheets. Starter files are only written into a new
/// or empty folder, which the caption says so nobody expects them in an existing project.
struct WorkspaceTemplatePicker: View {
    @Binding var template: WorkspaceBootstrap.StarterTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start From")
                .font(.system(size: 11, weight: .semibold))
            Picker("", selection: $template) {
                ForEach(WorkspaceBootstrap.StarterTemplate.allCases) { starter in
                    Text(starter.displayName).tag(starter)
                }
            }
            .pickerStyle(.menu)
            Text("A new or empty folder gets these files and a git repository. A folder with files in it is left as it is.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
