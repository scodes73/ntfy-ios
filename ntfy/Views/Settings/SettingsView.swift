import Foundation
import SwiftUI
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @State private var userDialog: UserDialog?
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("General"),
                    footer: Text("When subscribing to new topics, this server will be used as a default.")
                ) {
                    DefaultServerView()
                }
                Section(
                    header: Text("Notifications"),
                    footer: Text("Automatically download attachments up to the selected size. Attachments larger than this limit must be downloaded manually.")
                ) {
                    AttachmentAutoDownloadView()
                }
                Section(
                    footer: Text("Max priority notifications break through to grab your attention, appearing on the lock screen and playing a sound even when focus mode is on or your device is muted.")
                ) {
                    CriticalAlertsSettingView()
                }
                #if targetEnvironment(simulator)
                Section(
                    header: Text("Simulator / Dev"),
                    footer: Text("Firebase is off in the simulator by default. Use this to fire a local notification with action buttons — go Home or lock the sim, long-press the notification, then tap a button.")
                ) {
                    Button("Test notification action buttons") {
                        delegate.postDevActionButtonsNotification()
                    }
                    Text(FirebaseSupport.isEnabled ? "Firebase: on" : "Firebase: off (local notifs only)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                #endif
                Section(
                    header: Text("Users"),
                    footer: Text("To access read-protected topics, you may add or edit users here. All topics for a given server will use the same user.")
                ) {
                    UserTableView(dialog: $userDialog)
                }
                Section(header: Text("About")) {
                    AboutView()
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(item: $userDialog) { dialog in
            UserEditorView(
                selectedUser: dialog.user,
                onSave: { baseUrl, username, password in
                    store.saveUser(baseUrl: baseUrl, username: username, password: password)
                    userDialog = nil
                },
                onDelete: { user in
                    store.delete(user: user)
                    userDialog = nil
                },
                onCancel: {
                    userDialog = nil
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        SettingsView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}
