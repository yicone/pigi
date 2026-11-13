import SwiftUI

/// Title and one line of explanation shared by every page.
struct PageHeader: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 18, weight: .semibold))
            Text(note)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

