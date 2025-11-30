import SwiftUI
import SwiftUIQuery

struct CreatePostView: View {
    @Environment(\.mockServer) private var server
    @Environment(\.dismiss) private var dismiss
    @Environment(\.queryClient) private var client

    @State private var title = ""
    @State private var content = ""
    @State private var isSubmitting = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            Form {
                Section("New Post") {
                    TextField("Title", text: $title)
                    TextField("Content", text: $content, axis: .vertical)
                        .lineLimit(5...10)
                }

                if let error = error {
                    Section {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        Task {
                            await createPost()
                        }
                    }
                    .disabled(title.isEmpty || content.isEmpty || isSubmitting)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Creating...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func createPost() async {
        isSubmitting = true
        error = nil

        do {
            // Use author ID 1 for demo purposes
            _ = try await server.createPost(title: title, body: content, authorId: 1)

            // Invalidate posts cache so the list refreshes
            await client.invalidate(tag: .posts)

            dismiss()
        } catch {
            self.error = error
        }

        isSubmitting = false
    }
}

struct AddCommentView: View {
    let postId: Int

    @Environment(\.mockServer) private var server
    @Environment(\.dismiss) private var dismiss
    @Environment(\.queryClient) private var client

    @State private var commentBody = ""
    @State private var isSubmitting = false
    @State private var error: Error?

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Comment") {
                    TextField("Your comment", text: $commentBody, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = error {
                    Section {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Comment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task {
                            await addComment()
                        }
                    }
                    .disabled(commentBody.isEmpty || isSubmitting)
                }
            }
            .overlay {
                if isSubmitting {
                    ProgressView("Submitting...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func addComment() async {
        isSubmitting = true
        error = nil

        do {
            // Use author ID 1 for demo purposes
            _ = try await server.createComment(postId: postId, authorId: 1, body: commentBody)

            // Invalidate this post's comments
            await client.invalidate(tag: .postComments(postId))

            dismiss()
        } catch {
            self.error = error
        }

        isSubmitting = false
    }
}
