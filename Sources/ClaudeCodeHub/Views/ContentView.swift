import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: Theme.sidebarWidth)

                Divider().background(Theme.border)

                MainColumnView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if app.rightPanelVisible {
                    Divider().background(Theme.border)
                    RightPanelView()
                        .frame(width: Theme.rightPanelWidth)
                }
            }
            StatusBar()
        }
        .background(Theme.bg1)
        .foregroundStyle(Theme.text1)
        .sheet(isPresented: $app.showNewSessionModal) {
            NewSessionModal()
                .environmentObject(app)
                .environmentObject(app.sessions)
        }
        .sheet(isPresented: $app.showSettings) {
            SettingsSheet()
                .environmentObject(app)
                .environmentObject(app.prefs)
                .environmentObject(app.importer)
                .environmentObject(app.sessions)
        }
    }
}
