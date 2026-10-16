import SwiftUI

/// Edit one Enhance template: its name and the layout/instructions the notes should follow.
struct TemplateEditor: View {
    @State var template: NoteTemplate
    @Environment(TemplateStore.self) private var templates
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $template.name)
                }
                Section {
                    TextEditor(text: $template.instructions)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                } header: {
                    Text("What the notes should look like")
                } footer: {
                    Text("Write the headings and kinds of content you want, in Markdown — e.g. “## Decisions”, “- [ ] Task — owner”. Enhance always keeps your own notes first and never makes things up.")
                }
                Section {
                    if template.isBuiltIn {
                        Button("Reset to the original") {
                            templates.reset(template.id)
                            dismiss()
                        }
                    } else {
                        Button("Delete template", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(template.name.isEmpty ? "Template" : template.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if template.name.trimmingCharacters(in: .whitespaces).isEmpty { template.name = "Untitled template" }
                        templates.update(template)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete “\(template.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    templates.delete(template.id)
                    dismiss()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }
}
