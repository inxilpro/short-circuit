import SwiftUI

struct ApplicationsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Applications Are Coming",
            systemImage: "app.dashed",
            description: Text("Soon you’ll be able to pick an app, see everything it can open, and make it the default for several types at once.")
        )
    }
}

#Preview {
    ApplicationsPlaceholderView()
        .frame(width: 600, height: 400)
}
