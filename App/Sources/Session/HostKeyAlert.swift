import SwiftUI

extension View {
    /// Asks the person to trust a host key the first time (or warns when it changed).
    func hostKeyAlert(_ session: HostSession?) -> some View {
        modifier(HostKeyAlertModifier(session: session))
    }
}

private struct HostKeyAlertModifier: ViewModifier {
    let session: HostSession?

    func body(content: Content) -> some View {
        let question = session?.hostKeyQuestion
        content.alert(title(question), isPresented: Binding(
            get: { session?.hostKeyQuestion != nil },
            set: { shown in if !shown { session?.answerHostKey(false) } }
        ), presenting: question) { _ in
            Button("Cancel", role: .cancel) { session?.answerHostKey(false) }
            Button(question?.previousFingerprint == nil ? "Trust" : "Trust New Key",
                   role: question?.previousFingerprint == nil ? nil : .destructive) {
                session?.answerHostKey(true)
            }
        } message: { q in
            if let old = q.previousFingerprint {
                Text("The host key of \(q.key.host) has changed. This can mean someone is intercepting the connection.\n\nOld: \(old)\nNew: \(q.key.fingerprint) (\(q.key.keyType))")
            } else {
                Text("First connection to \(q.key.host). Check that this fingerprint matches the Mac's host key (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub):\n\n\(q.key.fingerprint)\n(\(q.key.keyType))")
            }
        }
    }

    private func title(_ q: HostSession.HostKeyQuestion?) -> String {
        q?.previousFingerprint == nil ? "Trust this computer?" : "Host key changed!"
    }
}
