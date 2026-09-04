import SwiftUI

struct MainMenuView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            if selectedTab == 0 {
                DashboardView()
            } else if selectedTab == 1 {
                LogsView()
            } else {
                SettingsView()
            }

            Divider()
                .background(Theme.green.opacity(0.3))

            // Custom Tab Bar
            HStack {
                TabBarButton(icon: "chart.bar.fill", title: "Dashboard", isSelected: selectedTab == 0) {
                    selectedTab = 0
                }

                TabBarButton(icon: "list.bullet.rectangle.portrait", title: "Logs", isSelected: selectedTab == 1) {
                    selectedTab = 1
                }

                TabBarButton(icon: "gearshape.fill", title: "Settings", isSelected: selectedTab == 2) {
                    selectedTab = 2
                }
            }
            .padding(.vertical, 8)
            .background(Theme.bg)
        }
        .overlay(ScanlineOverlay())
        .overlay(
            // Matches the popover's own native corner radius — a square (radius 0)
            // border drawn on top of a rounded popover window visibly clips at the
            // corners instead of tracing its edge.
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.green.opacity(0.4), lineWidth: 1)
        )
        // Fixed to match popover.contentSize (SRMAutoconnectApp.swift) so every tab
        // reports the same intrinsic size — otherwise NSHostingController resizes
        // the popover on each tab switch / open, which is the "laggy" jump.
        .frame(width: 300, height: 400)
    }
}

struct TabBarButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(Theme.mono(10))
            }
            .foregroundColor(isSelected ? Theme.green : (isHovering ? Theme.green.opacity(0.85) : Theme.dimGreen))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.green.opacity(isHovering ? 0.12 : 0))
            )
            .scaleEffect(isHovering ? 1.06 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
