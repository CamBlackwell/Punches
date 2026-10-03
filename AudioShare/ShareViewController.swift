import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    
    private let appGroupIdentifier = SharedConstants.appGroupIdentifier
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        preferredContentSize = CGSize(width: 100, height: 160)
        
        view.backgroundColor = .systemBackground
        
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        let titleLabel = UILabel()
        titleLabel.text = "Import to Punches"
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textAlignment = .center
        
        let addButton = UIButton(type: .system)
        var addConfig = UIButton.Configuration.filled()
        addConfig.title = "Add to Library"
        addConfig.baseBackgroundColor = .systemBlue
        addConfig.baseForegroundColor = .white
        addConfig.cornerStyle = .medium
        addConfig.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 32, bottom: 16, trailing: 32)
        addButton.configuration = addConfig
        addButton.addTarget(self, action: #selector(addToLibrary), for: .touchUpInside)
        
        let addAndPlayButton = UIButton(type: .system)
        var addAndPlayConfig = UIButton.Configuration.filled()
        addAndPlayConfig.title = "Add and Play"
        addAndPlayConfig.baseBackgroundColor = .systemGreen
        addAndPlayConfig.baseForegroundColor = .white
        addAndPlayConfig.cornerStyle = .medium
        addAndPlayConfig.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 32, bottom: 16, trailing: 32)
        addAndPlayButton.configuration = addAndPlayConfig
        addAndPlayButton.addTarget(self, action: #selector(addAndPlay), for: .touchUpInside)
        
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 16)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(addButton)
        stackView.addArrangedSubview(addAndPlayButton)
        stackView.addArrangedSubview(cancelButton)
        
        view.addSubview(stackView)
        
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            addButton.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            addAndPlayButton.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
    }
    
    @objc private func addToLibrary() {
        processFiles(shouldOpenApp: false)
    }
    
    @objc private func addAndPlay() {
        processFiles(shouldOpenApp: true)
    }
    
    @objc private func cancel() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
    
    private func processFiles(shouldOpenApp: Bool) {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            cancel()
            return
        }
        
        var fileURLs: [URL] = []
        let group = DispatchGroup()
        
        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                    group.enter()
                    
                    provider.loadItem(forTypeIdentifier: UTType.audio.identifier, options: nil) { (item, error) in
                        defer { group.leave() }
                        
                        if let error = error {
                            print("Error loading item: \(error)")
                            return
                        }
                        
                        if let url = item as? URL {
                            fileURLs.append(url)
                        }
                    }
                }
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            if fileURLs.isEmpty {
                self.cancel()
                return
            }
            
            self.handoffToSharedContainer(fileURLs)
            
            if shouldOpenApp {
                self.openMainApp()
            } else {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    /// Hands the shared files to the main app.
    ///
    /// The handoff is a file in a shared directory whose name encodes everything
    /// needed to import it: `<uuid>--<original file name>`. The previous version
    /// also wrote a `[String]` of filenames into a shared `UserDefaults` array —
    /// two sources of truth, written without a transaction, with the whole
    /// `PendingImports/` directory deleted afterwards by the app, which destroyed
    /// any file in the batch the app had not reached.
    ///
    /// This version writes only the file, and the app consumes each one
    /// individually after committing its own row. Nothing here opens the
    /// database, so there is no cross-process write to race, and an extension
    /// killed mid-handoff leaves a file the app picks up on next launch.
    private func handOffToSharedContainer(_ urls: [URL]) {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            // Without the app group the files cannot be handed over at all.
            // Saying so beats writing somewhere the app will never look.
            reportHandoffFailure(
                "The app group \(appGroupIdentifier) is unavailable, so the app cannot be reached. Add com.apple.security.application-groups to Punches3.entitlements."
            )
            return
        }

        let inbound = groupURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Inbound", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbound, withIntermediateDirectories: true)

        var failed = 0
        for url in urls {
            // The original name is carried in the filename because the inbound
            // file is moved (not copied) into the library, and the library names
            // its files by job id.
            let name = "\(UUID().uuidString)--\(url.lastPathComponent)"
            let destination = inbound.appendingPathComponent(name)

            do {
                // A UUID prefix makes a collision impossible, so there is no
                // "file exists, delete it first" window to race.
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                failed += 1
                print("Error handing off \(url.lastPathComponent): \(error)")
            }
        }

        guard failed == 0 else {
            reportHandoffFailure("Could not hand over \(failed) of \(urls.count) file(s).")
            return
        }
    }

    private func reportHandoffFailure(_ message: String) {
        let alert = UIAlertController(
            title: "Couldn't add to Punches",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        present(alert, animated: true)
    }
    
    private func openMainApp() {
        guard let url = URL(string: SharedConstants.openAndPlayScheme) else { return }
        
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:]) { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }
                return
            }
            responder = responder?.next
        }
        
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
